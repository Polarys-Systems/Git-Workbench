package app

import "core:fmt"

import font_core "../font"
import "../ui"
import "../workspace"

GITARIS_SUBMODULE_ROW :: 84

// Every submodule of the open repository: what the parent records, what is
// checked out, and whether they agree. Update brings a submodule to the
// recorded commit (cloning it first if needed); Open makes it the workspace.
gitaris_submodules_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Gitaris, w, h, scale: f32) {
	model := &state.model
	busy := workspace.remote_busy(&state.remote)
	repo := gitaris_repo_label(state)
	pw := min(w - 2 * GITARIS_GAP, 920)
	px := (w - pw) * 0.5
	py := GITARIS_MENU_HEIGHT + (1 - state.view_enter.value) * 10
	ph := h - GITARIS_MENU_HEIGHT - GITARIS_GAP
	x, cw := px + 20, pw - 40
	{
		ui.begin_window(ctx, template_rect({0, GITARIS_MENU_HEIGHT, w, h - GITARIS_MENU_HEIGHT}, scale), "submodules-header")
		template_panel(ctx, {px, py, pw, ph}, TEMPLATE_CARD, 16, scale)
		template_label(ctx, title, "Submodules", {x, py + 14, 140, 32}, 20, TEMPLATE_TEXT, scale)
		template_label(ctx, face, fmt.tprintf("of %s · recorded in its .gitmodules", repo), {x + 132, py + 14, cw - 400, 32}, 12, TEMPLATE_MUTED, scale)
		if gitaris_button(ctx, face, "Check status", {x + cw - 230, py + 15, 112, 30}, scale, id = "submodules-check") && !busy {
			gitaris_error(state, workspace.refresh(model))
			if state.error == "" do gitaris_notice(state, fmt.tprintf("Checked %d submodules of %s.", len(model.submodules), repo))
		}
		if gitaris_button(ctx, face, "Update all", {x + cw - 112, py + 15, 112, 30}, scale, true, id = "submodules-update-all") && !busy {
			gitaris_submodule_update(state)
		}
		status, color := "", TEMPLATE_MUTED
		if busy {
			status, color = gitaris_remote_progress(state), TEMPLATE_ACCENT
		} else if state.error != "" {
			status, color = state.error, GITARIS_ERROR_TEXT
		} else if model.submodule_error != "" {
			status, color = model.submodule_error, GITARIS_ERROR_TEXT
		} else if state.notice != "" {
			status, color = state.notice, GITARIS_ADD_TEXT
		}
		if status != "" do gitaris_message(ctx, face, status, {x, py + 52, cw, 34}, scale, color)
		if len(model.submodules) == 0 && model.submodule_error == "" {
			template_label(ctx, title, fmt.tprintf("%s has no submodules.", repo), {x, py + 120, cw, 30}, 16, TEMPLATE_TEXT, scale, {.CENTER})
			template_label(ctx, face, "Add one with git submodule add <url> <path>; it then appears here.", {x, py + 150, cw, 20}, 12, TEMPLATE_MUTED, scale, {.CENTER})
		}
		footnote := "Update is git submodule update --init --recursive: it clones what is missing and checks out the commit the parent records (detached HEAD). Local changes inside a submodule are never overwritten."
		gitaris_message(ctx, face, footnote, {x, py + ph - 42, cw, 34}, scale, TEMPLATE_MUTED)
	}
	if len(model.submodules) == 0 do return

	// The list moves down only while a status message is shown.
	list_top: f32 = busy || state.error != "" || model.submodule_error != "" || state.notice != "" ? 92 : 58
	viewport := ui.Rect2d{x, py + list_top, cw, ph - list_top - 50}
	ui.begin_window(ctx, template_rect(viewport, scale), "submodules-list")
	row :: GITARIS_SUBMODULE_ROW
	first, last, offset := gitaris_scroll_begin(ctx, viewport, len(model.submodules), row, scale)
	update, open := -1, -1
	for i in first..<last {
		info := model.submodules[i]
		y := viewport.y + f32(i) * row - offset
		focused := i == state.submodule_focus
		template_box(ctx, {x, y, cw - 8, row - 8}, focused ? TEMPLATE_SELECTED : TEMPLATE_SURFACE, 12, scale)
		template_box(ctx, {x + 14, y + 17, 10, 10}, gitaris_submodule_color(info), 5, scale)
		label, detail := workspace.submodule_describe(info, repo)
		attention := workspace.submodule_attention(info)
		template_label(ctx, title, info.path, {x + 34, y + 9, cw - 380, 26}, 15, TEMPLATE_TEXT, scale)
		tag_x := x + 34 + min(template_text_width(ctx, title, info.path, 15, scale) + 10, cw - 380)
		template_tag(ctx, face, label, tag_x, y + 13, attention ? TEMPLATE_WARNING : TEMPLATE_CARD, attention ? TEMPLATE_LIGHT : TEMPLATE_TEXT, scale)
		template_label(ctx, face, detail, {x + 34, y + 34, cw - 250, 18}, 11, TEMPLATE_TEXT, scale)
		recorded := workspace.submodule_recorded(info)
		commits := fmt.tprintf("recorded %s  ·  checked out %s  ·  %s", recorded != "" ? recorded : "—",
			info.workdir != "" ? info.workdir : "—", info.url)
		if info.branch != "" do commits = fmt.tprintf("%s  ·  branch %s", commits, info.branch)
		template_label(ctx, mono, commits, {x + 34, y + 54, cw - 250, 16}, 10, TEMPLATE_MUTED, scale)
		if gitaris_button(ctx, face, "Update", {x + cw - 214, y + 22, 92, 32}, scale, id = fmt.tprintf("update:%s", info.name)) && !busy {
			update = i
		}
		open_label := info.checked_out ? "Open  →" : "Open"
		if gitaris_button(ctx, face, open_label, {x + cw - 114, y + 22, 100, 32}, scale, info.checked_out, id = fmt.tprintf("open:%s", info.name)) {
			open = i
		}
	}
	gitaris_scroll_end(ctx, viewport, scale)
	if update >= 0 {
		state.submodule_focus = update
		gitaris_submodule_update(state, model.submodules[update].name)
	}
	if open >= 0 {
		state.submodule_focus = open
		if gitaris_enter_submodule(state, open) do gitaris_reset_scroll(ctx)
	}
}
