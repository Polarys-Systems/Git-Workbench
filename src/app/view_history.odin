package app

// Workspace main screen: the branch/tag/submodule sidebar on the left and the
// commit history (with graph and search) on the right.

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../git"
import "../ui"
import "../workspace"

@(private = "file") BRANCH_ROW_HEIGHT :: 36
@(private = "file") TAG_ROW_HEIGHT :: 44
@(private = "file") SIDEBAR_SUBMODULE_ROW_HEIGHT :: 40
@(private = "file") SIDEBAR_MAX_SUBMODULE_ROWS :: 5
@(private = "file") SIDEBAR_FOOTER_HEIGHT :: 56 // The user's name and email at the bottom.

// Dot color for a submodule: lime when it matches what the parent records,
// orange when it needs attention, gray when it is not checked out.
workbench_submodule_color :: proc(info: workspace.Submodule_Info) -> [4]f32 {
	if info.state == .NOT_INITIALIZED do return THEME_MUTED
	if workspace.submodule_attention(info) do return THEME_WARNING
	return THEME_HIGHLIGHT
}

// Main content panel beside the sidebar: its card rectangle.
workbench_main_rect :: proc(w, h: f32) -> ui.Rect2d {
	x: f32 = PANEL_GAP * 2 + SIDEBAR_WIDTH
	return {x, MENU_HEIGHT, w - x - PANEL_GAP, h - MENU_HEIGHT - PANEL_GAP}
}

workbench_history_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face,
	state: ^Workbench, w, h, scale: f32, mono: ^font_core.Face = nil) {
	panel := workbench_main_rect(w, h)
	{
		ui.begin_window(ctx, theme_rect({0, 0, w, h}, scale), "workspace-background")
		theme_panel(ctx, {PANEL_GAP, panel.y, SIDEBAR_WIDTH, panel.height}, THEME_CARD, 16, scale)
		theme_panel(ctx, panel, THEME_CARD, 16, scale)
	}
	workbench_sidebar_ui(ctx, face, title, icons, state, h, scale)
	if state.menu != .NONE || !state.ready do return // The sidebar switched views or repositories.

	x, content_w := panel.x + PANEL_PADDING, panel.width - 2 * PANEL_PADDING
	// A selected commit (or the working tree) replaces the list with its changes.
	if workspace.changes_open(state.model.changes) {
		workbench_changes_ui(ctx, face, title, mono != nil ? mono : face, state, x, content_w, h, scale)
		return
	}
	ui.begin_window(ctx, theme_rect(panel, scale), "history")
	header_y := panel.y + 14
	if history_header(ctx, face, title, icons, state, x, header_y, content_w, scale) do return
	history_commit_list(ctx, face, state, x, header_y, content_w, panel.y + panel.height, scale)
}

// ---------------------------------------------------------------------------
// Sidebar

workbench_sidebar_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face, state: ^Workbench, h, scale: f32) {
	model := &state.model
	top: f32 = MENU_HEIGHT
	bottom := h - PANEL_GAP
	x, inner_w: f32 = PANEL_GAP + 14, SIDEBAR_WIDTH - 28
	submodule_rows := min(len(model.submodules), SIDEBAR_MAX_SUBMODULE_ROWS)
	submodules_h: f32 = 0
	if len(model.submodules) > 0 do submodules_h = 36 + f32(submodule_rows) * SIDEBAR_SUBMODULE_ROW_HEIGHT
	{
		ui.begin_window(ctx, theme_rect({PANEL_GAP, top, SIDEBAR_WIDTH, bottom - top}, scale), "branches")
		y, stop := sidebar_repository(ctx, face, title, state, x, top + 14, inner_w, scale)
		if stop do return
		theme_box(ctx, {x, y, inner_w, 1}, THEME_LINE, 0, scale)
		y += 10
		sidebar_ref_switch(ctx, face, state, x, y, inner_w, scale)
		y += 36

		list := ui.Rect2d{x, y, inner_w, max(40, bottom - SIDEBAR_FOOTER_HEIGHT - submodules_h - y)}
		if state.sidebar_tags {
			sidebar_tags(ctx, face, icons, state, list, scale)
		} else {
			sidebar_branches(ctx, face, icons, state, list, scale)
		}

		// Who commits: the identity from Preferences.
		theme_box(ctx, {x, bottom - 48, inner_w, 1}, THEME_LINE, 0, scale)
		theme_label(ctx, face, model.config.username, {x, bottom - 42, inner_w, 18}, 12, THEME_TEXT, scale)
		theme_label(ctx, face, model.config.email, {x, bottom - 24, inner_w, 16}, 10, THEME_MUTED, scale)
	}
	if len(model.submodules) > 0 {
		submodules_y := bottom - SIDEBAR_FOOTER_HEIGHT - submodules_h + 4
		sidebar_submodules(ctx, face, title, state, {PANEL_GAP, submodules_y, SIDEBAR_WIDTH, submodules_h}, submodule_rows, scale)
	}
}

// Which repository is open: always visible, tagged inside a submodule, with
// a way back to the parent. Returns where the next section starts, or `stop`
// when the user went back (the workspace was replaced).
@(private = "file")
sidebar_repository :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench,
	x, y, width, scale: f32) -> (next_y: f32, stop: bool) {
	model := &state.model
	in_submodule := len(state.parents) > 0
	if in_submodule {
		theme_tag(ctx, face, "SUBMODULE", x, y, THEME_HIGHLIGHT, THEME_DARK, scale)
		theme_label(ctx, face, fmt.tprintf("of %s", workbench_parent_label(state)), {x + 82, y, width - 82, 18}, 11, THEME_MUTED, scale)
	} else {
		theme_tag(ctx, face, "REPOSITORY", x, y, THEME_BUTTON, THEME_MUTED, scale)
	}
	// Repositories inside WSL are named with their distribution.
	if distribution := workspace.wsl_distribution(model.config.project_path); distribution != "" {
		text := fmt.tprintf("WSL · %s", distribution)
		tag_x := x + width - theme_text_width(ctx, face, text, 10, scale) - 14
		theme_tag(ctx, face, text, tag_x, y, THEME_ACCENT, THEME_LIGHT, scale)
	}
	theme_label(ctx, title, workbench_repo_label(state), {x, y + 24, width, 24}, 17, THEME_TEXT, scale)
	theme_label(ctx, face, model.config.project_path, {x, y + 48, width, 16}, 10, THEME_MUTED, scale)
	next_y = y + 72
	if in_submodule {
		back := fmt.tprintf("↑  Back to %s", workbench_parent_label(state))
		if workbench_button(ctx, face, back, {x, next_y, width, 30}, scale, id = "sidebar-back") {
			if workbench_leave_to(state, len(state.parents) - 1) do workbench_reset_scroll(ctx)
			return next_y, true
		}
		next_y += 38
	}
	return next_y, false
}

// Branches and tags share the list: a two-way switch, plus New (+).
@(private = "file")
sidebar_ref_switch :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y, width, scale: f32) {
	model := &state.model
	half := (width - 40) * 0.5
	if workbench_button(ctx, face, fmt.tprintf("Branches  %d", len(model.branches)), {x, y, half, 28}, scale, !state.sidebar_tags, id = "sidebar-branches") {
		state.sidebar_tags = false
	}
	if workbench_button(ctx, face, fmt.tprintf("Tags  %d", len(model.tags)), {x + half + 4, y, half, 28}, scale, state.sidebar_tags, id = "sidebar-tags") {
		state.sidebar_tags = true
	}
	if workbench_button(ctx, face, "+", {x + width - 32, y, 32, 28}, scale, id = "sidebar-new") {
		if workspace.remote_busy(&state.remote) {
			workbench_error(state, "Wait for the running network operation to finish first.")
		} else {
			workbench_open_ref_dialog(ctx, state, state.sidebar_tags ? .TAG : .BRANCH, "", workbench_head_target(state))
		}
	}
}

// The branch list. Choosing a branch shows its history without checking it out.
@(private = "file")
sidebar_branches :: proc(ctx: ^ui.UiContext, face, icons: ^font_core.Face, state: ^Workbench, viewport: ui.Rect2d, scale: f32) {
	model := &state.model
	x, width := viewport.x, viewport.width
	// A branch is "selected" only while the history is scoped to it.
	scoped_to_branch := !model.all_branches && model.scoped_tag == ""
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(model.branches), BRANCH_ROW_HEIGHT, scale)
	chosen := -1
	for i in first..<last {
		branch := model.branches[i]
		y := viewport.y + f32(i) * BRANCH_ROW_HEIGHT - offset
		if workbench_row_button(ctx, face, branch.ref_name, {x, y, width - 6, 32}, scoped_to_branch && i == model.selected, scale) do chosen = i
		theme_label(ctx, icons, "", {x + 8, y, 18, 32}, 13, branch.remote ? THEME_MUTED : THEME_ACCENT, scale)
		head_tag_w: f32 = branch.head ? 46 : 0
		theme_label(ctx, face, branch.name, {x + 30, y, width - 44 - head_tag_w, 32}, 13, THEME_TEXT, scale)
		if branch.head {
			theme_tag(ctx, face, branch.unborn ? "NEW" : "HEAD", x + width - 50, y + 7, THEME_ACCENT, THEME_LIGHT, scale)
		}
	}
	workbench_scroll_end(ctx, viewport, scale)
	if chosen >= 0 && (chosen != model.selected || !scoped_to_branch) {
		workbench_error(state, workspace.select_branch(model, chosen))
		workbench_reset_windows(ctx, "history", "commit-files", "commit-diff")
	}
}

// The tag list. Choosing a tag shows the history leading to it.
@(private = "file")
sidebar_tags :: proc(ctx: ^ui.UiContext, face, icons: ^font_core.Face, state: ^Workbench, viewport: ui.Rect2d, scale: f32) {
	model := &state.model
	x, width := viewport.x, viewport.width
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(model.tags), TAG_ROW_HEIGHT, scale)
	chosen := -1
	for i in first..<last {
		tag := model.tags[i]
		y := viewport.y + f32(i) * TAG_ROW_HEIGHT - offset
		if workbench_row_button(ctx, face, fmt.tprintf("tag:%s", tag.name), {x, y, width - 6, 40}, model.scoped_tag == tag.name, scale) do chosen = i
		theme_label(ctx, icons, "", {x + 9, y + 2, 18, 22}, 12, tag.annotated ? THEME_ACCENT : THEME_MUTED, scale)
		theme_label(ctx, face, tag.name, {x + 30, y + 3, width - 44, 20}, 13, THEME_TEXT, scale)
		kind := "lightweight"
		if tag.annotated do kind = tag.message != "" ? tag.message : "annotated"
		detail := fmt.tprintf("%s  ·  %s", workbench_oid_short(tag.target), kind)
		theme_label(ctx, face, detail, {x + 30, y + 22, width - 44, 15}, 10, THEME_MUTED, scale)
	}
	if len(model.tags) == 0 {
		theme_label(ctx, face, "No tags yet. Use + or Tag… on a commit.", {x + 4, viewport.y + 8, width - 8, 18}, 11, THEME_MUTED, scale)
	}
	workbench_scroll_end(ctx, viewport, scale)
	if chosen >= 0 && model.tags[chosen].name != model.scoped_tag {
		workbench_error(state, workspace.select_tag(model, chosen))
		workbench_reset_windows(ctx, "history", "commit-files", "commit-diff")
	}
}

// Submodules at a glance. A checked-out one opens as the workspace; any
// other opens the Submodules view, where it can be updated.
@(private = "file")
sidebar_submodules :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face, state: ^Workbench,
	rect: ui.Rect2d, visible_rows: int, scale: f32) {
	model := &state.model
	x, y, width := rect.x + 14, rect.y, rect.width - 28
	ui.begin_window(ctx, theme_rect(rect, scale), "sidebar-submodules")
	theme_box(ctx, {x, y, width, 1}, THEME_LINE, 0, scale)
	theme_label(ctx, title, "Submodules", {x, y + 8, width - 40, 20}, 13, THEME_TEXT, scale)
	count := workbench_scanning(state) ? "checking…" : fmt.tprintf("%d", len(model.submodules))
	theme_label(ctx, face, count, {x + width - 80, y + 8, 80, 20}, 11, THEME_MUTED, scale, {.RIGHT})

	row_h :: SIDEBAR_SUBMODULE_ROW_HEIGHT
	viewport := ui.Rect2d{x, y + 34, width, f32(visible_rows) * row_h}
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(model.submodules), row_h, scale)
	chosen := -1
	for i in first..<last {
		info := model.submodules[i]
		row_y := viewport.y + f32(i) * row_h - offset
		if workbench_row_button(ctx, face, fmt.tprintf("submodule:%s", info.path), {x, row_y, width - 6, 36}, i == state.submodule_focus, scale) do chosen = i
		theme_box(ctx, {x + 10, row_y + 9, 8, 8}, workbench_submodule_color(info), 4, scale)
		theme_label(ctx, face, info.path, {x + 26, row_y + 2, width - 36, 18}, 13, THEME_TEXT, scale)
		label, _ := workspace.submodule_describe(info, workbench_repo_label(state))
		hint := fmt.tprintf("%s · %s", label, info.checked_out ? "open" : "update")
		hint_color := workspace.submodule_attention(info) ? THEME_WARNING : THEME_MUTED
		theme_label(ctx, face, hint, {x + 26, row_y + 19, width - 36, 15}, 10, hint_color, scale)
	}
	workbench_scroll_end(ctx, viewport, scale)
	if chosen < 0 do return
	if model.submodules[chosen].checked_out {
		if workbench_enter_submodule(state, chosen) do workbench_reset_scroll(ctx)
	} else {
		state.submodule_focus = chosen
		workbench_open_menu(state, .SUBMODULES)
	}
}

// ---------------------------------------------------------------------------
// History list

// Title, the scope being viewed (all branches, a branch or a tag) with its
// actions, the view buttons, and the search field. Returns true when an
// action replaced the view.
@(private = "file")
history_header :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face, state: ^Workbench,
	x, y, width, scale: f32) -> (stop: bool) {
	model := &state.model
	theme_label(ctx, title, "History", {x, y, 90, 32}, 20, THEME_TEXT, scale)

	// Scope chip: a tag icon and lime for a tag, a branch icon otherwise.
	scoped_tag := model.scoped_tag != ""
	scope := model.all_branches ? "All branches" : model.branches[model.selected].name
	if scoped_tag do scope = model.scoped_tag
	chip_w := max(80, min(theme_text_width(ctx, face, scope, 12, scale) + 40, width - 680))
	theme_box(ctx, {x + 90, y + 4, chip_w, 24}, scoped_tag ? THEME_HIGHLIGHT : THEME_BUTTON, 12, scale)
	theme_label(ctx, icons, scoped_tag ? "" : "", {x + 100, y + 4, 16, 24}, 12, THEME_ACCENT, scale)
	theme_label(ctx, face, scope, {x + 120, y + 4, chip_w - 34, 24}, 12, THEME_TEXT, scale)
	scope_actions(ctx, face, state, x + 98 + chip_w, y + 2, scale)
	if state.menu != .NONE || len(model.branches) == 0 do return true

	scroll := &ctx.windows[ctx.window_index].scroll_offset
	if workbench_button(ctx, face, "Refresh", {x + width - 84, y + 1, 84, 30}, scale) {
		workbench_error(state, workspace.refresh(model))
		scroll^ = {}
	}
	if workbench_button(ctx, face, "Working tree", {x + width - 204, y + 1, 114, 30}, scale) {
		workbench_error(state, workspace.select_working_changes(model))
		workbench_reset_windows(ctx, "commit-files", "commit-diff")
	}
	if workbench_button(ctx, face, "All branches", {x + width - 320, y + 1, 110, 30}, scale, model.all_branches) && !model.all_branches {
		workbench_error(state, workspace.select_history(model, model.selected, true))
		scroll^ = {}
	}
	search_hint := "Search loaded commits by message, author, hash or branch…"
	if workbench_field(ctx, face, "search", "", search_hint, &state.search, {x, y + 42, width, 36}, scale) == .MODIFIED {
		scroll^ = {}
	}
	theme_label(ctx, face, "GRAPH / COMMIT", {x + 8, y + 86, width - 150, 18}, 10, THEME_MUTED, scale)
	theme_label(ctx, face, "REVISION", {x + width - 96, y + 86, 80, 18}, 10, THEME_MUTED, scale, {.RIGHT})
	theme_box(ctx, {x, y + 106, width, 1}, THEME_LINE, 0, scale)
	return false
}

// Whether a commit matches the search. `query` is already lower case.
@(private = "file")
commit_matches :: proc(commit: workspace.Commit, query: string) -> bool {
	if query == "" do return true
	contains :: proc(text, query: string) -> bool {
		return strings.contains(strings.to_lower(text, context.temp_allocator), query)
	}
	return contains(commit.message, query) || contains(commit.author, query) || strings.contains(commit.hash, query) ||
		contains(commit.refs, query) || contains(commit.tags, query)
}

// The loaded commits that match the search, each with its graph row, and a
// footer with counts, sideways scrolling and Load more.
@(private = "file")
history_commit_list :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench,
	x, header_y, width, bottom, scale: f32) {
	model := &state.model
	query := strings.to_lower(strings.trim_space(strings.to_string(state.search)), context.temp_allocator)
	matches := make([dynamic]int, 0, len(model.commits), context.temp_allocator)
	for commit, i in model.commits do if commit_matches(commit, query) do append(&matches, i)

	footer := bottom - 44
	viewport := ui.Rect2d{x, header_y + 110, width, footer - header_y - 116}
	graph_width := max(f32(40), 18 + f32(model.graph.width) * GRAPH_LANE_SPACING)
	content_width := max(viewport.width, graph_width + 420)
	row_h :: COMMIT_ROW_HEIGHT
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(matches), row_h, scale, content_width)
	scroll_x := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	row_x := viewport.x - scroll_x
	chosen := -1
	for i in first..<last {
		commit := model.commits[matches[i]]
		y := viewport.y + f32(i) * row_h - offset
		if workbench_row_button(ctx, face, commit.hash, {viewport.x, y + 2, viewport.width - 8, row_h - 4}, false, scale) do chosen = matches[i]
		// Filtering removes intermediate commits. Draw isolated nodes then,
		// rather than inventing connections between unrelated search hits.
		workbench_graph_row(ctx, commit.graph, row_x + 14, y, scale, viewport, query == "")
		commit_row_text(ctx, face, commit, row_x + graph_width + 6, y, content_width - graph_width - 110, scale)
		theme_label(ctx, face, commit.hash[:min(8, len(commit.hash))], {row_x + content_width - 92, y + 7, 76, 22}, 11, THEME_MUTED, scale, {.RIGHT})
	}
	if len(matches) == 0 {
		message := len(model.commits) == 0 ? "No commits on this branch yet." : "No matching commits in the loaded history."
		theme_label(ctx, face, message, {viewport.x, viewport.y + 28, viewport.width, 30}, 14, THEME_MUTED, scale, {.CENTER})
	}
	workbench_scroll_end(ctx, viewport, scale, true)
	if chosen >= 0 {
		workbench_error(state, workspace.select_commit(model, chosen))
		workbench_reset_windows(ctx, "commit-files", "commit-diff")
	}

	// Footer: errors first, otherwise what the list shows.
	if state.error != "" {
		workbench_message(ctx, face, state.error, {x, footer + 4, width - 250, 34}, scale)
	} else {
		summary := fmt.tprintf("%d shown · %d loaded", len(matches), len(model.commits))
		if query != "" do summary = fmt.tprintf("%s · search results, graph connections hidden", summary)
		theme_label(ctx, face, summary, {x, footer + 6, width - 250, 30}, 11, THEME_MUTED, scale)
	}
	if content_width > viewport.width {
		scroll := &ctx.windows[ctx.window_index].scroll_offset.x
		if workbench_button(ctx, face, "←", {x + width - 192, footer + 7, 30, 28}, scale, id = "graph-left") {
			scroll^ = max(0, scroll^ - 160 * scale)
		}
		if workbench_button(ctx, face, "→", {x + width - 158, footer + 7, 30, 28}, scale, id = "graph-right") {
			scroll^ = min((content_width - viewport.width) * scale, scroll^ + 160 * scale)
		}
	}
	if model.has_more && workbench_button(ctx, face, "Load more", {x + width - 118, footer + 6, 118, 30}, scale) {
		workbench_error(state, workspace.load_more(model))
	}
}

// A commit's message, and below it its tags, refs, author and date.
@(private = "file")
commit_row_text :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, commit: workspace.Commit, x, y, width, scale: f32) {
	theme_label(ctx, face, commit.message, {x, y + 7, width, 22}, 14, THEME_TEXT, scale)
	metadata := fmt.tprintf("%s  ·  %s", commit.author, commit.date)
	if commit.refs != "" do metadata = fmt.tprintf("%s  ·  %s", commit.refs, metadata)
	chips := workbench_tag_chips(ctx, face, commit.tags, x, y + 29, scale)
	theme_label(ctx, face, metadata, {x + chips, y + 28, width - chips, 18}, 11, commit.refs != "" ? THEME_ACCENT : THEME_MUTED, scale)
}

workbench_oid_short :: proc(id: git.Oid) -> string {
	hash: [65]u8
	copy := id
	_ = git.oid_tostr(raw_data(hash[:]), len(hash), &copy)
	return strings.clone(string(cstring(raw_data(hash[:])))[:8], context.temp_allocator)
}

// Small chips for the tags on a commit row. Returns the width used.
workbench_tag_chips :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, tags: string, x, y: f32, scale: f32) -> f32 {
	if tags == "" do return 0
	used: f32 = 0
	rest := tags
	for name in strings.split_iterator(&rest, ", ") {
		used += theme_tag(ctx, face, name, x + used, y, THEME_HIGHLIGHT, THEME_DARK, scale, 16) + 4
	}
	return used + 2
}

// ---------------------------------------------------------------------------
// Actions on the viewed branch or tag

// Beside the scope chip: Push tag / Delete for a tag; Check out / Delete for
// a branch other than the checked-out one.
@(private = "file")
scope_actions :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y: f32, scale: f32) {
	model := &state.model
	if model.scoped_tag != "" {
		tag_actions(ctx, face, state, x, y, scale)
		return
	}
	if model.all_branches || model.selected < 0 || model.selected >= len(model.branches) do return
	branch := model.branches[model.selected]
	if branch.head || branch.ref_name == "HEAD" do return
	branch_actions(ctx, face, state, branch, x, y, scale)
}

@(private = "file")
tag_actions :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, x, y: f32, scale: f32) {
	model := &state.model
	key := fmt.tprintf("tag:%s", model.scoped_tag)
	// Deleting frees scoped_tag, so keep a copy of the name.
	name := strings.clone(model.scoped_tag, context.temp_allocator)
	delete_x := x
	// While a delete waits for confirmation, other actions step aside.
	if state.delete_armed != key {
		if workbench_button(ctx, face, "Push tag", {x, y, 84, 28}, scale, id = "scope-push-tag") && !workspace.remote_busy(&state.remote) {
			workbench_tag_push(state, name)
		}
		delete_x += 90
	}
	if confirmed_delete(ctx, face, state, key, "scope-delete-tag", delete_x, y, scale) {
		err := workspace.delete_tag(model, name)
		workbench_error(state, err)
		if err == "" do workbench_notice(state, fmt.tprintf("Deleted tag %s (local only; a pushed tag stays on the remote).", name))
		workbench_reset_windows(ctx, "history", "commit-files", "commit-diff")
	}
}

@(private = "file")
branch_actions :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, branch: workspace.Branch, x, y: f32, scale: f32) {
	model := &state.model
	key := fmt.tprintf("branch:%s", branch.ref_name)
	delete_x := x
	if state.delete_armed != key {
		if workbench_button(ctx, face, "Check out", {x, y, 90, 28}, scale, true, id = "scope-checkout") {
			if workspace.remote_busy(&state.remote) {
				workbench_error(state, "Wait for the running network operation to finish before switching branches.")
			} else {
				notice, err := workspace.checkout_branch(model, model.selected)
				workbench_error(state, err)
				if notice != "" do workbench_notice(state, notice)
				workbench_reset_windows(ctx, "history", "branches", "commit-files", "commit-diff")
				return
			}
		}
		delete_x += 96
	}
	if branch.remote do return // Remote-tracking branches are deleted on the remote, not here.
	if confirmed_delete(ctx, face, state, key, "scope-delete-branch", delete_x, y, scale) {
		notice, err := workspace.delete_branch(model, model.selected)
		workbench_error(state, err)
		if notice != "" do workbench_notice(state, notice)
		workbench_reset_windows(ctx, "history", "branches", "commit-files", "commit-diff")
	}
}

// A Delete button that needs a second click: the first turns it into
// "Confirm delete" with a Cancel beside it. `key` names what would be
// deleted. Returns true on the confirming click.
@(private = "file")
confirmed_delete :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, key, id: string, x, y, scale: f32) -> bool {
	armed := state.delete_armed == key
	label := armed ? "Confirm delete" : "Delete"
	if workbench_button(ctx, face, label, {x, y, armed ? 120 : 70, 28}, scale, armed, id = id) {
		if armed {
			workbench_disarm(state)
			return true
		}
		workbench_arm(state, key)
	}
	if armed && workbench_button(ctx, face, "Cancel", {x + 126, y, 70, 28}, scale, id = "scope-delete-cancel") {
		workbench_disarm(state)
	}
	return false
}

workbench_arm :: proc(state: ^Workbench, key: string) {
	delete(state.delete_armed)
	state.delete_armed = strings.clone(key)
}

workbench_disarm :: proc(state: ^Workbench) {
	delete(state.delete_armed)
	state.delete_armed = ""
}
