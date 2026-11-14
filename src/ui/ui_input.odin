package ui

import "core:strings"

Mouse_Button :: enum { LEFT, RIGHT, MIDDLE }
Key :: enum { BACKSPACE, DELETE, RETURN, ESCAPE, LEFT, RIGHT, UP, DOWN, HOME, END, CTRL, SPACE }

UiInput :: struct {
	mouse_down, mouse_pressed, mouse_released: [Mouse_Button]bool,
	key_down, key_pressed, key_released: [Key]bool,
	scroll: [2]f32,
	text: strings.Builder,
}

// Transient events are also cleared by end(); held buttons/keys are preserved.
input_reset :: proc(self: ^UiContext) {
	self.input.mouse_pressed = {}
	self.input.mouse_released = {}
	self.input.key_pressed = {}
	self.input.key_released = {}
	self.input.scroll = {}
	self.delta_mouse = {}
	strings.builder_reset(&self.input.text)
}

input_mouse_move :: proc(self: ^UiContext, x, y: f32) {
	self.mouse_pos = {x, y}
}

input_mouse_delta :: proc(self: ^UiContext, x, y: f32) {
	self.delta_mouse += {x, y}
}

input_mouse_button :: proc(self: ^UiContext, button: Mouse_Button, down: bool, pressed := false, released := false) {
	self.input.mouse_pressed[button] |= pressed || (down && !self.input.mouse_down[button])
	self.input.mouse_released[button] |= released || (!down && self.input.mouse_down[button])
	self.input.mouse_down[button] = down
}

input_key :: proc(self: ^UiContext, key: Key, down: bool, pressed := false, released := false) {
	self.input.key_pressed[key] |= pressed || (down && !self.input.key_down[key])
	self.input.key_released[key] |= released || (!down && self.input.key_down[key])
	self.input.key_down[key] = down
}

input_scroll :: proc(self: ^UiContext, x, y: f32) {
	self.input.scroll += {x, y}
}

input_text :: proc(self: ^UiContext, text: string) {
	strings.write_string(&self.input.text, text)
}

@(private)
interact :: proc(self: ^UiContext, box: ^UiBox) -> UiResult {
	if box.actions == {} do return .NOT_ACTIVE
	box.hovered = clip_rect(box.rect, self.mouse_pos) && clip_rect(box.boundary_rect, self.mouse_pos) &&
		(self.had_elements ? self.hover_id == box.id : !self.pointer_claimed)
	if box.hovered do self.pointer_claimed = true
	pressed := false
	if box.hovered && self.active_id == 0 {
		for button in Mouse_Button {
			clickable := (button == .LEFT && .CLICKABLE in box.actions) ||
				(button == .RIGHT && .RIGHT_CLICKABLE in box.actions)
			if clickable && self.input.mouse_pressed[button] {
				self.active_id = box.id
				self.active_button = button
				if button == .LEFT do self.focus_id = box.id
				pressed = true
				break
			}
		}
	}
	box.focused = self.focus_id == box.id
	if box.focused do self.focus_seen = true
	box.active = self.active_id == box.id
	if box.active {
		self.active_seen = true
		if self.input.mouse_released[self.active_button] {
			box.active = false
			return box.hovered ? .RELEASED : .NOT_ACTIVE
		}
		return pressed ? .PRESSED : .ACTIVE
	}
	return .NOT_ACTIVE
}
