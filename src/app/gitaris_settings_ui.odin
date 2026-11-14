package app

import font_core "../font"
import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

GITARIS_MENU_HEIGHT :: 48

gitaris_menu_ui :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Gitaris, w, scale: f32) {
	ui.begin_window(ctx, template_rect({0, 0, w, GITARIS_MENU_HEIGHT}, scale), "menu-bar")
	if gitaris_button(ctx, face, "Project", {24, 8, 104, 32}, scale) {
		gitaris_open_menu(state, state.menu == .PROJECT ? .NONE : .PROJECT)
	}
	if gitaris_button(ctx, face, "Preferences", {136, 8, 128, 32}, scale) {
		gitaris_open_menu(state, state.menu == .PREFERENCES ? .NONE : .PREFERENCES)
	}
	if gitaris_button(ctx, face, "Merge editor", {272, 8, 128, 32}, scale) {
		gitaris_open_menu(state, state.menu == .MERGE ? .NONE : .MERGE)
	}
	busy := workspace.remote_busy(&state.remote)
	if gitaris_button(ctx, face, busy ? "Sync ···" : "Sync", {408, 8, 96, 32}, scale, id = "menu-sync") {
		gitaris_open_menu(state, state.menu == .SYNC ? .NONE : .SYNC)
	}
	// Push/pull results stay visible from every view.
	status, color := state.model.config.project_path, TEMPLATE_MUTED
	if busy {
		status, color = gitaris_remote_progress(state), TEMPLATE_ACCENT
	} else if state.notice != "" {
		status, color = state.notice, GITARIS_ADD_TEXT
	}
	template_label(ctx, face, status, {528, 8, w - 552, 32}, 12, color, scale, {.RIGHT})
	template_box(ctx, {0, GITARIS_MENU_HEIGHT - 1, w, 1}, TEMPLATE_LINE, 0, scale)
}

gitaris_settings_ui :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face,
	state: ^Gitaris, window: ^SDL.Window, w, h, scale: f32) {
	ui.begin_window(ctx, template_rect({0, GITARIS_MENU_HEIGHT, w, h - GITARIS_MENU_HEIGHT}, scale), "workspace-settings")
	preferences := state.menu == .PREFERENCES
	pw := min(w - 64, 640)
	ph: f32 = preferences ? 508 : 332
	px := (w - pw) * 0.5
	py := GITARIS_MENU_HEIGHT + max(24, (h - GITARIS_MENU_HEIGHT - ph) * 0.5) + (1 - state.view_enter.value) * 12
	template_panel(ctx, {px, py, pw, ph}, TEMPLATE_SURFACE, 22, scale)
	x, fw := px + 32, pw - 64
	template_label(ctx, title, preferences ? "Preferences" : "Open project", {x, py + 24, fw, 38}, 26, TEMPLATE_TEXT, scale)
	submit := false
	if preferences {
		_ = gitaris_field(ctx, face, "username", "Commit name", "Your name", &state.username,
			{x, py + 112, fw, 44}, scale)
		submit = gitaris_field(ctx, face, "email", "Commit email", "you@example.com", &state.email,
			{x, py + 196, fw, 44}, scale) == .SUBMIT
		_ = gitaris_field(ctx, face, "ssh", "SSH key location", "~/.ssh or a private key file", &state.ssh,
			{x, py + 280, fw - 156, 44}, scale)
		if gitaris_button(ctx, face, "Folder", {x + fw - 146, py + 280, 70, 44}, scale) {
			gitaris_pick(state, window, project = false, file = false)
		}
		if gitaris_button(ctx, face, "Key file", {x + fw - 70, py + 280, 70, 44}, scale) {
			gitaris_pick(state, window, project = false, file = true)
		}
		template_label(ctx, face, "Only the location is saved; your keys stay in place.", {x, py + 330, fw, 22}, 12, TEMPLATE_MUTED, scale)
	} else {
		submit = gitaris_field(ctx, face, "project", "Project folder", "Choose a local Git repository", &state.project,
			{x, py + 112, fw - 100, 44}, scale) == .SUBMIT
		if gitaris_button(ctx, face, "Browse...", {x + fw - 90, py + 112, 90, 44}, scale) {
			gitaris_pick(state, window, project = true, file = false)
		}
	}
	if state.error != "" do gitaris_message(ctx, face, state.error, {x, py + ph - 140, fw, 54}, scale)
	if gitaris_button(ctx, face, "Cancel", {x + fw - 220, py + ph - 72, 96, 40}, scale) || ctx.input.key_pressed[.ESCAPE] {
		gitaris_open_menu(state, .NONE)
	}
	clicked := gitaris_button(ctx, face, preferences ? "Save" : "Open", {x + fw - 112, py + ph - 72, 112, 40}, scale, true)
	if state.menu != .NONE && !state.picker_pending && (clicked || submit) {
		gitaris_start(state)
		if state.error == "" {
			ctx.windows[1].scroll_offset = {}
			ctx.windows[2].scroll_offset = {}
		}
	}
	template_label(ctx, face, "Saved in gitaris.json in the current execution folder.", {x, py + ph - 26, fw, 20}, 11, TEMPLATE_MUTED, scale)
}
