package app

import font_core "../font"
import "../ui"
import "../workspace"
import SDL "vendor:sdl3"

gitaris_ui :: proc(ctx: ^ui.UiContext, face, title, welcome, icons: ^font_core.Face,
	state: ^Gitaris, window: ^SDL.Window, width, height, scale: f32, mono: ^font_core.Face = nil) {
	gitaris_remote_poll(state)
	gitaris_animate_view(ctx, state)
	logical_width, logical_height := width / scale, height / scale
	code_face := mono != nil ? mono : face
	ui.begin(ctx, width, height)
	style := ui.default_style
	style.color_top, style.color_bottom = TEMPLATE_SURFACE, TEMPLATE_SURFACE
	style.radius = 0
	ui.style_push(ctx, style)
	content_end := 0
	if state.ready {
		if state.menu == .NONE {
			gitaris_history_ui(ctx, face, title, icons, state, logical_width, logical_height, scale, code_face)
		} else if state.menu == .MERGE {
			gitaris_merge_ui(ctx, face, title, code_face, state, logical_width, logical_height, scale)
		} else if state.menu == .SYNC {
			gitaris_sync_ui(ctx, face, title, state, logical_width, logical_height, scale)
		} else {
			gitaris_settings_ui(ctx, face, title, state, window, logical_width, logical_height, scale)
		}
		content_end = ctx.n_boxes
		gitaris_menu_ui(ctx, face, state, logical_width, scale)
	} else {
		gitaris_welcome_ui(ctx, face, title, welcome, icons, state, window, logical_width, logical_height, scale)
		content_end = ctx.n_boxes
	}
	ui.style_pop(ctx)
	ui.end(ctx)
	ui.fade_elements(ctx, 0, content_end, state.view_enter.value)
}

gitaris_animate_view :: proc(ctx: ^ui.UiContext, state: ^Gitaris) {
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
		}
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
