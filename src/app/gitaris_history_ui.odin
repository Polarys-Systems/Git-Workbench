package app

import "core:fmt"
import "core:path/filepath"
import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"

gitaris_history_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face,
	state: ^Gitaris, w, h, scale: f32, mono: ^font_core.Face = nil) {
	model := &state.model
	top: f32 = GITARIS_MENU_HEIGHT
	side_w: f32 = 280
	x: f32 = 348
	cw := w - x - 48
	{
		ui.begin_window(ctx, template_rect({0, 0, w, h}, scale), "workspace-background")
		template_panel(ctx, {24, top + 24, side_w, h - top - 48}, TEMPLATE_SURFACE, 22, scale)
		template_panel(ctx, {324, top + 24, w - 348, h - top - 48}, TEMPLATE_SURFACE, 22, scale)
	}
	{
		ui.begin_window(ctx, template_rect({40, top + 40, side_w - 32, h - top - 80}, scale), "branches")
		template_label(ctx, icons, "\uf1d3", {48, top + 48, 32, 36}, 27, TEMPLATE_ACCENT, scale)
		template_label(ctx, title, "git-workbench", {91, top + 48, 189, 36}, 24, TEMPLATE_TEXT, scale)
		template_label(ctx, face, "PROJECT", {48, top + 120, 232, 22}, 11, TEMPLATE_MUTED, scale)
		template_label(ctx, title, filepath.base(model.config.project_path), {48, top + 149, 232, 30}, 19, TEMPLATE_TEXT, scale)
		template_label(ctx, face, model.config.project_path, {48, top + 183, 232, 23}, 12, TEMPLATE_MUTED, scale)
		template_box(ctx, {48, top + 231, 232, 1}, TEMPLATE_LINE, 0, scale)
		template_label(ctx, title, "Branches", {48, top + 250, 170, 28}, 17, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("%d", len(model.branches)), {222, top + 250, 58, 28}, 12, TEMPLATE_MUTED, scale, {.RIGHT})
		viewport := ui.Rect2d{48, top + 295, 232, h - top - 413}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(model.branches), 56, scale)
		chosen := -1
		for i in first..<last {
			branch := model.branches[i]
			y := viewport.y + f32(i) * 56 - offset
			selected := i == model.selected && !model.all_branches
			if gitaris_row_button(ctx, face, branch.ref_name, {48, y, 224, 50}, selected, scale) do chosen = i
			template_label(ctx, icons, "\uf126", {58, y + 4, 22, 26}, 15, TEMPLATE_ACCENT, scale)
			template_label(ctx, face, branch.name, {88, y + 3, 173, 26}, 14, TEMPLATE_TEXT, scale)
			kind := branch.remote ? "Remote" : "Local"
			if branch.head do kind = branch.unborn ? "HEAD · no commits yet" : "HEAD"
			template_label(ctx, face, kind, {88, y + 29, 173, 18}, 10, TEMPLATE_MUTED, scale)
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if chosen >= 0 && (chosen != model.selected || model.all_branches) {
			gitaris_error(state, workspace.select_branch(model, chosen))
			ctx.windows[2].scroll_offset = {}
			ctx.windows[3].scroll_offset = {}
			ctx.windows[4].scroll_offset = {}
		}
		template_label(ctx, face, model.config.username, {48, h - 95, 232, 24}, 13, TEMPLATE_TEXT, scale)
		template_label(ctx, face, model.config.email, {48, h - 70, 232, 20}, 11, TEMPLATE_MUTED, scale)
	}
	if workspace.changes_open(model.changes) {
		gitaris_changes_ui(ctx, face, title, mono != nil ? mono : face, state, x, cw, h, scale)
		return
	}
	{
		ui.begin_window(ctx, template_rect({x, top + 40, cw, h - top - 80}, scale), "history")
		template_label(ctx, face, "REPOSITORY  /  HISTORY", {x + 8, top + 54, cw - 260, 24}, 11, TEMPLATE_MUTED, scale)
		if gitaris_button(ctx, face, "Working tree", {x + cw - 232, top + 51, 132, 34}, scale) {
			gitaris_error(state, workspace.select_working_changes(model))
			ctx.windows[3].scroll_offset = {}
			ctx.windows[4].scroll_offset = {}
		}
		if gitaris_button(ctx, face, "Refresh", {x + cw - 92, top + 51, 84, 34}, scale) {
			gitaris_error(state, workspace.refresh(model))
			ctx.windows[ctx.window_index].scroll_offset = {}
		}
		template_label(ctx, title, "Commit history", {x + 8, top + 98, cw - 16, 47}, 32, TEMPLATE_TEXT, scale)
		branch := model.branches[model.selected]
		template_label(ctx, icons, "\uf126", {x + 8, top + 155, 24, 28}, 17, TEMPLATE_ACCENT, scale)
		template_label(ctx, face, model.all_branches ? "All local and remote branches" : branch.name, {x + 40, top + 155, cw - 192, 28}, 16, TEMPLATE_TEXT, scale)
		if gitaris_button(ctx, face, "All branches", {x + cw - 144, top + 153, 136, 32}, scale, model.all_branches) && !model.all_branches {
			gitaris_error(state, workspace.select_history(model, model.selected, true))
			ctx.windows[ctx.window_index].scroll_offset = {}
		}
		if gitaris_field(ctx, face, "search", "", "Search loaded commits by message, author, hash or branch...", &state.search,
			{x + 8, top + 207, cw - 16, 42}, scale) == .MODIFIED {
			ctx.windows[ctx.window_index].scroll_offset = {}
		}
		if state.error != "" do gitaris_message(ctx, face, state.error, {x + 8, top + 255, cw - 16, 36}, scale)
		template_label(ctx, face, "GRAPH / COMMIT", {x + 24, top + 298, cw - 150, 24}, 10, TEMPLATE_MUTED, scale)
		template_label(ctx, face, "REVISION", {x + cw - 104, top + 298, 80, 24}, 10, TEMPLATE_MUTED, scale, {.RIGHT})
		template_box(ctx, {x + 8, top + 332, cw - 16, 1}, TEMPLATE_LINE, 0, scale)
		matches := make([dynamic]int, 0, len(model.commits), context.temp_allocator)
		query := strings.to_lower(strings.trim_space(strings.to_string(state.search)), context.temp_allocator)
		if query != "" && state.error == "" {
			template_label(ctx, face, "Search results · graph connections hidden", {x + 8, top + 255, cw - 16, 28}, 12, TEMPLATE_MUTED, scale)
		}
		for commit, i in model.commits {
			if query == "" || strings.contains(strings.to_lower(commit.message, context.temp_allocator), query) ||
				strings.contains(strings.to_lower(commit.author, context.temp_allocator), query) || strings.contains(commit.hash, query) ||
				strings.contains(strings.to_lower(commit.refs, context.temp_allocator), query) {
				append(&matches, i)
			}
		}
		viewport := ui.Rect2d{x + 8, top + 342, cw - 16, h - top - 461}
		graph_width := max(f32(44), 20 + f32(model.graph.width) * GITARIS_GRAPH_SPACING)
		content_width := max(viewport.width, graph_width + 420)
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(matches), 72, scale, content_width)
		horizontal := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
		rx := viewport.x - horizontal
		chosen := -1
		for row in first..<last {
			commit := model.commits[matches[row]]
			y := viewport.y + f32(row) * 72 - offset
			if gitaris_row_button(ctx, face, commit.hash, {viewport.x, y + 2, viewport.width - 8, 68}, false, scale) do chosen = matches[row]
			// Filtering removes intermediate commits. Draw isolated nodes then,
			// rather than inventing connections between unrelated search hits.
			gitaris_graph_row(ctx, commit.graph, rx + 16, y, scale, viewport, query == "")
			text_x := rx + graph_width + 8
			text_width := content_width - graph_width - 120
			template_label(ctx, face, commit.message, {text_x, y + 7, text_width, 29}, 15, TEMPLATE_TEXT, scale)
			metadata := fmt.tprintf("%s  /  %s", commit.author, commit.date)
			if commit.refs != "" do metadata = fmt.tprintf("%s  ·  %s", commit.refs, metadata)
			template_label(ctx, face, metadata, {text_x, y + 38, text_width, 22}, 12, commit.refs != "" ? TEMPLATE_ACCENT : TEMPLATE_MUTED, scale)
			template_label(ctx, face, commit.hash[:min(8, len(commit.hash))], {rx + content_width - 96, y + 10, 80, 28}, 12, TEMPLATE_MUTED, scale, {.RIGHT})
		}
		if len(matches) == 0 {
			message := len(model.commits) == 0 ? "No commits on this branch yet." : "No matching commits in the loaded history."
			template_label(ctx, face, message, {viewport.x, viewport.y + 32, viewport.width, 34}, 16, TEMPLATE_MUTED, scale, {.CENTER})
		}
		gitaris_scroll_end(ctx, viewport, scale, true)
		if chosen >= 0 {
			gitaris_error(state, workspace.select_commit(model, chosen))
			ctx.windows[3].scroll_offset = {}
			ctx.windows[4].scroll_offset = {}
		}
		template_label(ctx, face, fmt.tprintf("%d shown · %d loaded", len(matches), len(model.commits)), {x + 8, h - 90, cw - 248, 30}, 12, TEMPLATE_MUTED, scale)
		if content_width > viewport.width {
			scroll := &ctx.windows[ctx.window_index].scroll_offset.x
			if gitaris_button(ctx, face, "←", {x + cw - 220, h - 90, 28, 28}, scale, id = "graph-left") do scroll^ = max(0, scroll^ - 160 * scale)
			if gitaris_button(ctx, face, "→", {x + cw - 184, h - 90, 28, 28}, scale, id = "graph-right") do scroll^ = min((content_width - viewport.width) * scale, scroll^ + 160 * scale)
		}
		if model.has_more && gitaris_button(ctx, face, "Load more", {x + cw - 144, h - 94, 136, 38}, scale) {
			gitaris_error(state, workspace.load_more(model))
		}
	}
}
