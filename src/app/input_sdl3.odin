package app

// Translates SDL3 events (mouse, keyboard, text input) into UI input.

import SDL "vendor:sdl3"
import "../ui"

// Feed events before ui.begin. SDL positions are window units; UI uses pixels.
input_process_sdl_event :: proc(ctx: ^ui.UiContext, event: ^SDL.Event, scale: f32) {
	#partial switch event.type {
	case .MOUSE_MOTION:
		ui.input_mouse_move(ctx, event.motion.x * scale, event.motion.y * scale)
		ui.input_mouse_delta(ctx, event.motion.xrel * scale, event.motion.yrel * scale)
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		ui.input_mouse_move(ctx, event.button.x * scale, event.button.y * scale)
		switch event.button.button {
		case SDL.BUTTON_LEFT:   ui.input_mouse_button(ctx, .LEFT, event.button.down)
		case SDL.BUTTON_RIGHT:  ui.input_mouse_button(ctx, .RIGHT, event.button.down)
		case SDL.BUTTON_MIDDLE: ui.input_mouse_button(ctx, .MIDDLE, event.button.down)
		}
	case .MOUSE_WHEEL:
		ui.input_mouse_move(ctx, event.wheel.mouse_x * scale, event.wheel.mouse_y * scale)
		direction: f32 = event.wheel.direction == .FLIPPED ? -1 : 1
		ui.input_scroll(ctx, event.wheel.x * direction, event.wheel.y * direction)
	case .TEXT_INPUT:
		ui.input_text(ctx, string(event.text.text))
	case .KEY_DOWN, .KEY_UP:
		if event.key.down && event.key.scancode == .TAB {
			// A document editor takes Tab as text; Shift+Tab still leaves it.
			shift := (event.key.mod & SDL.KMOD_SHIFT) != {}
			if ctx.wants_tab && !shift {
				ui.input_text(ctx, "\t")
			} else {
				input_focus_next(ctx, shift)
			}
		}
		if event.key.down && event.key.scancode == .V && (event.key.mod & SDL.KMOD_CTRL) != {} {
			text := SDL.GetClipboardText()
			if text != nil {
				ui.input_text(ctx, string(cstring(text)))
				SDL.free(text)
			}
		}
		key, mapped := ui_key_from_scancode(event.key.scancode)
		if mapped do ui.input_key(ctx, key, event.key.down, event.key.down)
		ui.input_key(ctx, .CTRL, (event.key.mod & SDL.KMOD_CTRL) != {})
		ui.input_key(ctx, .SHIFT, (event.key.mod & SDL.KMOD_SHIFT) != {})
	case .WINDOW_MOUSE_ENTER:
		x, y: f32
		_ = SDL.GetMouseState(&x, &y)
		ui.input_mouse_move(ctx, x * scale, y * scale)
	case .WINDOW_MOUSE_LEAVE:
		ui.input_mouse_move(ctx, -1, -1)
	case .WINDOW_FOCUS_LOST:
		ui.input_reset(ctx)
		ui.input_mouse_move(ctx, -1, -1)
		ctx.input.mouse_down = {}
		ctx.input.key_down = {}
		ctx.active_id, ctx.focus_id = 0, 0
	}
}

// Traverse the previous frame's visible controls, keeping keyboard focus and
// the text caret consistent with mouse focus. Hidden virtual rows are excluded.
input_focus_next :: proc(ctx: ^ui.UiContext, reverse := false) {
	boxes := ui.elements(ctx)
	// An open dialog keeps focus to itself.
	if workbench_modal_first_box >= 0 && workbench_modal_first_box < len(boxes) do boxes = boxes[workbench_modal_first_box:]
	current := reverse ? 0 : len(boxes) - 1
	for box, i in boxes do if box.id == ctx.focus_id do current = i
	for step in 1..=len(boxes) {
		i := (current + (reverse ? -step : step) + len(boxes)) % len(boxes)
		box := &boxes[i]
		if .CLICKABLE not_in box.actions || box.boundary_rect.width <= 0 || box.boundary_rect.height <= 0 do continue
		ctx.focus_id = box.id
		ctx.caret = len(box.text.buf)
		return
	}
}

@(private)
ui_key_from_scancode :: proc(code: SDL.Scancode) -> (ui.Key, bool) {
	#partial switch code {
	case .BACKSPACE: return .BACKSPACE, true
	case .DELETE:    return .DELETE, true
	case .RETURN, .KP_ENTER: return .RETURN, true
	case .ESCAPE:    return .ESCAPE, true
	case .LEFT:      return .LEFT, true
	case .RIGHT:     return .RIGHT, true
	case .UP:        return .UP, true
	case .DOWN:      return .DOWN, true
	case .HOME:      return .HOME, true
	case .END:       return .END, true
	case .SPACE:     return .SPACE, true
	case .PAGEUP:    return .PAGE_UP, true
	case .PAGEDOWN:  return .PAGE_DOWN, true
	case .A:         return .A, true
	case .C:         return .C, true
	case .X:         return .X, true
	}
	return {}, false
}
