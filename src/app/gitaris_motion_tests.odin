package app

import "core:strings"
import "core:testing"
import "../ui"

@(test)
view_entrances_settle_and_keep_navigation_opaque :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := ui.init()
	defer ui.destroy(ctx)
	state: Gitaris
	defer gitaris_destroy(&state)
	ui.set_delta_time(ctx, 0.016)
	gitaris_test_frame(ctx, &state, 1)
	testing.expect(t, state.view_enter.value > 0 && state.view_enter.value < 1)
	for _ in 0..<20 do gitaris_test_frame(ctx, &state, 1)
	testing.expect(t, ui.anim_float_settled(&state.view_enter) && state.view_enter.value == 1)
	state.ready, state.menu = true, .PREFERENCES
	gitaris_test_frame(ctx, &state, 2)
	testing.expect(t, state.view_enter.value > 0 && state.view_enter.value < 1)
	fields, menus := 0, 0
	for box in ui.elements(ctx) {
		if .EDITABLE in box.actions {
			fields += 1
			testing.expect(t, box.style.color_top.a > 0 && box.style.color_top.a < 1)
			ui.input_mouse_move(ctx, box.rect.x + 10, box.rect.y + 10)
			testing.expect(t, ui.mouse_cursor(ctx) == .TEXT)
		}
		if strings.to_string(box.text) == "Project" && .CLICKABLE in box.actions {
			menus += 1
			testing.expect(t, box.style.color_top.a == 1)
		}
	}
	testing.expect(t, fields == 3 && menus == 1)
	ui.set_animations_enabled(ctx, false)
	gitaris_test_frame(ctx, &state, 2)
	testing.expect(t, state.view_enter.value == 1 && !state.view_enter.active)
	for box in ui.elements(ctx) {
		if .EDITABLE in box.actions do testing.expect(t, box.style.color_top.a == 1)
	}
}
