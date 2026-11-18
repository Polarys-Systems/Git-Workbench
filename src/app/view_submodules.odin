package app

// Submodules panel: status of each submodule, with open and update actions.

import "core:fmt"

import font_core "../font"
import "../ui"
import "../workspace"

SUBMODULE_ROW_HEIGHT :: 84

// Every submodule of the open repository: what the parent records, what is
// checked out, and whether they agree. Update brings a submodule to the
// recorded commit (cloning it first if needed); Open makes it the workspace.
workbench_submodules_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench, w, h, scale: f32) {
	model := &state.model
	busy := workspace.remote_busy(&state.remote)
	repo := workbench_repo_label(state)
	panel_w := min(w - 2 * PANEL_GAP, 920)
	panel_x := (w - panel_w) * 0.5
	panel_y := MENU_HEIGHT + (1 - state.view_enter.value) * 10
	panel_h := h - MENU_HEIGHT - PANEL_GAP
	x, content_w := panel_x + 20, panel_w - 40
	{
		ui.begin_window(ctx, theme_rect({0, MENU_HEIGHT, w, h - MENU_HEIGHT}, scale), "submodules-header")
		theme_panel(ctx, {panel_x, panel_y, panel_w, panel_h}, THEME_CARD, 16, scale)
		theme_label(ctx, title, "Submodules", {x, panel_y + 14, 140, 32}, 20, THEME_TEXT, scale)
		theme_label(ctx, face, fmt.tprintf("of %s · recorded in its .gitmodules", repo), {x + 132, panel_y + 14, content_w - 400, 32}, 12, THEME_MUTED, scale)
		if workbench_button(ctx, face, "Check status", {x + content_w - 230, panel_y + 15, 112, 30}, scale, id = "submodules-check") && !busy {
			workbench_error(state, workspace.refresh(model))
			workbench_notice(state, "") // The checking line reports progress.
		}
		if workbench_button(ctx, face, "Update all", {x + content_w - 112, panel_y + 15, 112, 30}, scale, true, id = "submodules-update-all") && !busy {
			workbench_submodule_update(state)
		}
		status, color := "", THEME_MUTED
		if busy {
			status, color = workbench_remote_progress(state), THEME_ACCENT
		} else if state.error != "" {
			status, color = state.error, THEME_ERROR_TEXT
		} else if model.submodule_error != "" {
			status, color = model.submodule_error, THEME_ERROR_TEXT
		} else if state.notice != "" {
			status, color = state.notice, THEME_ADDITION_TEXT
		}
		if status == "" && workbench_scanning(state) do status = "Checking for changes inside submodules… (slow on large ones; everything else works meanwhile)"
		if status != "" do workbench_message(ctx, face, status, {x, panel_y + 52, content_w, 34}, scale, color)
		if len(model.submodules) == 0 && model.submodule_error == "" {
			theme_label(ctx, title, fmt.tprintf("%s has no submodules.", repo), {x, panel_y + 120, content_w, 30}, 16, THEME_TEXT, scale, {.CENTER})
			theme_label(ctx, face, "Add one with git submodule add <url> <path>; it then appears here.", {x, panel_y + 150, content_w, 20}, 12, THEME_MUTED, scale, {.CENTER})
		}
		footnote := "Update is git submodule update --init --recursive: it clones what is missing and checks out the commit the parent records (detached HEAD). Local changes inside a submodule are never overwritten."
		workbench_message(ctx, face, footnote, {x, panel_y + panel_h - 42, content_w, 34}, scale, THEME_MUTED)
	}
	if len(model.submodules) == 0 do return

	// The list moves down only while a status message is shown.
	list_top: f32 = busy || state.error != "" || model.submodule_error != "" || state.notice != "" || workbench_scanning(state) ? 92 : 58
	viewport := ui.Rect2d{x, panel_y + list_top, content_w, panel_h - list_top - 50}
	ui.begin_window(ctx, theme_rect(viewport, scale), "submodules-list")
	row :: SUBMODULE_ROW_HEIGHT
	first, last, offset := workbench_scroll_begin(ctx, viewport, len(model.submodules), row, scale)
	update, open := -1, -1
	for i in first..<last {
		info := model.submodules[i]
		y := viewport.y + f32(i) * row - offset
		focused := i == state.submodule_focus
		theme_box(ctx, {x, y, content_w - 8, row - 8}, focused ? THEME_SELECTED : THEME_SURFACE, 12, scale)
		theme_box(ctx, {x + 14, y + 17, 10, 10}, workbench_submodule_color(info), 5, scale)
		label, detail := workspace.submodule_describe(info, repo)
		attention := workspace.submodule_attention(info)
		theme_label(ctx, title, info.path, {x + 34, y + 9, content_w - 380, 26}, 15, THEME_TEXT, scale)
		tag_x := x + 34 + min(theme_text_width(ctx, title, info.path, 15, scale) + 10, content_w - 380)
		theme_tag(ctx, face, label, tag_x, y + 13, attention ? THEME_WARNING : THEME_CARD, attention ? THEME_LIGHT : THEME_TEXT, scale)
		theme_label(ctx, face, detail, {x + 34, y + 34, content_w - 250, 18}, 11, THEME_TEXT, scale)
		recorded := workspace.submodule_recorded(info)
		commits := fmt.tprintf("recorded %s  ·  checked out %s  ·  %s", recorded != "" ? recorded : "—",
			info.workdir != "" ? info.workdir : "—", info.url)
		if info.branch != "" do commits = fmt.tprintf("%s  ·  branch %s", commits, info.branch)
		theme_label(ctx, mono, commits, {x + 34, y + 54, content_w - 250, 16}, 10, THEME_MUTED, scale)
		if workbench_button(ctx, face, "Update", {x + content_w - 214, y + 22, 92, 32}, scale, id = fmt.tprintf("update:%s", info.name)) && !busy {
			update = i
		}
		open_label := info.checked_out ? "Open  →" : "Open"
		if workbench_button(ctx, face, open_label, {x + content_w - 114, y + 22, 100, 32}, scale, info.checked_out, id = fmt.tprintf("open:%s", info.name)) {
			open = i
		}
	}
	workbench_scroll_end(ctx, viewport, scale)
	if update >= 0 {
		state.submodule_focus = update
		workbench_submodule_update(state, model.submodules[update].name)
	}
	if open >= 0 {
		state.submodule_focus = open
		if workbench_enter_submodule(state, open) do workbench_reset_scroll(ctx)
	}
}
