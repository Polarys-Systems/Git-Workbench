package ui

UiCursor :: enum { DEFAULT, POINTER, TEXT, PROGRESS }

// Resolve against this frame's clipped draw order. Decorative labels over a
// button are transparent to hit testing; a later window/background blocks it.
mouse_cursor :: proc(self: ^UiContext) -> UiCursor {
	for i := self.n_boxes - 1; i >= 0; i -= 1 {
		box := &self.boxes[i]
		if !clip_rect(box.rect, self.mouse_pos) || !clip_rect(box.boundary_rect, self.mouse_pos) do continue
		if .EDITABLE in box.actions do return .TEXT
		if .CLICKABLE in box.actions || .RIGHT_CLICKABLE in box.actions do return .POINTER
		if box.actions != {} || box.draw_background do return .DEFAULT
	}
	return .DEFAULT
}
