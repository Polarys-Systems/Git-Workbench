package app

// The menu bar along the top and the Project/Preferences settings panels.

import "core:fmt"

import font_core "../font"
import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

// After switching repositories, lists start again from the top.
workbench_reset_scroll :: proc(ctx: ^ui.UiContext) {
	for &window in ctx.windows do window.scroll_offset = {}
}

// Resets only the named lists (e.g. the diff when another file is chosen).
workbench_reset_windows :: proc(ctx: ^ui.UiContext, names: ..string) {
	for name in names {
		id := ui.make_id(name)
		for &window in ctx.windows do if window.id == id do window.scroll_offset = {}
	}
}

// A borderless text button (breadcrumb links).
workbench_link :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text, id: string, rect: ui.Rect2d,
	size: f32, color: [4]f32, scale: f32) -> bool {
	style := workbench_control_style(face, scale)
	style.font_size = size * scale
	style.padding = 6 * scale
	style.radius = 8 * scale
	style.text_color = color
	style.color_top, style.color_bottom = {0, 0, 0, 0}, {0, 0, 0, 0}
	style.hover_color, style.active_color = THEME_HOVER, THEME_BUTTON
	ui.style_push(ctx, style)
	result := ui.button(ctx, text, theme_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

// A menu tab. The active one is charcoal; the others are light pills.
workbench_tab :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text, id: string, x, y, width: f32,
	active: bool, scale: f32) -> bool {
	style := workbench_control_style(face, scale, active)
	if !active {
		style.color_top, style.color_bottom = THEME_CARD, THEME_CARD
		style.hover_color, style.active_color = THEME_LIGHT, THEME_HOVER
	}
	style.padding = 14 * scale
	ui.style_push(ctx, style)
	result := ui.button(ctx, text, theme_rect({x, y, width, 32}, scale), {.NONE}, id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

Workbench_Tab :: struct {
	text, id: string,
	menu: Workbench_Menu,
	badge: int, // Shown as a count after the text when > 0.
	warn: bool, // The badge needs attention.
}

workbench_menu_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face, state: ^Workbench, w, scale: f32) {
	ui.begin_window(ctx, theme_rect({0, 0, w, MENU_HEIGHT}, scale), "menu-bar")
	busy := workspace.remote_busy(&state.remote)
	attention := workspace.submodule_attention_count(state.model)
	tabs := [?]Workbench_Tab{
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
		widths[i] = theme_text_width(ctx, face, tab.text, 13, scale) + 28
		if tab.badge > 0 do widths[i] += 24
		total += widths[i] + 6
	}
	x := w - PANEL_GAP - total + 6
	tabs_start := x
	for tab, i in tabs {
		active := state.menu == tab.menu
		if workbench_tab(ctx, face, tab.text, tab.id, x, 10, widths[i], active, scale) {
			workbench_open_menu(state, active || tab.menu == .NONE ? .NONE : tab.menu)
		}
		if tab.badge > 0 {
			fill, color := THEME_HIGHLIGHT, THEME_DARK
			if tab.warn do fill, color = THEME_WARNING, THEME_LIGHT
			theme_box(ctx, {x + widths[i] - 32, 17, 20, 18}, fill, 9, scale)
			theme_label(ctx, face, fmt.tprintf("%d", tab.badge), {x + widths[i] - 32, 17, 20, 18}, 10, color, scale, {.CENTER})
		}
		x += widths[i] + 6
	}

	// Breadcrumb: the saved project, then each submodule entered. Ancestors
	// are links back up; the open repository is in bold, tagged when it is
	// a submodule, so it is always clear where commits and syncs go.
	theme_box(ctx, {PANEL_GAP + 2, 12, 28, 28}, THEME_HIGHLIGHT, 14, scale)
	theme_label(ctx, icons, "", {PANEL_GAP + 2, 12, 28, 28}, 16, THEME_DARK, scale, {.CENTER})
	crumbs := workbench_crumbs(state)
	crumb_x: f32 = PANEL_GAP + 38
	limit := tabs_start - 12
	for crumb, i in crumbs {
		last := i == len(crumbs) - 1
		if i > 0 {
			theme_label(ctx, face, "›", {crumb_x, 10, 14, 32}, 16, THEME_MUTED, scale, {.CENTER})
			crumb_x += 16
		}
		width := min(theme_text_width(ctx, title, crumb, 14, scale) + 12, max(40, limit - crumb_x))
		if last {
			theme_label(ctx, title, crumb, {crumb_x + 6, 10, width - 6, 32}, 14, THEME_TEXT, scale)
		} else if workbench_link(ctx, title, crumb, fmt.tprintf("crumb-%d", i), {crumb_x, 12, width, 28}, 14, THEME_MUTED, scale) {
			if workbench_leave_to(state, i) do workbench_reset_scroll(ctx)
		}
		crumb_x += width + 2
	}
	if len(crumbs) > 1 {
		crumb_x += 4
		crumb_x += theme_tag(ctx, face, "SUBMODULE", crumb_x, 17, THEME_HIGHLIGHT, THEME_DARK, scale)
	}
	// Push/pull/update progress and results stay visible from every view.
	status, color := "", THEME_MUTED
	if busy {
		status, color = workbench_remote_progress(state), THEME_ACCENT
	} else if state.notice != "" {
		status, color = state.notice, THEME_ADDITION_TEXT
	}
	if status != "" && limit - crumb_x > 60 {
		theme_label(ctx, face, status, {crumb_x + 14, 10, limit - crumb_x - 14, 32}, 12, color, scale)
	}
}

workbench_settings_ui :: proc(ctx: ^ui.UiContext, face, title: ^font_core.Face,
	state: ^Workbench, window: ^SDL.Window, w, h, scale: f32) {
	ui.begin_window(ctx, theme_rect({0, MENU_HEIGHT, w, h - MENU_HEIGHT}, scale), "workspace-settings")
	preferences := state.menu == .PREFERENCES
	panel_w := min(w - 2 * PANEL_GAP, 560)
	panel_h: f32 = preferences ? 392 : 236
	panel_x := (w - panel_w) * 0.5
	panel_y := MENU_HEIGHT + max(PANEL_GAP, (h - MENU_HEIGHT - panel_h) * 0.4) + (1 - state.view_enter.value) * 10
	theme_panel(ctx, {panel_x, panel_y, panel_w, panel_h}, THEME_CARD, 18, scale)
	x, field_w := panel_x + 24, panel_w - 48
	theme_label(ctx, title, preferences ? "Preferences" : "Open project", {x, panel_y + 20, field_w, 30}, 20, THEME_TEXT, scale)
	submit := false
	if preferences {
		_ = workbench_field(ctx, face, "username", "Commit name", "Your name", &state.username,
			{x, panel_y + 84, field_w, 38}, scale)
		submit = workbench_field(ctx, face, "email", "Commit email", "you@example.com", &state.email,
			{x, panel_y + 152, field_w, 38}, scale) == .SUBMIT
		_ = workbench_field(ctx, face, "ssh", "SSH key location", "~/.ssh or a private key file", &state.ssh,
			{x, panel_y + 220, field_w - 164, 38}, scale)
		if workbench_button(ctx, face, "Folder", {x + field_w - 158, panel_y + 220, 76, 38}, scale) {
			workbench_pick(state, window, project = false, file = false)
		}
		if workbench_button(ctx, face, "Key file", {x + field_w - 76, panel_y + 220, 76, 38}, scale) {
			workbench_pick(state, window, project = false, file = true)
		}
		theme_label(ctx, face, "Only the location is saved; your keys stay in place.", {x, panel_y + 262, field_w, 18}, 11, THEME_MUTED, scale)
	} else {
		submit = workbench_field(ctx, face, "project", "Project folder", "A local Git repository · WSL works too: /home/you/project", &state.project,
			{x, panel_y + 84, field_w - 100, 38}, scale) == .SUBMIT
		if workbench_button(ctx, face, "Browse...", {x + field_w - 92, panel_y + 84, 92, 38}, scale) {
			workbench_pick(state, window, project = true, file = false)
		}
		if len(state.parents) > 0 {
			theme_label(ctx, face, "Opening a project leaves the submodule you are in.", {x, panel_y + 126, field_w, 18}, 11, THEME_MUTED, scale)
		}
	}
	if state.error != "" do workbench_message(ctx, face, state.error, {x, panel_y + panel_h - 104, field_w, 34}, scale)
	if workbench_button(ctx, face, "Cancel", {x + field_w - 204, panel_y + panel_h - 64, 96, 36}, scale) || ctx.input.key_pressed[.ESCAPE] {
		workbench_open_menu(state, .NONE)
	}
	clicked := workbench_button(ctx, face, preferences ? "Save" : "Open", {x + field_w - 100, panel_y + panel_h - 64, 100, 36}, scale, true)
	if state.menu != .NONE && !state.picker_pending && (clicked || submit) {
		workbench_start(state)
		if state.error == "" do workbench_reset_scroll(ctx)
	}
	theme_label(ctx, face, "Saved in gitaris.json in the current execution folder.", {x, panel_y + panel_h - 24, field_w, 16}, 10, THEME_MUTED, scale)
}
