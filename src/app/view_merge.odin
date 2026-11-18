package app

// Merge editor: lists conflicted files and, for each conflict, keeps the
// current side, the incoming side, or both.

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"

// Where the parts of the merge editor go: a header across the top, the file
// list on the left, and the selected file's actions, previews and result on
// the right.
@(private = "file")
Merge_Layout :: struct {
	x, width: f32, // Inside the panel's padding.
	header_y: f32,
	content_y: f32, // Below the header.
	bottom: f32,
	files_w: f32,
	file_x, file_w: f32, // The selected file's column.
}

workbench_merge_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face,
	state: ^Workbench, w, h, scale: f32) {
	panel := ui.Rect2d{PANEL_GAP, MENU_HEIGHT, w - 2 * PANEL_GAP, h - MENU_HEIGHT - PANEL_GAP}
	header_y: f32 = MENU_HEIGHT + 14
	files_w: f32 = 220
	layout := Merge_Layout{
		x = panel.x + PANEL_PADDING,
		width = panel.width - 2 * PANEL_PADDING,
		header_y = header_y,
		content_y = header_y + 64,
		bottom = panel.y + panel.height - 14,
		files_w = files_w,
	}
	layout.file_x = layout.x + files_w + 16
	layout.file_w = layout.width - files_w - 16

	if merge_header(ctx, face, title, state, panel, &layout, w, h, scale) do return
	merge_file_list(ctx, face, title, state, layout, scale)
	editor := &state.model.merge
	file := &editor.files[editor.selected]
	if merge_actions(ctx, face, title, state, file, layout, scale) do return
	preview_bottom := merge_previews(ctx, mono, file, layout, scale)
	merge_result_editor(ctx, face, mono, state, file, layout, preview_bottom + 10, scale)
}

// The card, title row and description. Returns true when there is nothing
// more to draw (the user left, or no conflicts are left).
@(private = "file")
merge_header :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench,
	panel: ui.Rect2d, layout: ^Merge_Layout, w, h, scale: f32) -> (stop: bool) {
	model := &state.model
	x, width, y := layout.x, layout.width, layout.header_y
	ui.begin_window(ctx, theme_rect({0, MENU_HEIGHT, w, h - MENU_HEIGHT}, scale), "merge-header")
	theme_panel(ctx, panel, THEME_CARD, 16, scale)
	if workbench_button(ctx, face, "← History", {x, y + 1, 96, 30}, scale) {
		workbench_open_menu(state, .NONE)
		return true
	}
	theme_label(ctx, title, "Merge editor", {x + 108, y, width - 300, 32}, 18, THEME_TEXT, scale)
	if workbench_button(ctx, face, "Reload conflicts", {x + width - 140, y + 1, 140, 30}, scale) {
		workbench_error(state, workspace.load_merge(model))
	}
	description := fmt.tprintf("Conflicts in %s's working tree · drafts stay while switching files · Reload discards drafts", workbench_repo_label(state))
	theme_label(ctx, face, description, {x, y + 38, width, 18}, 11, THEME_MUTED, scale)
	if state.error != "" {
		workbench_message(ctx, face, state.error, {x, y + 60, width, 34}, scale)
		layout.content_y += 34
	}
	if len(model.merge.files) == 0 {
		theme_label(ctx, title, "No unresolved conflicts in the index.", {x, layout.content_y + 40, width, 30}, 17, THEME_TEXT, scale, {.CENTER})
		return true
	}
	return false
}

// Conflicted files with their state; clicking one selects it.
@(private = "file")
merge_file_list :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench, layout: Merge_Layout, scale: f32) {
	model := &state.model
	editor := &model.merge
	x, y, width := layout.x, layout.content_y, layout.files_w
	ui.begin_window(ctx, theme_rect({x, y, width, layout.bottom - y}, scale), "merge-files")
	remaining := 0
	for file in editor.files do if !file.staged do remaining += 1
	theme_label(ctx, title, "Files", {x, y, width - 100, 24}, 13, THEME_TEXT, scale)
	theme_label(ctx, face, fmt.tprintf("%d unresolved", remaining), {x + width - 100, y, 100, 24}, 11, THEME_MUTED, scale, {.RIGHT})

	row_h :: 44
	viewport := ui.Rect2d{x, y + 30, width, layout.bottom - y - 30}
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(editor.files), row_h, scale)
	chosen := -1
	for i in first..<last {
		file := &editor.files[i]
		row_y := viewport.y + f32(i) * row_h - offset
		if workbench_row_button(ctx, face, file.path, {x, row_y, width - 7, 40}, i == editor.selected, scale) do chosen = i
		theme_label(ctx, face, file.path, {x + 10, row_y + 3, width - 24, 20}, 13, THEME_TEXT, scale)
		status := "Unresolved"
		if file.staged {
			status = "Staged"
		} else if file.issue != "" {
			status = "External resolution needed"
		}
		theme_label(ctx, face, status, {x + 10, row_y + 22, width - 24, 15}, 10, THEME_MUTED, scale)
	}
	workbench_scroll_end(ctx, viewport, scale)
	if chosen >= 0 {
		workbench_error(state, workspace.select_merge_file(model, chosen))
		ctx.caret = 0
		workbench_reset_windows(ctx, "merge-current", "merge-incoming", "merge-result")
	}
}

// The selected file's name, then one button per way to resolve its next
// conflict, and Save and stage. Returns true when the file cannot be edited
// here (or is already done), so the editor below is not shown.
@(private = "file")
merge_actions :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench,
	file: ^workspace.Merge_File, layout: Merge_Layout, scale: f32) -> (stop: bool) {
	x, y, width := layout.file_x, layout.content_y, layout.file_w
	ui.begin_window(ctx, theme_rect({x, y, width, layout.bottom - y}, scale), "merge-actions")
	theme_label(ctx, title, file.path, {x, y, width, 24}, 15, THEME_TEXT, scale)
	if file.issue != "" {
		workbench_message(ctx, face, file.issue, {x, y + 32, width, 52}, scale)
		return true
	}
	if !file.loaded do return true
	if file.staged {
		theme_label(ctx, face, "Result saved and staged. Continue your merge or rebase with Git.", {x, y + 32, width, 30}, 14, THEME_TEXT, scale)
		return true
	}

	hunk, found, marker_error := workspace.next_merge_hunk(strings.to_string(file.result))
	if found {
		// The two combinations keep both sides and differ only in order.
		choices := [workspace.Merge_Choice]struct { label: string, width: f32 }{
			.CURRENT = {"Use current", 108},
			.INCOMING = {"Use incoming", 116},
			.BOTH = {"Current + incoming", 152},
			.BOTH_INCOMING_FIRST = {"Incoming + current", 152},
		}
		button_x := x
		for choice, kind in choices {
			if workbench_button(ctx, face, choice.label, {button_x, y + 30, choice.width, 30}, scale) {
				workbench_error(state, workspace.choose_merge_hunk(file, kind))
				workbench_reset_windows(ctx, "merge-current", "merge-incoming")
				// Continue in the result where the block was replaced.
				ctx.focus_id = workbench_merge_result_id(file.path)
				ctx.caret = hunk.start
			}
			button_x += choice.width + 6
		}
	} else {
		message := marker_error != "" ? "Repair the markers in the result below." : "No conflict blocks left. Review, then save."
		theme_label(ctx, face, message, {x, y + 30, width - 160, 30}, 12, THEME_MUTED, scale)
	}
	if workbench_button(ctx, face, "Save and stage", {x + width - 140, y + 30, 140, 30}, scale, true) {
		workbench_error(state, workspace.save_merge_file(&state.model))
	}
	return false
}

// Side-by-side previews of the next conflict's two sides. Returns their bottom edge.
@(private = "file")
merge_previews :: proc(ctx: ^ui.UiContext, mono: ^font_core.Face, file: ^workspace.Merge_File,
	layout: Merge_Layout, scale: f32) -> (bottom: f32) {
	// Choices operate on the next block, not the whole file, so Git's automatic
	// merges and any manual edits elsewhere in the result remain intact.
	text := strings.to_string(file.result)
	hunk, found, _ := workspace.next_merge_hunk(text)
	current, incoming := "No remaining block", "No remaining block"
	if found {
		current = text[hunk.current_start:hunk.current_end]
		incoming = text[hunk.incoming_start:hunk.incoming_end]
	}
	x, width := layout.file_x, layout.file_w
	half := (width - 10) * 0.5
	y := layout.content_y + 70
	height := clamp((layout.bottom - y) * 0.4, 90, 180)
	merge_preview(ctx, mono, "merge-current", "CURRENT (ours) · next block", current, {x, y, half, height}, THEME_DELETION, scale)
	merge_preview(ctx, mono, "merge-incoming", "INCOMING (theirs) · next block", incoming, {x + half + 10, y, half, height}, THEME_ADDITION, scale)
	return y + height
}

// A read-only, scrollable block of monospaced text with a heading.
@(private = "file")
merge_preview :: proc(ctx: ^ui.UiContext, mono: ^font_core.Face, id, heading, text: string,
	rect: ui.Rect2d, color: [4]f32, scale: f32) {
	ui.begin_window(ctx, theme_rect(rect, scale), id)
	theme_box(ctx, rect, color, 10, scale)
	theme_label(ctx, mono, heading, {rect.x + 10, rect.y + 2, rect.width - 20, 24}, 11, THEME_TEXT, scale)
	line_h :: 20
	char_w :: 8 // Estimated width of a monospaced character, to size the scroll area.
	lines := strings.split(text, "\n", context.temp_allocator)
	width := rect.width
	for line in lines do width = max(width, f32(len(line)) * char_w + 24)
	viewport := ui.Rect2d{rect.x + 10, rect.y + 28, rect.width - 20, rect.height - 36}
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(lines), line_h, scale, width)
	scroll_x := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	for i in first..<last {
		line_rect := ui.Rect2d{viewport.x - scroll_x, viewport.y + f32(i) * line_h - offset, width, line_h}
		theme_label(ctx, mono, strings.trim_suffix(lines[i], "\r"), line_rect, 13, THEME_TEXT, scale)
	}
	workbench_scroll_end(ctx, viewport, scale, true)
}

// The editable result of the merge, with Reset and scrollbars.
@(private = "file")
merge_result_editor :: proc(ctx: ^ui.UiContext, face, mono: ^font_core.Face, state: ^Workbench,
	file: ^workspace.Merge_File, layout: Merge_Layout, y, scale: f32) {
	x, width, bottom := layout.file_x, layout.file_w, layout.bottom
	ui.begin_window(ctx, theme_rect({x, y, width, bottom - y}, scale), "merge-result")
	theme_label(ctx, face, "RESULT · click to edit · drag or Shift+arrows to select · Ctrl+A/C/X/V · Tab indents",
		{x, y, width - 136, 28}, 10, THEME_MUTED, scale)
	editor_id := workbench_merge_result_id(file.path)
	if workbench_button(ctx, face, "Reset result", {x + width - 120, y, 120, 28}, scale) {
		workbench_set_field(&file.result, file.original)
		ctx.focus_id = editor_id
		ctx.caret = 0
		workbench_error(state, "")
	}
	// The window's scroll storage holds the editor's view, so switching files
	// (which resets this window) starts at the top.
	window := &ctx.windows[ctx.window_index]
	area := ui.Rect2d{x, y + 34, width, bottom - y - 34}
	style := workbench_field_style(mono, scale)
	style.font_size = 13 * scale
	ui.style_push(ctx, style)
	result, extent, view := ui.text_editor(ctx, file.path, &file.result, theme_rect(area, scale), &window.scroll_offset)
	ui.style_pop(ctx)
	if result == .MODIFIED do workbench_error(state, "")
	workbench_scrollbar(ctx, "result-y", {area.x + area.width - 12, area.y + 6, 10, area.height - 12},
		view.y, extent.y, &window.scroll_offset.y, true, scale, editor_id)
	workbench_scrollbar(ctx, "result-x", {area.x + 6, area.y + area.height - 12, area.width - 24, 10},
		view.x, extent.x, &window.scroll_offset.x, false, scale, editor_id)
}

// The result editor's element ID (its window is "merge-result"), for focusing it.
workbench_merge_result_id :: proc(path: string) -> ui.UiId {
	return ui.make_id(path, ui.make_id("merge-result"))
}
