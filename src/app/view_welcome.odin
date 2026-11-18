package app

// First-run screen: SSH key, project folder and commit identity.

import font_core "../font"
import "../ui"
import SDL "vendor:sdl3"

workbench_welcome_ui :: proc(ctx: ^ui.UiContext, face, title, welcome, icons: ^font_core.Face,
	state: ^Workbench, window: ^SDL.Window, w, h, scale: f32) {
	ui.begin_window(ctx, theme_rect({0, 0, w, h}, scale), "welcome")
	card_w := min(w - 64, 1320)
	card_x := (w - card_w) * 0.5
	card_y := max(24, (h - 660) * 0.5) + (1 - state.view_enter.value) * 12
	theme_panel(ctx, {card_x, card_y, card_w, 660}, THEME_SURFACE, 24, scale)
	x := card_x + 40
	left_w := card_w * 0.44 - 64
	theme_label(ctx, icons, "\uf1d3", {x, card_y + 40, 32, 36}, 28, THEME_ACCENT, scale)
	theme_label(ctx, title, "git-workbench", {x + 44, card_y + 40, left_w - 44, 36}, 23, THEME_TEXT, scale)
	// Gambarino ships in Regular only. A subpixel overprint supplies faux bold.
	bold_offsets := [?]f32{0, 0.7}
	for offset in bold_offsets {
		theme_label(ctx, welcome, "Welcome.", {x + offset, card_y + 146, left_w, 104}, 74, THEME_TEXT, scale)
	}
	theme_label(ctx, face, "A little clarity for your code.", {x, card_y + 258, left_w, 32}, 19, THEME_TEXT, scale)
	theme_label(ctx, face, "To start working, tell me where\nto look for your SSH keys.", {x, card_y + 316, left_w, 64}, 17, THEME_MUTED, scale)
	theme_label(ctx, face, "Then choose a project and the name\nand email you'll use for commits.", {x, card_y + 398, left_w, 64}, 16, THEME_MUTED, scale)
	theme_box(ctx, {x, card_y + 536, 42, 2}, THEME_ACCENT, 0, scale)
	theme_label(ctx, face, "Your workspace, ready when you are.", {x, card_y + 554, left_w, 28}, 13, THEME_MUTED, scale)

	form_x := card_x + card_w * 0.46
	form_w := card_w * 0.54 - 40
	theme_label(ctx, title, "Make yourself at home", {form_x, card_y + 40, form_w, 38}, 25, THEME_TEXT, scale)
	theme_label(ctx, face, "A few details, and you're ready to explore.", {form_x, card_y + 83, form_w, 26}, 14, THEME_MUTED, scale)
	_ = workbench_field(ctx, face, "ssh", "SSH key location", "~/.ssh or a private key file", &state.ssh,
		{form_x, card_y + 156, form_w - 156, 44}, scale)
	if workbench_button(ctx, face, "Folder", {form_x + form_w - 146, card_y + 156, 70, 44}, scale) {
		workbench_pick(state, window, project = false, file = false)
	}
	if workbench_button(ctx, face, "Key file", {form_x + form_w - 70, card_y + 156, 70, 44}, scale) {
		workbench_pick(state, window, project = false, file = true)
	}
	theme_label(ctx, face, "Only the location is saved; your keys stay in place.", {form_x, card_y + 206, form_w, 22}, 12, THEME_MUTED, scale)
	_ = workbench_field(ctx, face, "project", "Project", "A local Git repository · WSL works too: /home/you/project", &state.project,
		{form_x, card_y + 270, form_w - 100, 44}, scale)
	if workbench_button(ctx, face, "Browse...", {form_x + form_w - 90, card_y + 270, 90, 44}, scale) {
		workbench_pick(state, window, project = true, file = false)
	}
	_ = workbench_field(ctx, face, "username", "Commit name", "Your name", &state.username,
		{form_x, card_y + 360, form_w, 44}, scale)
	submit := workbench_field(ctx, face, "email", "Commit email", "you@example.com", &state.email,
		{form_x, card_y + 450, form_w, 44}, scale) == .SUBMIT
	if state.error != "" {
		// Wrap error text into short lines to keep actionable feedback visible.
		workbench_message(ctx, face, state.error, {form_x, card_y + 501, form_w, 52}, scale)
	}
	clicked := workbench_button(ctx, title, state.picker_pending ? "Choose a location..." : "Open my workspace  →",
		{form_x, card_y + 563, form_w, 46}, scale, true, id = "open-workspace")
	if (clicked || submit) && !state.picker_pending do workbench_start(state)
	theme_label(ctx, face, "Saved in gitaris.json in the current execution folder.", {form_x, card_y + 618, form_w, 22}, 11, THEME_MUTED, scale)
}
