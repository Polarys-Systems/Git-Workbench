package app

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"

GITARIS_SIDEBAR_WIDTH :: 248

// Dot color for a submodule: lime when it matches what the parent records,
// orange when it needs attention, gray when it is not checked out.
gitaris_submodule_color :: proc(info: workspace.Submodule_Info) -> [4]f32 {
	if info.state == .NOT_INITIALIZED do return TEMPLATE_MUTED
	if workspace.submodule_attention(info) do return TEMPLATE_WARNING
	return TEMPLATE_HIGHLIGHT
}

// Main content panel beside the sidebar: its card rectangle.
gitaris_main_rect :: proc(w, h: f32) -> ui.Rect2d {
	x: f32 = GITARIS_GAP * 2 + GITARIS_SIDEBAR_WIDTH
	return {x, GITARIS_MENU_HEIGHT, w - x - GITARIS_GAP, h - GITARIS_MENU_HEIGHT - GITARIS_GAP}
}

gitaris_sidebar_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face, state: ^Gitaris, h, scale: f32) {
	model := &state.model
	top: f32 = GITARIS_MENU_HEIGHT
	sx, sw: f32 = GITARIS_GAP, GITARIS_SIDEBAR_WIDTH
	bottom := h - GITARIS_GAP
	x, iw := sx + 14, sw - 28
	in_submodule := len(state.parents) > 0
	submodule_rows := min(len(model.submodules), 5)
	submodule_height := len(model.submodules) > 0 ? 36 + f32(submodule_rows) * 40 : 0
	{
		ui.begin_window(ctx, template_rect({sx, top, sw, bottom - top}, scale), "branches")
		// Which repository is open: always visible, tagged inside a submodule.
		y := top + 14
		if in_submodule {
			template_tag(ctx, face, "SUBMODULE", x, y, TEMPLATE_HIGHLIGHT, TEMPLATE_DARK, scale)
			template_label(ctx, face, fmt.tprintf("of %s", gitaris_parent_label(state)), {x + 82, y, iw - 82, 18}, 11, TEMPLATE_MUTED, scale)
		} else {
			template_tag(ctx, face, "REPOSITORY", x, y, TEMPLATE_BUTTON, TEMPLATE_MUTED, scale)
		}
		// Repositories inside WSL are named with their distribution.
		if distribution := workspace.wsl_distribution(model.config.project_path); distribution != "" {
			text := fmt.tprintf("WSL · %s", distribution)
			template_tag(ctx, face, text, x + iw - template_text_width(ctx, face, text, 10, scale) - 14, y, TEMPLATE_ACCENT, TEMPLATE_LIGHT, scale)
		}
		template_label(ctx, title, gitaris_repo_label(state), {x, y + 24, iw, 24}, 17, TEMPLATE_TEXT, scale)
		template_label(ctx, face, model.config.project_path, {x, y + 48, iw, 16}, 10, TEMPLATE_MUTED, scale)
		y += 72
		if in_submodule {
			if gitaris_button(ctx, face, fmt.tprintf("↑  Back to %s", gitaris_parent_label(state)), {x, y, iw, 30}, scale, id = "sidebar-back") {
				if gitaris_leave_to(state, len(state.parents) - 1) do gitaris_reset_scroll(ctx)
				return
			}
			y += 38
		}
		template_box(ctx, {x, y, iw, 1}, TEMPLATE_LINE, 0, scale)
		y += 12
		template_label(ctx, title, "Branches", {x, y, iw - 40, 20}, 13, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("%d", len(model.branches)), {x + iw - 40, y, 40, 20}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
		y += 26
		viewport := ui.Rect2d{x, y, iw, max(40, bottom - 56 - submodule_height - y)}
		first, last, offset := gitaris_scroll_begin(ctx, viewport, len(model.branches), 36, scale)
		chosen := -1
		for i in first..<last {
			branch := model.branches[i]
			ry := viewport.y + f32(i) * 36 - offset
			selected := i == model.selected && !model.all_branches
			if gitaris_row_button(ctx, face, branch.ref_name, {x, ry, iw - 6, 32}, selected, scale) do chosen = i
			template_label(ctx, icons, "", {x + 8, ry, 18, 32}, 13, branch.remote ? TEMPLATE_MUTED : TEMPLATE_ACCENT, scale)
			tag_w: f32 = branch.head ? 46 : 0
			template_label(ctx, face, branch.name, {x + 30, ry, iw - 44 - tag_w, 32}, 13, TEMPLATE_TEXT, scale)
			if branch.head {
				template_tag(ctx, face, branch.unborn ? "NEW" : "HEAD", x + iw - 50, ry + 7, TEMPLATE_ACCENT, TEMPLATE_LIGHT, scale)
			}
		}
		gitaris_scroll_end(ctx, viewport, scale)
		if chosen >= 0 && (chosen != model.selected || model.all_branches) {
			gitaris_error(state, workspace.select_branch(model, chosen))
			gitaris_reset_windows(ctx, "history", "commit-files", "commit-diff")
		}
		template_box(ctx, {x, bottom - 48, iw, 1}, TEMPLATE_LINE, 0, scale)
		template_label(ctx, face, model.config.username, {x, bottom - 42, iw, 18}, 12, TEMPLATE_TEXT, scale)
		template_label(ctx, face, model.config.email, {x, bottom - 24, iw, 16}, 10, TEMPLATE_MUTED, scale)
	}
	if len(model.submodules) == 0 do return
	// Submodules: status at a glance. A checked-out one opens as the workspace;
	// any other opens the Submodules view, where it can be updated.
	sy := bottom - 56 - submodule_height + 4
	ui.begin_window(ctx, template_rect({sx, sy, sw, submodule_height}, scale), "sidebar-submodules")
	template_box(ctx, {x, sy, iw, 1}, TEMPLATE_LINE, 0, scale)
	template_label(ctx, title, "Submodules", {x, sy + 8, iw - 40, 20}, 13, TEMPLATE_TEXT, scale)
	count := gitaris_scanning(state) ? "checking…" : fmt.tprintf("%d", len(model.submodules))
	template_label(ctx, face, count, {x + iw - 80, sy + 8, 80, 20}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
	viewport := ui.Rect2d{x, sy + 34, iw, f32(submodule_rows) * 40}
	first, last, offset := gitaris_scroll_begin(ctx, viewport, len(model.submodules), 40, scale)
	chosen := -1
	for i in first..<last {
		info := model.submodules[i]
		ry := viewport.y + f32(i) * 40 - offset
		if gitaris_row_button(ctx, face, fmt.tprintf("submodule:%s", info.path), {x, ry, iw - 6, 36}, i == state.submodule_focus, scale) do chosen = i
		template_box(ctx, {x + 10, ry + 9, 8, 8}, gitaris_submodule_color(info), 4, scale)
		template_label(ctx, face, info.path, {x + 26, ry + 2, iw - 36, 18}, 13, TEMPLATE_TEXT, scale)
		label, _ := workspace.submodule_describe(info, gitaris_repo_label(state))
		hint := info.checked_out ? fmt.tprintf("%s · open", label) : fmt.tprintf("%s · update", label)
		template_label(ctx, face, hint, {x + 26, ry + 19, iw - 36, 15}, 10, workspace.submodule_attention(info) ? TEMPLATE_WARNING : TEMPLATE_MUTED, scale)
	}
	gitaris_scroll_end(ctx, viewport, scale)
	if chosen >= 0 {
		if model.submodules[chosen].checked_out {
			if gitaris_enter_submodule(state, chosen) do gitaris_reset_scroll(ctx)
		} else {
			state.submodule_focus = chosen
			gitaris_open_menu(state, .SUBMODULES)
		}
	}
}

gitaris_history_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face,
	state: ^Gitaris, w, h, scale: f32, mono: ^font_core.Face = nil) {
	model := &state.model
	panel := gitaris_main_rect(w, h)
	{
		ui.begin_window(ctx, template_rect({0, 0, w, h}, scale), "workspace-background")
		template_panel(ctx, {GITARIS_GAP, panel.y, GITARIS_SIDEBAR_WIDTH, panel.height}, TEMPLATE_CARD, 16, scale)
		template_panel(ctx, panel, TEMPLATE_CARD, 16, scale)
	}
	gitaris_sidebar_ui(ctx, face, title, icons, state, h, scale)
	if state.menu != .NONE || !state.ready do return // The sidebar switched views or repositories.
	x, cw := panel.x + GITARIS_PAD, panel.width - 2 * GITARIS_PAD
	if workspace.changes_open(model.changes) {
		gitaris_changes_ui(ctx, face, title, mono != nil ? mono : face, state, x, cw, h, scale)
		return
	}
	y0 := panel.y + 14
	bottom := panel.y + panel.height
	ui.begin_window(ctx, template_rect(panel, scale), "history")
	// Header: title, the viewed branch, and actions on one line.
	template_label(ctx, title, "History", {x, y0, 90, 32}, 20, TEMPLATE_TEXT, scale)
	branch := model.branches[model.selected]
	scope := model.all_branches ? "All branches" : branch.name
	chip_w := min(template_text_width(ctx, face, scope, 12, scale) + 40, cw - 470)
	template_box(ctx, {x + 90, y0 + 4, chip_w, 24}, TEMPLATE_BUTTON, 12, scale)
	template_label(ctx, icons, "", {x + 100, y0 + 4, 16, 24}, 12, TEMPLATE_ACCENT, scale)
	template_label(ctx, face, scope, {x + 120, y0 + 4, chip_w - 34, 24}, 12, TEMPLATE_TEXT, scale)
	if gitaris_button(ctx, face, "Refresh", {x + cw - 84, y0 + 1, 84, 30}, scale) {
		gitaris_error(state, workspace.refresh(model))
		ctx.windows[ctx.window_index].scroll_offset = {}
	}
	if gitaris_button(ctx, face, "Working tree", {x + cw - 204, y0 + 1, 114, 30}, scale) {
		gitaris_error(state, workspace.select_working_changes(model))
		gitaris_reset_windows(ctx, "commit-files", "commit-diff")
	}
	if gitaris_button(ctx, face, "All branches", {x + cw - 320, y0 + 1, 110, 30}, scale, model.all_branches) && !model.all_branches {
		gitaris_error(state, workspace.select_history(model, model.selected, true))
		ctx.windows[ctx.window_index].scroll_offset = {}
	}
	if gitaris_field(ctx, face, "search", "", "Search loaded commits by message, author, hash or branch…", &state.search,
		{x, y0 + 42, cw, 36}, scale) == .MODIFIED {
		ctx.windows[ctx.window_index].scroll_offset = {}
	}
	template_label(ctx, face, "GRAPH / COMMIT", {x + 8, y0 + 86, cw - 150, 18}, 10, TEMPLATE_MUTED, scale)
	template_label(ctx, face, "REVISION", {x + cw - 96, y0 + 86, 80, 18}, 10, TEMPLATE_MUTED, scale, {.RIGHT})
	template_box(ctx, {x, y0 + 106, cw, 1}, TEMPLATE_LINE, 0, scale)
	matches := make([dynamic]int, 0, len(model.commits), context.temp_allocator)
	query := strings.to_lower(strings.trim_space(strings.to_string(state.search)), context.temp_allocator)
	for commit, i in model.commits {
		if query == "" || strings.contains(strings.to_lower(commit.message, context.temp_allocator), query) ||
			strings.contains(strings.to_lower(commit.author, context.temp_allocator), query) || strings.contains(commit.hash, query) ||
			strings.contains(strings.to_lower(commit.refs, context.temp_allocator), query) {
			append(&matches, i)
		}
	}
	footer := bottom - 44
	viewport := ui.Rect2d{x, y0 + 110, cw, footer - y0 - 116}
	graph_width := max(f32(40), 18 + f32(model.graph.width) * GITARIS_GRAPH_SPACING)
	content_width := max(viewport.width, graph_width + 420)
	row :: GITARIS_ROW_HEIGHT
	first, last, offset := gitaris_scroll_begin(ctx, viewport, len(matches), row, scale, content_width)
	horizontal := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	rx := viewport.x - horizontal
	chosen := -1
	for i in first..<last {
		commit := model.commits[matches[i]]
		y := viewport.y + f32(i) * row - offset
		if gitaris_row_button(ctx, face, commit.hash, {viewport.x, y + 2, viewport.width - 8, row - 4}, false, scale) do chosen = matches[i]
		// Filtering removes intermediate commits. Draw isolated nodes then,
		// rather than inventing connections between unrelated search hits.
		gitaris_graph_row(ctx, commit.graph, rx + 14, y, scale, viewport, query == "")
		text_x := rx + graph_width + 6
		text_width := content_width - graph_width - 110
		template_label(ctx, face, commit.message, {text_x, y + 7, text_width, 22}, 14, TEMPLATE_TEXT, scale)
		metadata := fmt.tprintf("%s  ·  %s", commit.author, commit.date)
		if commit.refs != "" do metadata = fmt.tprintf("%s  ·  %s", commit.refs, metadata)
		template_label(ctx, face, metadata, {text_x, y + 28, text_width, 18}, 11, commit.refs != "" ? TEMPLATE_ACCENT : TEMPLATE_MUTED, scale)
		template_label(ctx, face, commit.hash[:min(8, len(commit.hash))], {rx + content_width - 92, y + 7, 76, 22}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
	}
	if len(matches) == 0 {
		message := len(model.commits) == 0 ? "No commits on this branch yet." : "No matching commits in the loaded history."
		template_label(ctx, face, message, {viewport.x, viewport.y + 28, viewport.width, 30}, 14, TEMPLATE_MUTED, scale, {.CENTER})
	}
	gitaris_scroll_end(ctx, viewport, scale, true)
	if chosen >= 0 {
		gitaris_error(state, workspace.select_commit(model, chosen))
		gitaris_reset_windows(ctx, "commit-files", "commit-diff")
	}
	// Footer: errors first, otherwise what the list shows.
	if state.error != "" {
		gitaris_message(ctx, face, state.error, {x, footer + 4, cw - 250, 34}, scale)
	} else {
		summary := fmt.tprintf("%d shown · %d loaded", len(matches), len(model.commits))
		if query != "" do summary = fmt.tprintf("%s · search results, graph connections hidden", summary)
		template_label(ctx, face, summary, {x, footer + 6, cw - 250, 30}, 11, TEMPLATE_MUTED, scale)
	}
	if content_width > viewport.width {
		scroll := &ctx.windows[ctx.window_index].scroll_offset.x
		if gitaris_button(ctx, face, "←", {x + cw - 192, footer + 7, 30, 28}, scale, id = "graph-left") do scroll^ = max(0, scroll^ - 160 * scale)
		if gitaris_button(ctx, face, "→", {x + cw - 158, footer + 7, 30, 28}, scale, id = "graph-right") do scroll^ = min((content_width - viewport.width) * scale, scroll^ + 160 * scale)
	}
	if model.has_more && gitaris_button(ctx, face, "Load more", {x + cw - 118, footer + 6, 118, 30}, scale) {
		gitaris_error(state, workspace.load_more(model))
	}
}
