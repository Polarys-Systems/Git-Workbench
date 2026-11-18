package app

// Changes of a commit or of the working tree: the file list (with staging and
// the commit box) and the diff of the selected file.

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

DIFF_LINE_HEIGHT :: 22

@(private = "file") FILE_ROW_HEIGHT :: 44
// The diff's gutter: old and new line numbers, then the +/- sign; text starts at DIFF_TEXT_X.
@(private = "file") DIFF_OLD_LINE_X :: 4
@(private = "file") DIFF_NEW_LINE_X :: 48
@(private = "file") DIFF_SIGN_X :: 94
@(private = "file") DIFF_TEXT_X :: 112

// Where the parts of the changes view go. The header spans the top; below it
// the file list sits on the left and the diff on the right.
@(private = "file")
Changes_Layout :: struct {
	x, width: f32, // The content column.
	header_y: f32,
	panes_y: f32, // Top of the file list and the diff.
	bottom: f32,
	files_w: f32, // Width of the file list.
	diff_x, diff_w: f32,
}

workbench_file_status :: proc(file: workspace.Changed_File) -> (string, string, [4]f32) {
	if file.old_mode == git.FILEMODE_COMMIT || file.new_mode == git.FILEMODE_COMMIT {
		switch file.status {
		case git.DELTA_ADDED: return "S", "Submodule added", THEME_ADDITION_TEXT
		case git.DELTA_DELETED: return "S", "Submodule removed", THEME_DELETION_TEXT
		case: return "S", "Submodule", THEME_ACCENT
		}
	}
	switch file.status {
	case git.DELTA_ADDED: return "A", "Added", THEME_ADDITION_TEXT
	case git.DELTA_DELETED: return "D", "Deleted", THEME_DELETION_TEXT
	case git.DELTA_RENAMED: return "R", "Renamed", THEME_ACCENT
	case git.DELTA_COPIED: return "C", "Copied", THEME_ACCENT
	case git.DELTA_TYPECHANGE: return "T", "Type changed", THEME_MUTED
	case git.DELTA_UNTRACKED: return "U", "Untracked (new, not staged)", THEME_ADDITION_TEXT
	case git.DELTA_CONFLICTED: return "!", "Conflicted · resolve in the Merge editor", THEME_DELETION_TEXT
	case git.DELTA_UNREADABLE: return "?", "Unreadable", THEME_MUTED
	case: return "M", "Modified", THEME_ACCENT
	}
}

workbench_stage_status :: proc(file: workspace.Changed_File) -> (string, [4]f32) {
	if file.staged && file.unstaged do return "Partly staged", THEME_ACCENT
	if file.staged do return "Staged", THEME_ADDITION_TEXT
	return "Not staged", THEME_MUTED
}

// Message box and Commit button for the working tree view. Commits exactly the
// staged files to the open repository, which the info line names. Returns
// true when a commit replaced the model this frame.
workbench_commit_form :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y, w, scale: f32) -> bool {
	model := &state.model
	ui.style_push(ctx, workbench_field_style(face, scale))
	ui.textbox(ctx, "commit-message", &state.commit_message, theme_rect({x, y, w, 64}, scale))
	ui.style_pop(ctx)
	if len(state.commit_message.buf) == 0 {
		theme_label(ctx, face, "Commit message · first line is the summary", {x + 11, y + 4, w - 22, 24}, 13, THEME_MUTED, scale)
	}
	staged := 0
	for file in model.changes.files do if file.staged do staged += 1
	target := workbench_repo_label(state)
	info := staged > 0 ? fmt.tprintf("%d staged · into %s", staged, target) : fmt.tprintf("Nothing staged in %s", target)
	theme_label(ctx, face, info, {x, y + 70, w - 176, 30}, 11, staged > 0 ? THEME_TEXT : THEME_MUTED, scale)
	// A roomier editor with a summary line, description and staged files.
	if workbench_button(ctx, face, "Editor", {x + w - 170, y + 70, 70, 30}, scale, id = "commit-editor") {
		workbench_open_commit_editor(ctx, state)
	}
	if !workbench_button(ctx, face, "Commit", {x + w - 94, y + 70, 94, 30}, scale, true, id = "commit-staged") do return false
	replaced, err := workbench_commit(ctx, state, strings.to_string(state.commit_message))
	workbench_error(state, err)
	return replaced
}

workbench_changes_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face,
	state: ^Workbench, x, content_w, h, scale: f32) {
	header_y: f32 = MENU_HEIGHT + 14
	files_w := clamp(content_w * 0.3, 220, 300)
	layout := Changes_Layout{
		x = x,
		width = content_w,
		header_y = header_y,
		panes_y = header_y + 64,
		bottom = h - PANEL_GAP - 14,
		files_w = files_w,
		diff_x = x + files_w + 14,
		diff_w = content_w - files_w - 14,
	}
	// Each panel returns true when something it did (leaving the view, staging,
	// committing) replaced what the rest of this frame would draw.
	if changes_header(ctx, face, title, state, &layout, h, scale) do return
	if changes_file_list(ctx, face, title, mono, state, layout, scale) do return
	if len(state.model.changes.files) > 0 do changes_diff(ctx, face, title, mono, state, layout, scale)
}

// Title row: back button, what is being compared, and its actions. Moves
// `layout.panes_y` down when an error message needs room.
@(private = "file")
changes_header :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench,
	layout: ^Changes_Layout, h, scale: f32) -> (stop: bool) {
	model := &state.model
	changes := &model.changes
	x, width, y := layout.x, layout.width, layout.header_y
	// Keep the history window's scroll position while its details are open.
	ui.begin_window(ctx, theme_rect(workbench_main_rect(x + width + PANEL_PADDING + PANEL_GAP, h), scale), "history")
	if workbench_button(ctx, face, "← History", {x, y + 1, 96, 30}, scale) {
		workspace.clear_changes(changes)
		workbench_error(state, "")
		return true
	}

	meta: string
	if changes.working {
		theme_label(ctx, title, "Uncommitted changes", {x + 108, y, width - 200, 32}, 18, THEME_TEXT, scale)
		if workbench_button(ctx, face, "Reload", {x + width - 80, y + 1, 80, 30}, scale) {
			workbench_error(state, workspace.select_working_changes(model))
		}
		branch := model.sync.branch != "" ? model.sync.branch : "Detached HEAD"
		base := changes.hash != "" ? fmt.tprintf("HEAD %s", changes.hash[:min(8, len(changes.hash))]) : "no commits yet"
		meta = fmt.tprintf("%s  ·  %s  ·  %d changed  ·  %s  ·  compared with the last commit; viewing never stages",
			workbench_repo_label(state), branch, len(changes.files), base)
	} else {
		commit := model.commits[changes.commit_index]
		theme_label(ctx, title, commit.message, {x + 108, y, width - 108 - 200, 32}, 18, THEME_TEXT, scale)
		// Start a branch or tag right here, without checking anything out.
		dialog := Workbench_Dialog.NONE
		if workbench_button(ctx, face, "Branch…", {x + width - 192, y + 1, 92, 30}, scale, id = "commit-branch") do dialog = .BRANCH
		if workbench_button(ctx, face, "Tag…", {x + width - 94, y + 1, 94, 30}, scale, id = "commit-tag") do dialog = .TAG
		if dialog != .NONE {
			if workspace.remote_busy(&state.remote) {
				workbench_error(state, "Wait for the running network operation to finish first.")
			} else {
				workbench_open_ref_dialog(ctx, state, dialog, commit.hash, workbench_commit_target(commit))
			}
		}
		meta = fmt.tprintf("%s  ·  %s  ·  %s  ·  compared with the first parent", commit.author, commit.date, changes.hash)
		if commit.tags != "" do meta = fmt.tprintf("Tagged %s  ·  %s", commit.tags, meta)
	}
	theme_label(ctx, face, meta, {x, y + 38, width, 18}, 11, THEME_MUTED, scale)

	if state.error != "" {
		workbench_message(ctx, face, state.error, {x, y + 60, width, 34}, scale)
		layout.panes_y += 34
	}
	if len(changes.files) == 0 {
		empty := changes.working ? "No uncommitted changes. The working tree matches the last commit." : "This commit has no file changes."
		theme_label(ctx, face, empty, {x, layout.panes_y + 24, width, 36}, 15, THEME_MUTED, scale, {.CENTER})
		// The working tree still shows its (empty) file list and commit form.
		return !changes.working
	}
	return false
}

// The list of changed files. In the working tree it also has a check box per
// file, Stage/Unstage for the checked files (or the viewed file when none is
// checked), and the commit form at the bottom.
@(private = "file")
changes_file_list :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench,
	layout: Changes_Layout, scale: f32) -> (stop: bool) {
	model := &state.model
	changes := &model.changes
	working := changes.working
	x, y, width, bottom := layout.x, layout.panes_y, layout.files_w, layout.bottom
	ui.begin_window(ctx, theme_rect({x, y, width, bottom - y}, scale), "commit-files")

	title_x: f32 = working ? 30 : 0
	if working && len(changes.files) > 0 {
		all := true
		for file in changes.files do all = all && file.selected
		if workbench_check(ctx, face, "check-all-files", &all, {x + 4, y + 2, 20, 20}, scale) {
			for &file in changes.files do file.selected = all
		}
	}
	theme_label(ctx, title, "Changed files", {x + title_x, y, width - title_x - 40, 24}, 13, THEME_TEXT, scale)
	theme_label(ctx, face, fmt.tprintf("%d", len(changes.files)), {x + width - 40, y, 40, 24}, 11, THEME_MUTED, scale, {.RIGHT})

	list_top := y + 32
	list_bottom := bottom
	if working {
		if staging_buttons(ctx, face, state, x, list_top, width, scale) do return true
		list_top += 50
		list_bottom = bottom - 108
		theme_box(ctx, {x, list_bottom + 4, width, 1}, THEME_LINE, 0, scale)
		if workbench_commit_form(ctx, face, state, x, bottom - 100, width, scale) do return true
	}

	viewport := ui.Rect2d{x, list_top, width, list_bottom - list_top}
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(changes.files), FILE_ROW_HEIGHT, scale)
	chosen := -1
	for i in first..<last {
		row_y := viewport.y + f32(i) * FILE_ROW_HEIGHT - offset
		selected := i == changes.file.index
		if changed_file_row(ctx, face, mono, &changes.files[i], i, selected, working, viewport.x, row_y, width, scale) {
			chosen = i
		}
	}
	workbench_scroll_end(ctx, viewport, scale)
	if chosen >= 0 && chosen != changes.file.index {
		workbench_error(state, workspace.select_file(model, chosen))
		workbench_reset_windows(ctx, "commit-diff")
	}
	return false
}

// Stage and Unstage, with a hint saying which files they apply to.
@(private = "file")
staging_buttons :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y, width, scale: f32) -> (stop: bool) {
	model := &state.model
	button_w := (width - 6) * 0.5
	targets := workspace.stage_targets(model.changes)
	if workbench_button(ctx, face, "Stage", {x, y, button_w, 28}, scale, id = "stage-files") {
		workbench_error(state, workspace.stage_files(model, targets[:]))
		return true
	}
	if workbench_button(ctx, face, "Unstage", {x + button_w + 6, y, button_w, 28}, scale, id = "unstage-files") {
		workbench_error(state, workspace.unstage_files(model, targets[:]))
		return true
	}
	checked := 0
	for file in model.changes.files do if file.selected do checked += 1
	hint := "Applies to the viewed file · check files to pick several"
	if checked > 0 do hint = fmt.tprintf("Applies to %d checked file%s", checked, checked == 1 ? "" : "s")
	theme_label(ctx, face, hint, {x + 2, y + 30, width - 2, 16}, 10, THEME_MUTED, scale)
	return false
}

// One row of the file list: status badge, file name and folder (and, in the
// working tree, a check box and the stage status). Returns true when clicked.
@(private = "file")
changed_file_row :: proc(ctx: ^ui.UiContext, face, mono: ^font_core.Face, file: ^workspace.Changed_File,
	index: int, selected, working: bool, x, y, width, scale: f32) -> (clicked: bool) {
	clicked = workbench_row_button(ctx, face, fmt.tprintf("%d:%s", index, file.path), {x, y, width - 7, 40}, selected, scale)
	badge, _, color := workbench_file_status(file^)
	if !working {
		theme_label(ctx, mono, badge, {x + 9, y + 2, 20, 22}, 12, color, scale)
		theme_label(ctx, face, filepath.base(file.path), {x + 30, y + 3, width - 45, 20}, 13, THEME_TEXT, scale)
		theme_label(ctx, face, file.path, {x + 30, y + 22, width - 45, 15}, 10, THEME_MUTED, scale)
		return
	}
	workbench_check(ctx, face, fmt.tprintf("check:%s", file.path), &file.selected, {x + 6, y + 10, 20, 20}, scale)
	theme_label(ctx, mono, badge, {x + 32, y + 2, 16, 22}, 12, color, scale)
	theme_label(ctx, face, filepath.base(file.path), {x + 48, y + 3, width - 63, 20}, 13, THEME_TEXT, scale)
	stage, stage_color := workbench_stage_status(file^)
	theme_label(ctx, face, stage, {x + 48, y + 22, 76, 15}, 10, stage_color, scale)
	theme_label(ctx, face, file.path, {x + 124, y + 22, width - 139, 15}, 10, THEME_MUTED, scale)
	return
}

// The selected file: its name and a one-line description, then either the
// spreadsheet grid (workbooks) or the line-by-line diff.
@(private = "file")
changes_diff :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench,
	layout: Changes_Layout, scale: f32) {
	model := &state.model
	changes := &model.changes
	x, y, width, bottom := layout.diff_x, layout.panes_y, layout.diff_w, layout.bottom
	ui.begin_window(ctx, theme_rect({x, y, width, bottom - y}, scale), "commit-diff")

	file := changes.files[changes.file.index]
	_, status, color := workbench_file_status(file)
	// A gitlink: say which commits are involved and offer to go inside.
	submodule := workspace.submodule_for_path(model^, file.path)
	// Workbooks open as a spreadsheet grid; the row-by-row text stays a click away.
	grid := changes.file.workbook && !changes.file.binary && len(changes.file.grid.sheets) > 0
	if grid do workbench_grid_sync(state, fmt.tprintf("%s|%v|%s", changes.hash, changes.working, file.path))
	header_w := width
	if submodule >= 0 {
		header_w = width - 140
	} else if grid {
		header_w = width - 150
	}
	theme_label(ctx, title, file.path, {x, y, header_w, 22}, 14, THEME_TEXT, scale)

	detail := status
	if file.status == git.DELTA_RENAMED do detail = fmt.tprintf("Renamed from %s", file.old_path)
	if file.old_mode != 0 && file.new_mode != 0 && file.old_mode != file.new_mode {
		detail = fmt.tprintf("%s · mode %o → %o", detail, file.old_mode, file.new_mode)
	}

	if grid {
		// Grid / Text toggle.
		if workbench_button(ctx, face, "Grid", {x + width - 142, y - 2, 70, 28}, scale, !state.grid.text, id = "workbook-grid") && state.grid.text {
			state.grid.text = false
			workbench_reset_windows(ctx, "commit-diff")
		}
		if workbench_button(ctx, face, "Text", {x + width - 70, y - 2, 70, 28}, scale, state.grid.text, id = "workbook-text") && !state.grid.text {
			state.grid.text = true
			workbench_reset_windows(ctx, "commit-diff")
		}
		if !state.grid.text {
			detail = fmt.tprintf("%s · spreadsheet view · green rows added, red removed, amber cells changed", detail)
			theme_label(ctx, face, detail, {x, y + 22, header_w, 16}, 11, color, scale)
			workbench_workbook_ui(ctx, face, title, mono, state, x, y + 50, width, bottom, scale)
			return
		}
	}
	if changes.file.workbook && !changes.file.binary {
		detail = fmt.tprintf("%s · spreadsheet compared row by row · numbers are rows, cells separated by |", detail)
	}
	if submodule >= 0 {
		label, explanation := workspace.submodule_describe(model.submodules[submodule], workbench_repo_label(state))
		detail = fmt.tprintf("Submodule · %s · %s", label, explanation)
		if workbench_button(ctx, face, "Open submodule →", {x + width - 132, y - 2, 132, 28}, scale, true, id = "open-submodule") {
			if workbench_enter_submodule(state, submodule) do workbench_reset_scroll(ctx)
			return
		}
	}
	theme_label(ctx, face, detail, {x, y + 22, header_w, 16}, 11, color, scale)
	theme_box(ctx, {x, y + 44, width, 1}, THEME_LINE, 0, scale)

	viewport := ui.Rect2d{x, y + 50, width, bottom - y - 80}
	if placeholder := diff_placeholder(changes.file, submodule >= 0); placeholder != "" {
		theme_label(ctx, face, placeholder, {x + 12, viewport.y + 20, width - 24, 60}, 13, THEME_MUTED, scale)
	}
	content_width := diff_lines(ctx, mono, &changes.file, viewport, scale)

	// Footer: line counts, and sideways scroll buttons for long lines.
	theme_label(ctx, mono, fmt.tprintf("+%d", changes.file.additions), {x, bottom - 24, 70, 22}, 12, THEME_ADDITION_TEXT, scale)
	theme_label(ctx, mono, fmt.tprintf("-%d", changes.file.deletions), {x + 70, bottom - 24, 70, 22}, 12, THEME_DELETION_TEXT, scale)
	if content_width > width {
		scroll := &ctx.windows[ctx.window_index].scroll_offset.x
		if workbench_button(ctx, face, "←", {x + width - 64, bottom - 26, 30, 26}, scale, id = "diff-left") {
			scroll^ = max(0, scroll^ - 240 * scale)
		}
		if workbench_button(ctx, face, "→", {x + width - 30, bottom - 26, 30, 26}, scale, id = "diff-right") {
			scroll^ = min((content_width - width) * scale, scroll^ + 240 * scale)
		}
	}
}

// Explains an empty diff (binary files, unchanged workbook cells, renames…);
// empty when there are lines to show.
@(private = "file")
diff_placeholder :: proc(file: workspace.File_Changes, is_submodule: bool) -> string {
	switch {
	case file.binary && file.note != "":
		return file.note
	case file.binary:
		return "Binary file changed — no text diff available."
	case len(file.lines) > 0:
		return ""
	case file.workbook:
		return "Workbook changed, but no cell values or formulas differ (formatting, comments, sizes or other content)."
	case is_submodule:
		return "Only the contents of the submodule changed. Open it to see and commit them."
	}
	return "No text changes (empty file, rename, or file mode only)."
}

// Draws the visible diff lines inside a scroll area. Returns the width of the
// widest line, which can exceed the viewport and then scrolls sideways.
@(private = "file")
diff_lines :: proc(ctx: ^ui.UiContext, mono: ^font_core.Face, file: ^workspace.File_Changes,
	viewport: ui.Rect2d, scale: f32) -> (content_width: f32) {
	// Width of one monospaced character, used to place changed-cell highlights.
	char_w: f32 = 8
	if ctx.measure_text != nil do char_w = ctx.measure_text(ui.UiFont(uintptr(mono)), "M", 13 * scale).x / scale
	content_width = max(viewport.width, DIFF_TEXT_X + f32(file.max_columns) * char_w + 20)
	line_h :: DIFF_LINE_HEIGHT

	first, last, offset := workbench_scroll_begin(ctx, viewport, len(file.lines), line_h, scale, content_width)
	scroll_x := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	line_x := viewport.x - scroll_x // Text scrolls sideways; line backgrounds stay put.
	for i in first..<last {
		line := file.lines[i]
		y := viewport.y + f32(i) * line_h - offset
		fill, text_color, sign := THEME_CARD, THEME_TEXT, " "
		switch line.kind {
		case .ADDITION: fill, text_color, sign = THEME_ADDITION, THEME_ADDITION_TEXT, "+"
		case .DELETION: fill, text_color, sign = THEME_DELETION, THEME_DELETION_TEXT, "-"
		case .HUNK: fill, text_color = THEME_SURFACE, THEME_MUTED
		case .NOTE: text_color = THEME_MUTED
		case .CONTEXT:
		}
		theme_box(ctx, {viewport.x, y, viewport.width, line_h}, fill, 0, scale)
		if line.kind == .HUNK {
			theme_label(ctx, mono, line.text, {line_x + 10, y, content_width - 20, line_h}, 12, text_color, scale)
			continue
		}
		// Changed cells within a workbook row get a stronger tint behind the text.
		strong := line.kind == .ADDITION ? THEME_ADDITION_STRONG : THEME_DELETION_STRONG
		for span in file.spans[line.span_start:][:line.span_count] {
			span_x := line_x + DIFF_TEXT_X + f32(span.start) * char_w - 1
			theme_box(ctx, {span_x, y + 3, f32(span.end - span.start) * char_w + 2, line_h - 6}, strong, 3, scale)
		}
		if line.old_line > 0 {
			theme_label(ctx, mono, fmt.tprintf("%d", line.old_line), {line_x + DIFF_OLD_LINE_X, y, 40, line_h}, 11, THEME_MUTED, scale, {.RIGHT})
		}
		if line.new_line > 0 {
			theme_label(ctx, mono, fmt.tprintf("%d", line.new_line), {line_x + DIFF_NEW_LINE_X, y, 40, line_h}, 11, THEME_MUTED, scale, {.RIGHT})
		}
		theme_label(ctx, mono, sign, {line_x + DIFF_SIGN_X, y, 14, line_h}, 13, text_color, scale)
		theme_label(ctx, mono, line.text, {line_x + DIFF_TEXT_X, y, content_width - DIFF_TEXT_X, line_h}, 13, text_color, scale)
	}
	workbench_scroll_end(ctx, viewport, scale, true)
	return
}
