package app

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

GITARIS_DIFF_FONT :: #load("../../assets/fonts/GeistMono/GeistMono-Regular.ttf")
GITARIS_ADDITION :: [4]f32{0.84, 0.93, 0.80, 1}
GITARIS_DELETION :: [4]f32{0.97, 0.85, 0.82, 1}
GITARIS_ADDITION_STRONG :: [4]f32{0.66, 0.85, 0.58, 1}
GITARIS_DELETION_STRONG :: [4]f32{0.94, 0.66, 0.60, 1}
GITARIS_ADD_TEXT ::[4]f32{0.20, 0.42, 0.14, 1}
GITARIS_DELETE_TEXT :: [4]f32{0.62, 0.22, 0.16, 1}
GITARIS_DIFF_LINE :: 22

gitaris_file_status :: proc(file: workspace.Changed_File) -> (string, string, [4]f32) {
	if file.old_mode == git.FILEMODE_COMMIT || file.new_mode == git.FILEMODE_COMMIT {
		switch file.status {
		case git.DELTA_ADDED: return "S", "Submodule added", GITARIS_ADD_TEXT
		case git.DELTA_DELETED: return "S", "Submodule removed", GITARIS_DELETE_TEXT
		case: return "S", "Submodule", TEMPLATE_ACCENT
		}
	}
	switch file.status {
	case git.DELTA_ADDED: return "A", "Added", GITARIS_ADD_TEXT
	case git.DELTA_DELETED: return "D", "Deleted", GITARIS_DELETE_TEXT
	case git.DELTA_RENAMED: return "R", "Renamed", TEMPLATE_ACCENT
	case git.DELTA_COPIED: return "C", "Copied", TEMPLATE_ACCENT
	case git.DELTA_TYPECHANGE: return "T", "Type changed", TEMPLATE_MUTED
	case git.DELTA_UNTRACKED: return "U", "Untracked (new, not staged)", GITARIS_ADD_TEXT
	case git.DELTA_CONFLICTED: return "!", "Conflicted · resolve in the Merge editor", GITARIS_DELETE_TEXT
	case git.DELTA_UNREADABLE: return "?", "Unreadable", TEMPLATE_MUTED
	case: return "M", "Modified", TEMPLATE_ACCENT
	}
}

gitaris_stage_status :: proc(file: workspace.Changed_File) -> (string, [4]f32) {
	if file.staged && file.unstaged do return "Partly staged", TEMPLATE_ACCENT
	if file.staged do return "Staged", GITARIS_ADD_TEXT
	return "Not staged", TEMPLATE_MUTED
}

// Message box and Commit button for the working tree view. Commits exactly the
// staged files to the open repository, which the info line names. Returns
// true when a commit replaced the model this frame.
gitaris_commit_form :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Gitaris, x, y, w, scale: f32) -> bool {
	model := &state.model
	ui.style_push(ctx, gitaris_field_style(face, scale))
	ui.textbox(ctx, "commit-message", &state.commit_message, template_rect({x, y, w, 64}, scale))
	ui.style_pop(ctx)
	if len(state.commit_message.buf) == 0 {
		template_label(ctx, face, "Commit message · first line is the summary", {x + 11, y + 4, w - 22, 24}, 13, TEMPLATE_MUTED, scale)
	}
	staged := 0
	for file in model.changes.files do if file.staged do staged += 1
	target := gitaris_repo_label(state)
	info := staged > 0 ? fmt.tprintf("%d staged · into %s", staged, target) : fmt.tprintf("Nothing staged in %s", target)
	template_label(ctx, face, info, {x, y + 70, w - 176, 30}, 11, staged > 0 ? TEMPLATE_TEXT : TEMPLATE_MUTED, scale)
	// A roomier editor with a summary line, description and staged files.
	if gitaris_button(ctx, face, "Editor", {x + w - 170, y + 70, 70, 30}, scale, id = "commit-editor") {
		gitaris_open_commit_editor(ctx, state)
	}
	if !gitaris_button(ctx, face, "Commit", {x + w - 94, y + 70, 94, 30}, scale, true, id = "commit-staged") do return false
	replaced, err := gitaris_commit(ctx, state, strings.to_string(state.commit_message))
	gitaris_error(state, err)
	return replaced
}

gitaris_changes_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face,
	state: ^Gitaris, x, cw, h, scale: f32) {
	model := &state.model
	changes := &model.changes
	top: f32 = GITARIS_MENU_HEIGHT
	y0 := top + 14
	bottom := h - GITARIS_GAP - 14
	working := changes.working
	py := y0 + 64
	{
		// Keep the history window's scroll position while its details are open.
		ui.begin_window(ctx, template_rect(gitaris_main_rect(x + cw + GITARIS_PAD + GITARIS_GAP, h), scale), "history")
		if gitaris_button(ctx, face, "← History", {x, y0 + 1, 96, 30}, scale) {
			workspace.clear_changes(changes)
			gitaris_error(state, "")
			return
		}
		meta: string
		if working {
			template_label(ctx, title, "Uncommitted changes", {x + 108, y0, cw - 200, 32}, 18, TEMPLATE_TEXT, scale)
			if gitaris_button(ctx, face, "Reload", {x + cw - 80, y0 + 1, 80, 30}, scale) {
				gitaris_error(state, workspace.select_working_changes(model))
			}
			branch := model.sync.branch != "" ? model.sync.branch : "Detached HEAD"
			base := changes.hash != "" ? fmt.tprintf("HEAD %s", changes.hash[:min(8, len(changes.hash))]) : "no commits yet"
			meta = fmt.tprintf("%s  ·  %s  ·  %d changed  ·  %s  ·  compared with the last commit; viewing never stages",
				gitaris_repo_label(state), branch, len(changes.files), base)
		} else {
			commit := model.commits[changes.commit_index]
			template_label(ctx, title, commit.message, {x + 108, y0, cw - 108 - 200, 32}, 18, TEMPLATE_TEXT, scale)
			// Start a branch or tag right here, without checking anything out.
			busy := workspace.remote_busy(&state.remote)
			if gitaris_button(ctx, face, "Branch…", {x + cw - 192, y0 + 1, 92, 30}, scale, id = "commit-branch") {
				if busy do gitaris_error(state, "Wait for the running network operation to finish first.")
				else do gitaris_open_ref_dialog(ctx, state, .BRANCH, commit.hash, gitaris_commit_target(commit))
			}
			if gitaris_button(ctx, face, "Tag…", {x + cw - 94, y0 + 1, 94, 30}, scale, id = "commit-tag") {
				if busy do gitaris_error(state, "Wait for the running network operation to finish first.")
				else do gitaris_open_ref_dialog(ctx, state, .TAG, commit.hash, gitaris_commit_target(commit))
			}
			meta = fmt.tprintf("%s  ·  %s  ·  %s  ·  compared with the first parent", commit.author, commit.date, changes.hash)
			if commit.tags != "" do meta = fmt.tprintf("Tagged %s  ·  %s", commit.tags, meta)
		}
		template_label(ctx, face, meta, {x, y0 + 38, cw, 18}, 11, TEMPLATE_MUTED, scale)
		if state.error != "" {
			gitaris_message(ctx, face, state.error, {x, y0 + 60, cw, 34}, scale)
			py += 34
		}
		if len(changes.files) == 0 {
			empty := working ? "No uncommitted changes. The working tree matches the last commit." : "This commit has no file changes."
			template_label(ctx, face, empty, {x, py + 24, cw, 36}, 15, TEMPLATE_MUTED, scale, {.CENTER})
			if !working do return
		}
	}

	fw := clamp(cw * 0.3, 220, 300)
	dx := x + fw + 14
	dw := cw - fw - 14
	{
		ui.begin_window(ctx, template_rect({x, py, fw, bottom - py}, scale), "commit-files")
		// Working changes get a check per file plus Stage/Unstage for the checked
		// files (or the viewed file when none is checked), and the commit form.
		title_x: f32 = working ? 30 : 0
		if working && len(changes.files) > 0 {
			all := true
			for file in changes.files do all = all && file.selected
			if gitaris_check(ctx, face, "check-all-files", &all, {x + 4, py + 2, 20, 20}, scale) {
				for &file in changes.files do file.selected = all
			}
		}
		template_label(ctx, title, "Changed files", {x + title_x, py, fw - title_x - 40, 24}, 13, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("%d", len(changes.files)), {x + fw - 40, py, 40, 24}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
		list_top := py + 32
		list_bottom := bottom
		if working {
			checked := 0
			for file in changes.files do if file.selected do checked += 1
			bw := (fw - 6) * 0.5
			targets := workspace.stage_targets(changes^)
			if gitaris_button(ctx, face, "Stage", {x, list_top, bw, 28}, scale, id = "stage-files") {
				gitaris_error(state, workspace.stage_files(model, targets[:]))
				return
			}
			if gitaris_button(ctx, face, "Unstage", {x + bw + 6, list_top, bw, 28}, scale, id = "unstage-files") {
				gitaris_error(state, workspace.unstage_files(model, targets[:]))
				return
			}
			hint := checked > 0 ? fmt.tprintf("Applies to %d checked file%s", checked, checked == 1 ? "" : "s") : "Applies to the viewed file · check files to pick several"
			template_label(ctx, face, hint, {x + 2, list_top + 30, fw - 2, 16}, 10, TEMPLATE_MUTED, scale)
			list_top += 50
			list_bottom = bottom - 108
			template_box(ctx, {x, list_bottom + 4, fw, 1}, TEMPLATE_LINE, 0, scale)
			if gitaris_commit_form(ctx, face, state, x, bottom - 100, fw, scale) do return
		}
		viewport := ui.Rect2d{x, list_top, fw, list_bottom - list_top}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(changes.files), 44, scale)
		chosen := -1
		for i in first..<last {
			file := &changes.files[i]
			y := viewport.y + f32(i) * 44 - offset
			if gitaris_row_button(ctx, face, fmt.tprintf("%d:%s", i, file.path), {viewport.x, y, fw - 7, 40}, i == changes.file.index, scale) do chosen = i
			badge, _, color := gitaris_file_status(file^)
			if !working {
				template_label(ctx, mono, badge, {viewport.x + 9, y + 2, 20, 22}, 12, color, scale)
				template_label(ctx, face, filepath.base(file.path), {viewport.x + 30, y + 3, fw - 45, 20}, 13, TEMPLATE_TEXT, scale)
				template_label(ctx, face, file.path, {viewport.x + 30, y + 22, fw - 45, 15}, 10, TEMPLATE_MUTED, scale)
				continue
			}
			gitaris_check(ctx, face, fmt.tprintf("check:%s", file.path), &file.selected, {viewport.x + 6, y + 10, 20, 20}, scale)
			template_label(ctx, mono, badge, {viewport.x + 32, y + 2, 16, 22}, 12, color, scale)
			template_label(ctx, face, filepath.base(file.path), {viewport.x + 48, y + 3, fw - 63, 20}, 13, TEMPLATE_TEXT, scale)
			stage, stage_color := gitaris_stage_status(file^)
			template_label(ctx, face, stage, {viewport.x + 48, y + 22, 76, 15}, 10, stage_color, scale)
			template_label(ctx, face, file.path, {viewport.x + 124, y + 22, fw - 139, 15}, 10, TEMPLATE_MUTED, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if chosen >= 0 && chosen != changes.file.index {
			gitaris_error(state, workspace.select_file(model, chosen))
			gitaris_reset_windows(ctx, "commit-diff")
		}
	}
	if len(changes.files) == 0 do return
	{
		ui.begin_window(ctx, template_rect({dx, py, dw, bottom - py}, scale), "commit-diff")
		file := changes.files[changes.file.index]
		_, status, color := gitaris_file_status(file)
		// A gitlink: say which commits are involved and offer to go inside.
		submodule := workspace.submodule_for_path(model^, file.path)
		// Workbooks open as a spreadsheet grid; the row-by-row text stays a click away.
		grid := changes.file.workbook && !changes.file.binary && len(changes.file.grid.sheets) > 0
		if grid do gitaris_grid_sync(state, fmt.tprintf("%s|%v|%s", changes.hash, working, file.path))
		header_w := submodule >= 0 ? dw - 140 : (grid ? dw - 150 : dw)
		template_label(ctx, title, file.path, {dx, py, header_w, 22}, 14, TEMPLATE_TEXT, scale)
		detail := status
		if file.status == git.DELTA_RENAMED do detail = fmt.tprintf("Renamed from %s", file.old_path)
		if file.old_mode != 0 && file.new_mode != 0 && file.old_mode != file.new_mode {
			detail = fmt.tprintf("%s · mode %o → %o", detail, file.old_mode, file.new_mode)
		}
		if grid {
			if gitaris_button(ctx, face, "Grid", {dx + dw - 142, py - 2, 70, 28}, scale, !state.grid.text, id = "workbook-grid") && state.grid.text {
				state.grid.text = false
				gitaris_reset_windows(ctx, "commit-diff")
			}
			if gitaris_button(ctx, face, "Text", {dx + dw - 70, py - 2, 70, 28}, scale, state.grid.text, id = "workbook-text") && !state.grid.text {
				state.grid.text = true
				gitaris_reset_windows(ctx, "commit-diff")
			}
		}
		if grid && !state.grid.text {
			detail = fmt.tprintf("%s · spreadsheet view · green rows added, red removed, amber cells changed", detail)
			template_label(ctx, face, detail, {dx, py + 22, header_w, 16}, 11, color, scale)
			gitaris_workbook_ui(ctx, face, title, mono, state, dx, py + 50, dw, bottom, scale)
			return
		}
		if changes.file.workbook && !changes.file.binary {
			detail = fmt.tprintf("%s · spreadsheet compared row by row · numbers are rows, cells separated by |", detail)
		}
		if submodule >= 0 {
			info := model.submodules[submodule]
			label, explanation := workspace.submodule_describe(info, gitaris_repo_label(state))
			detail = fmt.tprintf("Submodule · %s · %s", label, explanation)
			if gitaris_button(ctx, face, "Open submodule →", {dx + dw - 132, py - 2, 132, 28}, scale, true, id = "open-submodule") {
				if gitaris_enter_submodule(state, submodule) do gitaris_reset_scroll(ctx)
				return
			}
		}
		template_label(ctx, face, detail, {dx, py + 22, header_w, 16}, 11, color, scale)
		template_box(ctx, {dx, py + 44, dw, 1}, TEMPLATE_LINE, 0, scale)
		viewport := ui.Rect2d{dx, py + 50, dw, bottom - py - 80}
		if changes.file.binary && changes.file.note != "" {
			template_label(ctx, face, changes.file.note, {dx + 12, viewport.y + 20, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		} else if changes.file.binary {
			template_label(ctx, face, "Binary file changed — no text diff available.", {dx + 12, viewport.y + 20, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		} else if changes.file.workbook && len(changes.file.lines) == 0 {
			template_label(ctx, face, "Workbook changed, but no cell values or formulas differ (formatting, comments, sizes or other content).", {dx + 12, viewport.y + 20, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		} else if len(changes.file.lines) == 0 {
			text := submodule >= 0 ? "Only the contents of the submodule changed. Open it to see and commit them." : "No text changes (empty file, rename, or file mode only)."
			template_label(ctx, face, text, {dx + 12, viewport.y + 20, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		}
		cell: f32 = 8
		if ctx.measure_text != nil do cell = ctx.measure_text(ui.UiFont(uintptr(mono)), "M", 13 * scale).x / scale
		content_width := max(dw, 112 + f32(changes.file.max_columns) * cell + 20)
		line_h :: GITARIS_DIFF_LINE
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(changes.file.lines), line_h, scale, content_width)
		horizontal := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
		for i in first..<last {
			line := changes.file.lines[i]
			y := viewport.y + f32(i) * line_h - offset
			rx := dx - horizontal
			fill, text_color := TEMPLATE_CARD, TEMPLATE_TEXT
			sign := " "
			switch line.kind {
			case .ADDITION: fill, text_color, sign = GITARIS_ADDITION, GITARIS_ADD_TEXT, "+"
			case .DELETION: fill, text_color, sign = GITARIS_DELETION, GITARIS_DELETE_TEXT, "-"
			case .HUNK: fill, text_color = TEMPLATE_SURFACE, TEMPLATE_MUTED
			case .NOTE: text_color = TEMPLATE_MUTED
			case .CONTEXT:
			}
			template_box(ctx, {dx, y, dw, line_h}, fill, 0, scale)
			if line.kind == .HUNK {
				template_label(ctx, mono, line.text, {rx + 10, y, content_width - 20, line_h}, 12, text_color, scale)
				continue
			}
			// Changed cells within a workbook row get a stronger tint behind the text.
			strong := line.kind == .ADDITION ? GITARIS_ADDITION_STRONG : GITARIS_DELETION_STRONG
			for span in changes.file.spans[line.span_start:][:line.span_count] {
				template_box(ctx, {rx + 112 + f32(span.start) * cell - 1, y + 3, f32(span.end - span.start) * cell + 2, line_h - 6}, strong, 3, scale)
			}
			if line.old_line > 0 do template_label(ctx, mono, fmt.tprintf("%d", line.old_line), {rx + 4, y, 40, line_h}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
			if line.new_line > 0 do template_label(ctx, mono, fmt.tprintf("%d", line.new_line), {rx + 48, y, 40, line_h}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
			template_label(ctx, mono, sign, {rx + 94, y, 14, line_h}, 13, text_color, scale)
			template_label(ctx, mono, line.text, {rx + 112, y, content_width - 112, line_h}, 13, text_color, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale, true)
		template_label(ctx, mono, fmt.tprintf("+%d", changes.file.additions), {dx, bottom - 24, 70, 22}, 12, GITARIS_ADD_TEXT, scale)
		template_label(ctx, mono, fmt.tprintf("-%d", changes.file.deletions), {dx + 70, bottom - 24, 70, 22}, 12, GITARIS_DELETE_TEXT, scale)
		if content_width > dw {
			scroll := &ctx.windows[ctx.window_index].scroll_offset.x
			if gitaris_button(ctx, face, "←", {dx + dw - 64, bottom - 26, 30, 26}, scale, id = "diff-left") do scroll^ = max(0, scroll^ - 240 * scale)
			if gitaris_button(ctx, face, "→", {dx + dw - 30, bottom - 26, 30, 26}, scale, id = "diff-right") do scroll^ = min((content_width - dw) * scale, scroll^ + 240 * scale)
		}
	}
}
