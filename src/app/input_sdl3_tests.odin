package app

import "core:strings"
import "core:testing"

import "../ui"
import SDL "vendor:sdl3"

@(test)
form_tab_navigation_skips_clipped_controls :: proc(t: ^testing.T) {
	ctx := ui.init()
	defer ui.destroy(ctx)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	strings.write_string(&value, "Ada")
	ui.begin(ctx, 500, 300)
	{
		ui.begin_window(ctx, {0, 0, 500, 300}, "form")
		ui.input_box(ctx, "name", &value, {20, 20, 300, 40})
		ui.button(ctx, "Hidden", {20, 500, 300, 40})
		ui.button(ctx, "Continue", {20, 80, 300, 40})
	}
	ui.end(ctx)
	event: SDL.Event
	event.type = .KEY_DOWN
	event.key.down = true
	event.key.scancode = .TAB
	input_process_sdl_event(ctx, &event, 1)
	name := ctx.focus_id
	testing.expect(t, name == ctx.boxes[1].id && ctx.caret == 3)
	input_process_sdl_event(ctx, &event, 1)
	testing.expect(t, ctx.focus_id == ctx.boxes[3].id)
	input_process_sdl_event(ctx, &event, 1)
	testing.expect(t, ctx.focus_id == name)
	event.key.mod = SDL.KMOD_SHIFT
	input_process_sdl_event(ctx, &event, 1)
	testing.expect(t, ctx.focus_id == ctx.boxes[3].id)
}
