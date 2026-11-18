package app

// Top-level UI: picks which view to draw (welcome, settings, workspace
// and its sub-views), keeps the window title current and animates view changes.

import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

workbench_ui :: proc(ctx: ^ui.UiContext, face, title, welcome, icons: ^font_core.Face,
	state: ^Workbench, window: ^SDL.Window, width, height, scale: f32, mono: ^font_core.Face = nil) {
	workbench_remote_poll(state)
	workbench_scan_poll(state)
	workbench_animate_view(ctx, state)
	workbench_window_title(state, window)
	logical_width, logical_height := width / scale, height / scale
	code_face := mono != nil ? mono : face
	ui.begin(ctx, width, height)
	// Window backgrounds are transparent; the page color is the clear color.
	style := ui.default_style
	style.color_top, style.color_bottom = {0, 0, 0, 0}, {0, 0, 0, 0}
	style.radius = 0
	ui.style_push(ctx, style)
	content_end := 0
	if state.ready {
		switch state.menu {
		case .NONE: workbench_history_ui(ctx, face, title, icons, state, logical_width, logical_height, scale, code_face)
		case .MERGE: workbench_merge_ui(ctx, face, title, code_face, state, logical_width, logical_height, scale)
		case .SYNC: workbench_sync_ui(ctx, face, title, state, logical_width, logical_height, scale)
		case .SUBMODULES: workbench_submodules_ui(ctx, face, title, code_face, state, logical_width, logical_height, scale)
		case .PROJECT, .PREFERENCES: workbench_settings_ui(ctx, face, title, state, window, logical_width, logical_height, scale)
		}
		content_end = ctx.n_boxes
		workbench_menu_ui(ctx, face, title, icons, state, logical_width, scale)
		if state.dialog != .NONE {
			workbench_dialog_ui(ctx, face, title, code_face, state, logical_width, logical_height, scale)
		} else {
			workbench_modal_first_box = -1
		}
	} else {
		state.dialog = .NONE
		workbench_modal_first_box = -1
		workbench_welcome_ui(ctx, face, title, welcome, icons, state, window, logical_width, logical_height, scale)
		content_end = ctx.n_boxes
	}
	ui.style_pop(ctx)
	ui.end(ctx)
	ui.fade_elements(ctx, 0, content_end, state.view_enter.value)
}

// The title bar names the open repository, including the submodule path.
workbench_window_title :: proc(state: ^Workbench, window: ^SDL.Window) {
	text := "Git-Workbench"
	if state.ready {
		crumbs := workbench_crumbs(state)
		text = strings.concatenate({strings.join(crumbs[:], " › ", context.temp_allocator), " — Git-Workbench"}, context.temp_allocator)
	}
	if text == state.window_title do return
	delete(state.window_title)
	state.window_title = strings.clone(text)
	if window != nil do _ = SDL.SetWindowTitle(window, strings.clone_to_cstring(text, context.temp_allocator))
}

workbench_animate_view :: proc(ctx: ^ui.UiContext, state: ^Workbench) {
	view := "welcome"
	if state.ready {
		switch state.menu {
		case .NONE:
			view = "history"
			if workspace.changes_open(state.model.changes) {
				view = state.model.changes.working ? "working-changes" : "changes"
			}
		case .PROJECT: view = "project"
		case .PREFERENCES: view = "preferences"
		case .MERGE: view = "merge"
		case .SYNC: view = "sync"
		case .SUBMODULES: view = "submodules"
		}
		// Switching repositories replays the entrance, a visible cue.
		view = strings.concatenate({view, "@", state.model.config.project_path}, context.temp_allocator)
	}
	id := ui.make_id(view)
	if state.view_id != id {
		state.view_id = id
		ui.anim_float_set(&state.view_enter, 0)
		ui.anim_float_to(&state.view_enter, 1, 0.22, .Out_Cubic)
	}
	if !ctx.animations_enabled || ctx.delta_time <= 0 {
		ui.anim_float_set(&state.view_enter, 1)
	} else {
		ui.anim_float_tick(&state.view_enter, ctx.delta_time)
	}
}
