package ui

import "core:strings"
import "core:testing"

@(private)
motion_test_frame :: proc(ctx: ^UiContext, id := "action") -> UiResult {
	begin(ctx, 400, 300)
	style := default_style
	style.color_top, style.color_bottom = {0, 0, 0, 1}, {0, 0, 0, 1}
	style.hover_color, style.active_color = {1, 1, 1, 1}, {0.2, 0.2, 0.2, 1}
	style.border_color, style.focus_color = {0, 0, 0, 1}, {0, 1, 0, 1}
	style.border = 1
	style_push(ctx, style)
	result := button(ctx, "Action", {20, 20, 100, 40}, id = id)
	style_pop(ctx)
	end(ctx)
	return result
}

@(test)
motion_retargets_without_delaying_clicks :: proc(t: ^testing.T) {
	ctx := init()
	defer destroy(ctx)
	set_delta_time(ctx, 0.02)
	motion_test_frame(ctx)
	input_mouse_move(ctx, 30, 30)
	motion_test_frame(ctx)
	first := elements(ctx)[0].style.color_top.r
	testing.expect(t, first > 0 && first < 1)
	motion_test_frame(ctx)
	second := elements(ctx)[0].style.color_top.r
	testing.expect(t, second > first && second < 1)
	input_mouse_move(ctx, 200, 200)
	motion_test_frame(ctx)
	reversed := elements(ctx)[0].style.color_top.r
	testing.expect(t, reversed > 0 && reversed < second)
	for _ in 0..<10 do motion_test_frame(ctx)
	testing.expect(t, elements(ctx)[0].style.color_top.r == 0)
	input_mouse_move(ctx, 30, 30)
	input_mouse_button(ctx, .LEFT, true)
	testing.expect(t, motion_test_frame(ctx) == .PRESSED)
	outline := elements(ctx)[0].style.focus_color.g
	testing.expect(t, outline > 0 && outline < 1)
	input_mouse_button(ctx, .LEFT, false)
	testing.expect(t, motion_test_frame(ctx) == .SUBMIT)
	set_animations_enabled(ctx, false)
	motion_test_frame(ctx)
	testing.expect(t, elements(ctx)[0].style.color_top.r == 1)
	testing.expect(t, elements(ctx)[0].style.focus_color.g == 1)
}

@(test)
motion_recycled_rows_and_fades_do_not_leak :: proc(t: ^testing.T) {
	ctx := init()
	defer destroy(ctx)
	set_delta_time(ctx, 0.02)
	motion_test_frame(ctx)
	input_mouse_move(ctx, 30, 30)
	motion_test_frame(ctx)
	input_mouse_move(ctx, 200, 200)
	motion_test_frame(ctx, "another-row")
	testing.expect(t, elements(ctx)[0].style.color_top.r == 0)
	rect := elements(ctx)[0].rect
	fade_elements(ctx, 0, ctx.n_boxes, 0.25)
	testing.expect(t, elements(ctx)[0].style.color_top.a == 0.25)
	testing.expect(t, elements(ctx)[0].rect == rect)
	motion_test_frame(ctx, "another-row")
	testing.expect(t, elements(ctx)[0].style.color_top.a == 1)
	input_mouse_move(ctx, 30, 30)
	motion_test_frame(ctx, "another-row")
	begin(ctx, 400, 300)
	end(ctx)
	input_mouse_move(ctx, 200, 200)
	motion_test_frame(ctx, "another-row")
	testing.expect(t, elements(ctx)[0].style.color_top.r == 0)
}

@(test)
cursor_respects_clipping_decorations_and_topmost_windows :: proc(t: ^testing.T) {
	ctx := init()
	defer destroy(ctx)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	scales := [?]f32{1, 2}
	for scale in scales {
		begin(ctx, 400 * scale, 300 * scale)
		{
			begin_window(ctx, {0, 0, 200 * scale, 200 * scale}, "controls")
			button(ctx, "", {20 * scale, 20 * scale, 100 * scale, 40 * scale}, id = "row")
			label(ctx, "Row label", {20 * scale, 20 * scale, 100 * scale, 40 * scale})
			input_box(ctx, "edit", &value, {20 * scale, 80 * scale, 100 * scale, 40 * scale})
			button(ctx, "Clipped", {210 * scale, 20 * scale, 100 * scale, 40 * scale})
		}
		{
			begin_window(ctx, {90 * scale, 20 * scale, 30 * scale, 40 * scale}, "cover")
		}
		end(ctx)
		input_mouse_move(ctx, 30 * scale, 30 * scale)
		testing.expect(t, mouse_cursor(ctx) == .POINTER)
		input_mouse_move(ctx, 100 * scale, 30 * scale)
		testing.expect(t, mouse_cursor(ctx) == .DEFAULT)
		input_mouse_move(ctx, 30 * scale, 90 * scale)
		testing.expect(t, mouse_cursor(ctx) == .TEXT)
		ctx.focus_id = elements(ctx)[3].id
		input_mouse_move(ctx, 230 * scale, 30 * scale)
		testing.expect(t, mouse_cursor(ctx) == .DEFAULT)
		input_mouse_move(ctx, -1, -1)
		testing.expect(t, mouse_cursor(ctx) == .DEFAULT)
	}
}
