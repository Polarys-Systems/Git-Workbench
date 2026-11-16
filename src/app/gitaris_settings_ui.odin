package app

import "core:fmt"

import font_core "../font"
import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

GITARIS_MENU_HEIGHT :: 52
// Outer margin and gap between panels, and padding inside them.
GITARIS_GAP :: 12
GITARIS_PAD :: 16

// After switching repositories, lists start again from the top.
gitaris_reset_scroll :: proc(ctx: ^ui.UiContext) {
	for &window in ctx.windows do window.scroll_offset = {}
}

// Resets only the named lists (e.g. the diff when another file is chosen).
gitaris_reset_windows :: proc(ctx: ^ui.UiContext, names: ..string) {
	for name in names {
		id := ui.make_id(name)
		for &window in ctx.windows do if window.id == id do window.scroll_offset = {}
	}
}

// A borderless text button (breadcrumb links).
gitaris_link :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text, id: string, rect: ui.Rect2d,
	size: f32, color: [4]f32, scale: f32) -> bool {
	style := gitaris_control_style(face, scale)
	style.font_size = size * scale
	style.padding = 6 * scale
	style.radius = 8 * scale
	style.text_color = color
	style.color_top, style.color_bottom = {0, 0, 0, 0}, {0, 0, 0, 0}
	style.hover_color, style.active_color = TEMPLATE_HOVER, TEMPLATE_BUTTON
	ui.style_push(ctx, style)
	result := ui.button(ctx, text, template_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

// A menu tab. The active one is charcoal; the others are light pills.
gitaris_tab :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text, id: string, x, y, width: f32,
	active: bool, scale: f32) -> bool {
	style := gitaris_control_style(face, scale, active)
	if !active {
		style.color_top, style.color_bottom = TEMPLATE_CARD, TEMPLATE_CARD
		style.hover_color, style.active_color = TEMPLATE_LIGHT, TEMPLATE_HOVER
	}
	style.padding = 14 * scale
	ui.style_push(ctx, style)
	result := ui.button(ctx, text, template_rect({x, y, width, 32}, scale), {.NONE}, id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

Gitaris_Tab :: struct {
	text, id: string,
	menu: Gitaris_Menu,
	badge: int, // Shown as a count after the text when > 0.
	warn: bool, // The badge needs attention.
}

gitaris_menu_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face, state: ^Gitaris, w, scale: f32) {
	ui.begin_window(ctx, template_rect({0, 0, w, GITARIS_MENU_HEIGHT}, scale), "menu-bar")
	busy := workspace.remote_busy(&state.remote)
	attention := workspace.submodule_attention_count(state.model)
	tabs := [?]Gitaris_Tab{
		{"History", "menu-history", .NONE, 0, false},
		{"Submodules", "menu-submodules", .SUBMODULES, attention > 0 ? attention : len(state.model.submodules), attention > 0},
		{"Merge editor", "menu-merge", .MERGE, 0, false},
		{busy ? "Sync ···" : "Sync", "menu-sync", .SYNC, 0, false},
		{"Project", "menu-project", .PROJECT, 0, false},
		{"Preferences", "menu-preferences", .PREFERENCES, 0, false},
	}
	widths: [len(tabs)]f32
	total: f32 = 0
	for tab, i in tabs {
		widths[i] = template_text_width(ctx, face, tab.text, 13, scale) + 28
		if tab.badge > 0 do widths[i] += 24
		total += widths[i] + 6
	}
	x := w - GITARIS_GAP - total + 6
	tabs_start := x
	for tab, i in tabs {
		active := state.menu == tab.menu
		if gitaris_tab(ctx, face, tab.text, tab.id, x, 10, widths[i], active, scale) {
			gitaris_open_menu(state, active || tab.menu == .NONE ? .NONE : tab.menu)
		}
		if tab.badge > 0 {
			fill, color := TEMPLATE_HIGHLIGHT, TEMPLATE_DARK
			if tab.warn do fill, color = TEMPLATE_WARNING, TEMPLATE_LIGHT
			template_box(ctx, {x + widths[i] - 32, 17, 20, 18}, fill, 9, scale)
			template_label(ctx, face, fmt.tprintf("%d", tab.badge), {x + widths[i] - 32, 17, 20, 18}, 10, color, scale, {.CENTER})
		}
		x += widths[i] + 6
	}

	// Breadcrumb: the saved project, then each submodule entered. Ancestors
	// are links back up; the open repository is in bold, tagged when it is
	// a submodule, so it is always clear where commits and syncs go.
	template_box(ctx, {GITARIS_GAP + 2, 12, 28, 28}, TEMPLATE_HIGHLIGHT, 14, scale)
	template_label(ctx, icons, "", {GITARIS_GAP + 2, 12, 28, 28}, 16, TEMPLATE_DARK, scale, {.CENTER})
	crumbs := gitaris_crumbs(state)
	cx: f32 = GITARIS_GAP + 38
	limit := tabs_start - 12
	for crumb, i in crumbs {
		last := i == len(crumbs) - 1
		if i > 0 {
			template_label(ctx, face, "›", {cx, 10, 14, 32}, 16, TEMPLATE_MUTED, scale, {.CENTER})
			cx += 16
		}
		width := min(template_text_width(ctx, title, crumb, 14, scale) + 12, max(40, limit - cx))
		if last {
			template_label(ctx, title, crumb, {cx + 6, 10, width - 6, 32}, 14, TEMPLATE_TEXT, scale)
		} else if gitaris_link(ctx, title, crumb, fmt.tprintf("crumb-%d", i), {cx, 12, width, 28}, 14, TEMPLATE_MUTED, scale) {
			if gitaris_leave_to(state, i) do gitaris_reset_scroll(ctx)
		}
		cx += width + 2
	}
	if len(crumbs) > 1 {
		cx += 4
		cx += template_tag(ctx, face, "SUBMODULE", cx, 17, TEMPLATE_HIGHLIGHT, TEMPLATE_DARK, scale)
	}
	// Push/pull/update progress and results stay visible from every view.
	status, color := "", TEMPLATE_MUTED
	if busy {
		status, color = gitaris_remote_progress(state), TEMPLATE_ACCENT
	} else if state.notice != "" {
		status, color = state.notice, GITARIS_ADD_TEXT
	}
	if status != "" && limit - cx > 60 {
		template_label(ctx, face, status, {cx + 14, 10, limit - cx - 14, 32}, 12, color, scale)
	}
}

gitaris_settings_ui :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face,
	state: ^Gitaris, window: ^SDL.Window, w, h, scale: f32) {
	ui.begin_window(ctx, template_rect({0, GITARIS_MENU_HEIGHT, w, h - GITARIS_MENU_HEIGHT}, scale), "workspace-settings")
	preferences := state.menu == .PREFERENCES
	pw := min(w - 2 * GITARIS_GAP, 560)
	ph: f32 = preferences ? 392 : 236
	px := (w - pw) * 0.5
	py := GITARIS_MENU_HEIGHT + max(GITARIS_GAP, (h - GITARIS_MENU_HEIGHT - ph) * 0.4) + (1 - state.view_enter.value) * 10
	template_panel(ctx, {px, py, pw, ph}, TEMPLATE_CARD, 18, scale)
	x, fw := px + 24, pw - 48
	template_label(ctx, title, preferences ? "Preferences" : "Open project", {x, py + 20, fw, 30}, 20, TEMPLATE_TEXT, scale)
	submit := false
	if preferences {
		_ = gitaris_field(ctx, face, "username", "Commit name", "Your name", &state.username,
			{x, py + 84, fw, 38}, scale)
		submit = gitaris_field(ctx, face, "email", "Commit email", "you@example.com", &state.email,
			{x, py + 152, fw, 38}, scale) == .SUBMIT
		_ = gitaris_field(ctx, face, "ssh", "SSH key location", "~/.ssh or a private key file", &state.ssh,
			{x, py + 220, fw - 164, 38}, scale)
		if gitaris_button(ctx, face, "Folder", {x + fw - 158, py + 220, 76, 38}, scale) {
			gitaris_pick(state, window, project = false, file = false)
		}
		if gitaris_button(ctx, face, "Key file", {x + fw - 76, py + 220, 76, 38}, scale) {
			gitaris_pick(state, window, project = false, file = true)
		}
		template_label(ctx, face, "Only the location is saved; your keys stay in place.", {x, py + 262, fw, 18}, 11, TEMPLATE_MUTED, scale)
	} else {
		submit = gitaris_field(ctx, face, "project", "Project folder", "A local Git repository · WSL works too: /home/you/project", &state.project,
			{x, py + 84, fw - 100, 38}, scale) == .SUBMIT
		if gitaris_button(ctx, face, "Browse...", {x + fw - 92, py + 84, 92, 38}, scale) {
			gitaris_pick(state, window, project = true, file = false)
		}
		if len(state.parents) > 0 {
			template_label(ctx, face, "Opening a project leaves the submodule you are in.", {x, py + 126, fw, 18}, 11, TEMPLATE_MUTED, scale)
		}
	}
	if state.error != "" do gitaris_message(ctx, face, state.error, {x, py + ph - 104, fw, 34}, scale)
	if gitaris_button(ctx, face, "Cancel", {x + fw - 204, py + ph - 64, 96, 36}, scale) || ctx.input.key_pressed[.ESCAPE] {
		gitaris_open_menu(state, .NONE)
	}
	clicked := gitaris_button(ctx, face, preferences ? "Save" : "Open", {x + fw - 100, py + ph - 64, 100, 36}, scale, true)
	if state.menu != .NONE && !state.picker_pending && (clicked || submit) {
		gitaris_start(state)
		if state.error == "" do gitaris_reset_scroll(ctx)
	}
	template_label(ctx, face, "Saved in gitaris.json in the current execution folder.", {x, py + ph - 24, fw, 16}, 10, TEMPLATE_MUTED, scale)
}
