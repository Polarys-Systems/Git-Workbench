package app

import font_core "../font"
import "../ui"
import SDL "vendor:sdl3"

gitaris_welcome_ui :: proc(ctx: ^ui.UiContext, face, title, welcome, icons: ^font_core.Face,
	state: ^Gitaris, window: ^SDL.Window, w, h, scale: f32) {
	ui.begin_window(ctx, template_rect({0, 0, w, h}, scale), "welcome")
	cw := min(w - 64, 1320)
	cx := (w - cw) * 0.5
	cy := max(24, (h - 660) * 0.5) + (1 - state.view_enter.value) * 12
	template_panel(ctx, {cx, cy, cw, 660}, TEMPLATE_SURFACE, 24, scale)
	x := cx + 40
	left_w := cw * 0.44 - 64
	template_label(ctx, icons, "\uf1d3", {x, cy + 40, 32, 36}, 28, TEMPLATE_ACCENT, scale)
	template_label(ctx, title, "gitaris", {x + 44, cy + 40, left_w - 44, 36}, 23, TEMPLATE_TEXT, scale)
	// Gambarino ships in Regular only. A subpixel overprint supplies faux bold.
	bold_offsets := [?]f32{0, 0.7}
	for offset in bold_offsets {
		template_label(ctx, welcome, "Welcome.", {x + offset, cy + 146, left_w, 104}, 74, TEMPLATE_TEXT, scale)
	}
	template_label(ctx, face, "A little clarity for your code.", {x, cy + 258, left_w, 32}, 19, TEMPLATE_TEXT, scale)
	template_label(ctx, face, "To start working, tell me where\nto look for your SSH keys.", {x, cy + 316, left_w, 64}, 17, TEMPLATE_MUTED, scale)
	template_label(ctx, face, "Then choose a project and the name\nand email you'll use for commits.", {x, cy + 398, left_w, 64}, 16, TEMPLATE_MUTED, scale)
	template_box(ctx, {x, cy + 536, 42, 2}, TEMPLATE_ACCENT, 0, scale)
	template_label(ctx, face, "Your workspace, ready when you are.", {x, cy + 554, left_w, 28}, 13, TEMPLATE_MUTED, scale)

	fx := cx + cw * 0.46
	fw := cw * 0.54 - 40
	template_label(ctx, title, "Make yourself at home", {fx, cy + 40, fw, 38}, 25, TEMPLATE_TEXT, scale)
	template_label(ctx, face, "A few details, and you're ready to explore.", {fx, cy + 83, fw, 26}, 14, TEMPLATE_MUTED, scale)
	_ = gitaris_field(ctx, face, "ssh", "SSH key location", "~/.ssh or a private key file", &state.ssh,
		{fx, cy + 156, fw - 156, 44}, scale)
	if gitaris_button(ctx, face, "Folder", {fx + fw - 146, cy + 156, 70, 44}, scale) {
		gitaris_pick(state, window, project = false, file = false)
	}
	if gitaris_button(ctx, face, "Key file", {fx + fw - 70, cy + 156, 70, 44}, scale) {
		gitaris_pick(state, window, project = false, file = true)
	}
	template_label(ctx, face, "Only the location is saved; your keys stay in place.", {fx, cy + 206, fw, 22}, 12, TEMPLATE_MUTED, scale)
	_ = gitaris_field(ctx, face, "project", "Project", "Choose a local Git repository", &state.project,
		{fx, cy + 270, fw - 100, 44}, scale)
	if gitaris_button(ctx, face, "Browse...", {fx + fw - 90, cy + 270, 90, 44}, scale) {
		gitaris_pick(state, window, project = true, file = false)
	}
	_ = gitaris_field(ctx, face, "username", "Commit name", "Your name", &state.username,
		{fx, cy + 360, fw, 44}, scale)
	submit := gitaris_field(ctx, face, "email", "Commit email", "you@example.com", &state.email,
		{fx, cy + 450, fw, 44}, scale) == .SUBMIT
	if state.error != "" {
		// Wrap error text into short lines to keep actionable feedback visible.
		gitaris_message(ctx, face, state.error, {fx, cy + 501, fw, 52}, scale)
	}
	clicked := gitaris_button(ctx, title, state.picker_pending ? "Choose a location..." : "Open my workspace  →",
		{fx, cy + 563, fw, 46}, scale, true, id = "open-workspace")
	if (clicked || submit) && !state.picker_pending do gitaris_start(state)
	template_label(ctx, face, "Saved in gitaris.json in the current execution folder.", {fx, cy + 618, fw, 22}, 11, TEMPLATE_MUTED, scale)
}
