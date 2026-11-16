package app

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"

gitaris_merge_preview :: proc(ctx: ^ui.UiContext, mono: ^font_core.Face, id, heading, text: string,
	rect: ui.Rect2d, color: [4]f32, scale: f32) {
	ui.begin_window(ctx, template_rect(rect, scale), id)
	template_box(ctx, rect, color, 10, scale)
	template_label(ctx, mono, heading, {rect.x + 10, rect.y + 2, rect.width - 20, 24}, 11, TEMPLATE_TEXT, scale)
	lines := strings.split(text, "\n", context.temp_allocator)
	width := rect.width
	for line in lines do width = max(width, f32(len(line)) * 8 + 24)
	viewport := ui.Rect2d{rect.x + 10, rect.y + 28, rect.width - 20, rect.height - 36}
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
	top: f32 = GITARIS_MENU_HEIGHT
	panel := ui.Rect2d{GITARIS_GAP, top, w - 2 * GITARIS_GAP, h - top - GITARIS_GAP}
	px, pw := panel.x + GITARIS_PAD, panel.width - 2 * GITARIS_PAD
	y0 := top + 14
	bottom := panel.y + panel.height - 14
	content := y0 + 64
	{
		ui.begin_window(ctx, template_rect({0, top, w, h - top}, scale), "merge-header")
		template_panel(ctx, panel, TEMPLATE_CARD, 16, scale)
		if gitaris_button(ctx, face, "← History", {px, y0 + 1, 96, 30}, scale) {
			gitaris_open_menu(state, .NONE)
			return
		}
		template_label(ctx, title, "Merge editor", {px + 108, y0, pw - 300, 32}, 18, TEMPLATE_TEXT, scale)
		if gitaris_button(ctx, face, "Reload conflicts", {px + pw - 140, y0 + 1, 140, 30}, scale) {
			gitaris_error(state, workspace.load_merge(model))
		}
		template_label(ctx, face, fmt.tprintf("Conflicts in %s's working tree · drafts stay while switching files · Reload discards drafts", gitaris_repo_label(state)),
			{px, y0 + 38, pw, 18}, 11, TEMPLATE_MUTED, scale)
		if state.error != "" {
			gitaris_message(ctx, face, state.error, {px, y0 + 60, pw, 34}, scale)
			content += 34
		}
		if len(editor.files) == 0 {
			template_label(ctx, title, "No unresolved conflicts in the index.", {px, content + 40, pw, 30}, 17, TEMPLATE_TEXT, scale, {.CENTER})
			return
		}
	}

	lw: f32 = 220
	{
		ui.begin_window(ctx, template_rect({px, content, lw, bottom - content}, scale), "merge-files")
		remaining := 0
		for file in editor.files do if !file.staged do remaining += 1
		template_label(ctx, title, "Files", {px, content, lw - 100, 24}, 13, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("%d unresolved", remaining), {px + lw - 100, content, 100, 24}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
		viewport := ui.Rect2d{px, content + 30, lw, bottom - content - 30}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(editor.files), 44, scale)
		chosen := -1
		for i in first..<last {
			file := &editor.files[i]
			y := viewport.y + f32(i) * 44 - offset
			if gitaris_row_button(ctx, face, file.path, {px, y, lw - 7, 40}, i == editor.selected, scale) do chosen = i
			template_label(ctx, face, file.path, {px + 10, y + 3, lw - 24, 20}, 13, TEMPLATE_TEXT, scale)
			status := file.staged ? "Staged" : (file.issue != "" ? "External resolution needed" : "Unresolved")
			template_label(ctx, face, status, {px + 10, y + 22, lw - 24, 15}, 10, TEMPLATE_MUTED, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if chosen >= 0 {
			gitaris_error(state, workspace.select_merge_file(model, chosen))
			ctx.caret = 0
			gitaris_reset_windows(ctx, "merge-current", "merge-incoming", "merge-result")
		}
	}

	x, cw := px + lw + 16, pw - lw - 16
	file := &editor.files[editor.selected]
	{
		ui.begin_window(ctx, template_rect({x, content, cw, bottom - content}, scale), "merge-actions")
		template_label(ctx, title, file.path, {x, content, cw, 24}, 15, TEMPLATE_TEXT, scale)
		if file.issue != "" {
			gitaris_message(ctx, face, file.issue, {x, content + 32, cw, 52}, scale)
			return
		}
		if !file.loaded do return
		if file.staged {
			template_label(ctx, face, "Result saved and staged. Continue your merge or rebase with Git.", {x, content + 32, cw, 30}, 14, TEMPLATE_TEXT, scale)
			return
		}
		text := strings.to_string(file.result)
		hunk, found, marker_error := workspace.next_merge_hunk(text)
		if found {
			labels := [?]string{"Use current", "Use incoming", "Use both"}
			for label, i in labels {
				if gitaris_button(ctx, face, label, {x + f32(i) * 120, content + 30, 114, 30}, scale) {
					gitaris_error(state, workspace.choose_merge_hunk(file, workspace.Merge_Choice(i)))
					ctx.caret = hunk.start
					gitaris_reset_windows(ctx, "merge-current", "merge-incoming", "merge-result")
				}
			}
		} else {
			message := marker_error != "" ? "Repair the markers in the result below." : "No conflict blocks left. Review, then save."
			template_label(ctx, face, message, {x, content + 30, cw - 160, 30}, 12, TEMPLATE_MUTED, scale)
		}
		if gitaris_button(ctx, face, "Save and stage", {x + cw - 140, content + 30, 140, 30}, scale, true) {
			gitaris_error(state, workspace.save_merge_file(model))
		}
	}
	// Choices operate on the next block, not the whole file, so Git's automatic
	// merges and any manual edits elsewhere in the result remain intact.
	text := strings.to_string(file.result)
	hunk, found, _ := workspace.next_merge_hunk(text)
	current := found ? text[hunk.current_start:hunk.current_end] : "No remaining block"
	incoming := found ? text[hunk.incoming_start:hunk.incoming_end] : "No remaining block"
	half := (cw - 10) * 0.5
	preview_y := content + 70
	preview_h := clamp((bottom - preview_y) * 0.4, 90, 180)
	gitaris_merge_preview(ctx, mono, "merge-current", "CURRENT (ours) · next block", current,
		{x, preview_y, half, preview_h}, GITARIS_DELETION, scale)
	gitaris_merge_preview(ctx, mono, "merge-incoming", "INCOMING (theirs) · next block", incoming,
		{x + half + 10, preview_y, half, preview_h}, GITARIS_ADDITION, scale)

	y := preview_y + preview_h + 10
	ui.begin_window(ctx, template_rect({x, y, cw, bottom - y}, scale), "merge-result")
	template_label(ctx, face, "RESULT · editable · arrows / Home / End to navigate · Ctrl+V to paste", {x, y, cw - 136, 28}, 10, TEMPLATE_MUTED, scale)
	if gitaris_button(ctx, face, "Reset result", {x + cw - 120, y, 120, 28}, scale) {
		gitaris_set_field(&file.result, file.original)
		ctx.caret = 0
		gitaris_error(state, "")
	}
	style := gitaris_field_style(mono, scale)
	style.font_size = 13 * scale
	ui.style_push(ctx, style)
	if ui.textbox(ctx, file.path, &file.result, template_rect({x, y + 34, cw, bottom - y - 34}, scale)) == .MODIFIED {
		gitaris_error(state, "")
	}
	ui.style_pop(ctx)
}
