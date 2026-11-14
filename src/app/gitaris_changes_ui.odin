package app

import "core:fmt"
import "core:path/filepath"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

GITARIS_DIFF_FONT :: "./assets/fonts/GeistMono/GeistMono-Regular.ttf"
GITARIS_ADDITION :: [4]f32{0.76, 0.90, 0.77, 1}
GITARIS_DELETION :: [4]f32{0.96, 0.79, 0.77, 1}
GITARIS_ADDITION_STRONG :: [4]f32{0.55, 0.81, 0.58, 1}
GITARIS_DELETION_STRONG :: [4]f32{0.93, 0.62, 0.58, 1}
GITARIS_ADD_TEXT ::[4]f32{0.18, 0.39, 0.22, 1}
GITARIS_DELETE_TEXT :: [4]f32{0.59, 0.20, 0.18, 1}

gitaris_file_status :: proc(file: workspace.Changed_File) -> (string, string, [4]f32) {
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

gitaris_changes_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face,
	state: ^Gitaris, x, cw, h, scale: f32) {
	model := &state.model
	changes := &model.changes
	top: f32 = GITARIS_MENU_HEIGHT
	{
		// Keep the history window's scroll position while its details are open.
		ui.begin_window(ctx, template_rect({x, top + 40, cw, h - top - 80}, scale), "history")
		if gitaris_button(ctx, face, "← History", {x + 8, top + 51, 124, 34}, scale) {
			workspace.clear_changes(changes)
			gitaris_error(state, "")
			return
		}
		if changes.working {
			template_label(ctx, face, "WORKING TREE CHANGES", {x + 148, top + 54, cw - 256, 26}, 11, TEMPLATE_MUTED, scale)
			if gitaris_button(ctx, face, "Reload", {x + cw - 92, top + 51, 84, 34}, scale) {
				gitaris_error(state, workspace.select_working_changes(model))
			}
			template_label(ctx, title, "Uncommitted changes", {x + 8, top + 99, cw - 16, 40}, 26, TEMPLATE_TEXT, scale)
			branch := model.sync.branch != "" ? model.sync.branch : "Detached HEAD"
			summary := fmt.tprintf("%s  /  %d changed files", branch, len(changes.files))
			template_label(ctx, face, summary, {x + 8, top + 146, cw - 16, 26}, 14, TEMPLATE_MUTED, scale)
			base := changes.hash != "" ? fmt.tprintf("HEAD %s", changes.hash) : "No commits yet"
			template_label(ctx, mono, base, {x + 8, top + 177, cw - 16, 24}, 12, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "Compared with the last commit · staged, unstaged and untracked files · nothing is staged by viewing", {x + 8, top + 209, cw - 16, 24}, 11, TEMPLATE_MUTED, scale)
		} else {
			template_label(ctx, face, "COMMIT CHANGES", {x + 148, top + 54, cw - 156, 26}, 11, TEMPLATE_MUTED, scale)
			commit := model.commits[changes.commit_index]
			template_label(ctx, title, commit.message, {x + 8, top + 99, cw - 16, 40}, 26, TEMPLATE_TEXT, scale)
			template_label(ctx, face, fmt.tprintf("%s  /  %s", commit.author, commit.date), {x + 8, top + 146, cw - 16, 26}, 14, TEMPLATE_MUTED, scale)
			template_label(ctx, mono, changes.hash, {x + 8, top + 177, cw - 16, 24}, 12, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "Compared with first parent · initial commits use an empty tree", {x + 8, top + 209, cw - 16, 24}, 11, TEMPLATE_MUTED, scale)
		}
		if state.error != "" do gitaris_message(ctx, face, state.error, {x + 8, top + 235, cw - 16, 36}, scale)
		if len(changes.files) == 0 {
			empty := changes.working ? "No uncommitted changes. The working tree matches the last commit." : "This commit has no file changes."
			template_label(ctx, face, empty, {x + 8, top + 300, cw - 16, 44}, 17, TEMPLATE_MUTED, scale, {.CENTER})
			return
		}
	}

	fw := clamp(cw * 0.27, 188, 280)
	px, py := x + fw + 24, top + 286
	dw := cw - fw - 32
	{
		ui.begin_window(ctx, template_rect({x + 8, py, fw, h - py - 64}, scale), "commit-files")
		template_label(ctx, title, "Changed files", {x + 16, py + 4, fw - 58, 28}, 16, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("%d", len(changes.files)), {x + fw - 34, py + 4, 34, 28}, 12, TEMPLATE_MUTED, scale, {.RIGHT})
		template_box(ctx, {x + 8, py + 42, fw, 1}, TEMPLATE_LINE, 0, scale)
		viewport := ui.Rect2d{x + 8, py + 52, fw, h - py - 124}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(changes.files), 58, scale)
		chosen := -1
		for i in first..<last {
			file := changes.files[i]
			y := viewport.y + f32(i) * 58 - offset
			if gitaris_row_button(ctx, face, fmt.tprintf("%d:%s", i, file.path), {viewport.x, y, fw - 7, 54}, i == changes.file.index, scale) do chosen = i
			badge, _, color := gitaris_file_status(file)
			template_label(ctx, mono, badge, {viewport.x + 9, y + 8, 20, 26}, 13, color, scale)
			template_label(ctx, face, filepath.base(file.path), {viewport.x + 36, y + 5, fw - 51, 26}, 13, TEMPLATE_TEXT, scale)
			template_label(ctx, face, file.path, {viewport.x + 36, y + 30, fw - 51, 18}, 10, TEMPLATE_MUTED, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if chosen >= 0 && chosen != changes.file.index {
			gitaris_error(state, workspace.select_file(model, chosen))
			ctx.windows[4].scroll_offset = {}
		}
	}
	{
		ui.begin_window(ctx, template_rect({px, py, dw, h - py - 64}, scale), "commit-diff")
		file := changes.files[changes.file.index]
		_, status, color := gitaris_file_status(file)
		template_label(ctx, title, file.path, {px + 8, py + 4, dw - 16, 28}, 16, TEMPLATE_TEXT, scale)
		detail := status
		if file.status == git.DELTA_RENAMED do detail = fmt.tprintf("Renamed from %s", file.old_path)
		if file.old_mode != 0 && file.new_mode != 0 && file.old_mode != file.new_mode {
			detail = fmt.tprintf("%s · mode %o → %o", detail, file.old_mode, file.new_mode)
		}
		if changes.file.workbook && !changes.file.binary {
			detail = fmt.tprintf("%s · spreadsheet compared row by row · numbers are rows, cells separated by |", detail)
		}
		template_label(ctx, face, detail, {px + 8, py + 35, dw - 16, 20}, 11, color, scale)
		template_box(ctx, {px, py + 64, dw, 1}, TEMPLATE_LINE, 0, scale)
		viewport := ui.Rect2d{px, py + 74, dw, h - py - 178}
		if changes.file.binary && changes.file.note != "" {
			template_label(ctx, face, changes.file.note, {px + 12, viewport.y + 24, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		} else if changes.file.binary {
			template_label(ctx, face, "Binary file changed — no text diff available.", {px + 12, viewport.y + 24, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		} else if changes.file.workbook && len(changes.file.lines) == 0 {
			template_label(ctx, face, "Workbook changed, but no cell values or formulas differ (formatting, comments, sizes or other content).", {px + 12, viewport.y + 24, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		} else if len(changes.file.lines) == 0 {
			template_label(ctx, face, "No text changes (empty file, rename, or file mode only).", {px + 12, viewport.y + 24, dw - 24, 60}, 13, TEMPLATE_MUTED, scale)
		}
		cell: f32 = 8
		if ctx.measure_text != nil do cell = ctx.measure_text(ui.UiFont(uintptr(mono)), "M", 13 * scale).x / scale
		content_width := max(dw, 112 + f32(changes.file.max_columns) * cell + 20)
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(changes.file.lines), 24, scale, content_width)
		horizontal := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
		for i in first..<last {
			line := changes.file.lines[i]
			y := viewport.y + f32(i) * 24 - offset
			rx := px - horizontal
			fill, text_color := TEMPLATE_CARD, TEMPLATE_TEXT
			sign := " "
			switch line.kind {
			case .ADDITION: fill, text_color, sign = GITARIS_ADDITION, GITARIS_ADD_TEXT, "+"
			case .DELETION: fill, text_color, sign = GITARIS_DELETION, GITARIS_DELETE_TEXT, "-"
			case .HUNK: fill, text_color = TEMPLATE_SELECTED, TEMPLATE_ACCENT
			case .NOTE: text_color = TEMPLATE_MUTED
			case .CONTEXT:
			}
			template_box(ctx, {px, y, dw, 24}, fill, 0, scale)
			if line.kind == .HUNK {
				template_label(ctx, mono, line.text, {rx + 10, y, content_width - 20, 24}, 12, text_color, scale)
				continue
			}
			// Changed cells within a workbook row get a stronger tint behind the text.
			strong := line.kind == .ADDITION ? GITARIS_ADDITION_STRONG : GITARIS_DELETION_STRONG
			for span in changes.file.spans[line.span_start:][:line.span_count] {
				template_box(ctx, {rx + 112 + f32(span.start) * cell - 1, y + 3, f32(span.end - span.start) * cell + 2, 18}, strong, 3, scale)
			}
			if line.old_line > 0 do template_label(ctx, mono, fmt.tprintf("%d", line.old_line), {rx + 4, y, 40, 24}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
			if line.new_line > 0 do template_label(ctx, mono, fmt.tprintf("%d", line.new_line), {rx + 48, y, 40, 24}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
			template_label(ctx, mono, sign, {rx + 94, y, 14, 24}, 13, text_color, scale)
			template_label(ctx, mono, line.text, {rx + 112, y, content_width - 112, 24}, 13, text_color, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale, true)
		template_label(ctx, mono, fmt.tprintf("+%d", changes.file.additions), {px + 8, h - 88, 78, 24}, 12, GITARIS_ADD_TEXT, scale)
		template_label(ctx, mono, fmt.tprintf("-%d", changes.file.deletions), {px + 88, h - 88, 78, 24}, 12, GITARIS_DELETE_TEXT, scale)
		if content_width > dw {
			scroll := &ctx.windows[ctx.window_index].scroll_offset.x
			if gitaris_button(ctx, face, "←", {px + dw - 62, h - 90, 26, 26}, scale, id = "diff-left") do scroll^ = max(0, scroll^ - 240 * scale)
			if gitaris_button(ctx, face, "→", {px + dw - 30, h - 90, 26, 26}, scale, id = "diff-right") do scroll^ = min((content_width - dw) * scale, scroll^ + 240 * scale)
		}
	}
}
