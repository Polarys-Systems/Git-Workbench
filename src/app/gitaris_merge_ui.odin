package app

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"

gitaris_merge_preview :: proc(ctx: ^ui.UiContext, mono: ^font_core.Face, id, heading, text: string,
	rect: ui.Rect2d, color: [4]f32, scale: f32) {
	ui.begin_window(ctx, template_rect(rect, scale), id)
	template_box(ctx, rect, color, 8, scale)
	template_label(ctx, mono, heading, {rect.x + 8, rect.y, rect.width - 16, 28}, 12, TEMPLATE_TEXT, scale)
	lines := strings.split(text, "\n", context.temp_allocator)
	width := rect.width
	for line in lines do width = max(width, f32(len(line)) * 8 + 24)
	viewport := ui.Rect2d{rect.x + 8, rect.y + 32, rect.width - 16, rect.height - 44}
	first, last, offset := gitaris_scroll_begin(ctx, viewport, len(lines), 20, scale, width)
	horizontal := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	for i in first..<last {
		template_label(ctx, mono, strings.trim_suffix(lines[i], "\r"),
			{viewport.x - horizontal, viewport.y + f32(i) * 20 - offset, width, 20}, 13, TEMPLATE_TEXT, scale)
	}
	gitaris_scroll_end(ctx, viewport, scale, true)
}

gitaris_merge_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face,
	state: ^Gitaris, w, h, scale: f32) {
	model := &state.model
	editor := &model.merge
	{
		ui.begin_window(ctx, template_rect({0, GITARIS_MENU_HEIGHT, w, h - GITARIS_MENU_HEIGHT}, scale), "merge-header")
		if gitaris_button(ctx, face, "← History", {32, 78, 116, 36}, scale) {
			gitaris_open_menu(state, .NONE)
			return
		}
		template_label(ctx, title, "Merge editor", {168, 72, w - 400, 44}, 28, TEMPLATE_TEXT, scale)
		if gitaris_button(ctx, face, "Reload conflicts", {w - 196, 78, 164, 36}, scale) {
			gitaris_error(state, workspace.load_merge(model))
		}
		template_label(ctx, face, "Working tree conflicts · drafts stay while switching files · Reload discards drafts", {32, 120, w - 64, 24}, 12, TEMPLATE_MUTED, scale)
		if state.error != "" do gitaris_message(ctx, face, state.error, {32, 148, w - 64, 34}, scale)
		if len(editor.files) == 0 {
			template_label(ctx, title, "No unresolved conflicts in the index.", {32, 228, w - 64, 40}, 22, TEMPLATE_TEXT, scale, {.CENTER})
			return
		}
	}

	{
		ui.begin_window(ctx, template_rect({32, 184, 208, h - 216}, scale), "merge-files")
		remaining := 0
		for file in editor.files do if !file.staged do remaining += 1
		template_label(ctx, face, fmt.tprintf("%d unresolved files", remaining), {40, 188, 192, 28}, 13, TEMPLATE_MUTED, scale)
		viewport := ui.Rect2d{32, 228, 208, h - 268}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(editor.files), 58, scale)
		chosen := -1
		for i in first..<last {
			file := &editor.files[i]
			y := viewport.y + f32(i) * 58 - offset
			if gitaris_row_button(ctx, face, file.path, {32, y, 200, 54}, i == editor.selected, scale) do chosen = i
			template_label(ctx, face, file.path, {40, y + 3, 184, 26}, 13, TEMPLATE_TEXT, scale)
			status := file.staged ? "Staged" : (file.issue != "" ? "External resolution needed" : "Unresolved")
			template_label(ctx, face, status, {40, y + 30, 184, 18}, 10, TEMPLATE_MUTED, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if chosen >= 0 {
			gitaris_error(state, workspace.select_merge_file(model, chosen))
			ctx.caret = 0
			ctx.windows[3].scroll_offset = {}
			ctx.windows[4].scroll_offset = {}
		}
	}

	x, cw := f32(264), w - 296
	file := &editor.files[editor.selected]
	{
		ui.begin_window(ctx, template_rect({x, 184, cw, h - 216}, scale), "merge-actions")
		template_label(ctx, title, file.path, {x, 184, cw, 28}, 18, TEMPLATE_TEXT, scale)
		if file.issue != "" {
			gitaris_message(ctx, face, file.issue, {x, 236, cw, 72}, scale)
			return
		}
		if !file.loaded do return
		if file.staged {
			template_label(ctx, face, "Result saved and staged. Continue your merge or rebase with Git.", {x, 236, cw, 54}, 15, TEMPLATE_TEXT, scale)
			return
		}
		text := strings.to_string(file.result)
		hunk, found, marker_error := workspace.next_merge_hunk(text)
		if found {
			labels := [?]string{"Use current", "Use incoming", "Use both"}
			for label, i in labels {
				if gitaris_button(ctx, face, label, {x + f32(i) * 128, 224, 120, 34}, scale) {
					gitaris_error(state, workspace.choose_merge_hunk(file, workspace.Merge_Choice(i)))
					ctx.caret = hunk.start
					ctx.windows[3].scroll_offset = {}
					ctx.windows[4].scroll_offset = {}
				}
			}
		} else {
			message := marker_error != "" ? "Repair the markers in the result below." : "No conflict blocks left. Review, then save."
			template_label(ctx, face, message, {x, 224, cw - 160, 34}, 12, TEMPLATE_MUTED, scale)
		}
		if gitaris_button(ctx, face, "Save and stage", {x + cw - 152, 224, 152, 34}, scale, true) {
			gitaris_error(state, workspace.save_merge_file(model))
		}
	}
	// Choices operate on the next block, not the whole file, so Git's automatic
	// merges and any manual edits elsewhere in the result remain intact.
	text := strings.to_string(file.result)
	hunk, found, _ := workspace.next_merge_hunk(text)
	current := found ? text[hunk.current_start:hunk.current_end] : "No remaining block"
	incoming := found ? text[hunk.incoming_start:hunk.incoming_end] : "No remaining block"
	pw := (cw - 12) * 0.5
	ph := min(180, (h - 400) * 0.45)
	gitaris_merge_preview(ctx, mono, "merge-current", "CURRENT (ours) · next block", current,
		{x, 272, pw, ph}, GITARIS_DELETION, scale)
	gitaris_merge_preview(ctx, mono, "merge-incoming", "INCOMING (theirs) · next block", incoming,
		{x + pw + 12, 272, pw, ph}, GITARIS_ADDITION, scale)

	y := 284 + ph
	ui.begin_window(ctx, template_rect({x, y, cw, h - y - 32}, scale), "merge-result")
	template_label(ctx, face, "RESULT · editable · arrows / Home / End to navigate · Ctrl+V to paste", {x, y, cw - 136, 28}, 11, TEMPLATE_MUTED, scale)
	if gitaris_button(ctx, face, "Reset result", {x + cw - 128, y, 128, 28}, scale) {
		gitaris_set_field(&file.result, file.original)
		ctx.caret = 0
		gitaris_error(state, "")
	}
	style := gitaris_control_style(mono, scale)
	style.font_size = 13 * scale
	style.hover_color, style.active_color = TEMPLATE_CARD, TEMPLATE_CARD
	ui.style_push(ctx, style)
	if ui.textbox(ctx, file.path, &file.result, template_rect({x, y + 36, cw, h - y - 68}, scale)) == .MODIFIED {
		gitaris_error(state, "")
	}
	ui.style_pop(ctx)
}
