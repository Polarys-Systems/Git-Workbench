package ui

import "core:strings"
import "core:unicode/utf8"

button :: proc(self: ^UiContext, str: string, rect := AUTO_RECT, align := UiAlignments{.CENTER}, id: string = "") -> UiResult {
	box := new_box(self, str, align, {.HOVERABLE, .CLICKABLE}, rect, id)
	if box.result == .RELEASED || (box.focused && (self.input.key_pressed[.RETURN] || self.input.key_pressed[.SPACE])) {
		box.result = .SUBMIT
	}
	highlight(box)
	return box.result
}

label :: proc(self: ^UiContext, str: string, rect := AUTO_RECT, align := UiAlignments{.NONE}) -> ^UiBox {
	box := new_box(self, str, align, {}, rect)
	box.draw_background = false
	return box
}

// This is only a bounding rectangle. The renderer evaluates the line inside it,
// so diagonal edges and round caps need no extra UI geometry or hit targets.
line :: proc(self: ^UiContext, start, end: [2]f32, width: f32, color: [4]f32) -> ^UiBox {
	if width <= 0 do return nil
	pad := width * 0.5 + 1
	// Negative UI coordinates mean automatic layout. Clip the bounding box to
	// the screen first, keeping the original endpoints for the distance field.
	lo := [2]f32{max(self.screen.x, min(start.x, end.x) - pad), max(self.screen.y, min(start.y, end.y) - pad)}
	hi := [2]f32{min(self.screen.x + self.screen.width, max(start.x, end.x) + pad), min(self.screen.y + self.screen.height, max(start.y, end.y) + pad)}
	if hi.x <= lo.x || hi.y <= lo.y do return nil
	box := new_box(self, "", {}, {}, {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y})
	box.draw_background = false
	box.line_start, box.line_end, box.line_width = start, end, width
	box.style.text_color = color
	return box
}

check :: proc(self: ^UiContext, str: string, value: ^bool, rect := AUTO_RECT, id: string = "") -> UiResult {
	assert(value != nil)
	box := new_box(self, str, {.NONE}, {.HOVERABLE, .CLICKABLE}, rect, id)
	if box.result == .RELEASED || (box.focused && self.input.key_pressed[.SPACE]) {
		value^ = !value^
		box.result = .MODIFIED
	}
	box.icon = value^ ? .CHECK : .CHECK_UNCHECKED
	size := max(0, min(box.style.font_size, min(box.rect.width, box.rect.height) - 2 * box.style.padding))
	box.icon_rect = {box.rect.x + box.style.padding, box.rect.y + (box.rect.height - size) * 0.5, size, size}
	position_text(box)
	highlight(box)
	return box.result
}

// The caller owns the UTF-8 builder. IDs must be unique within a window.
input_box :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect := AUTO_RECT) -> UiResult {
	return edit_box(self, id, value, rect, false)
}

textbox :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect := AUTO_RECT) -> UiResult {
	return edit_box(self, id, value, rect, true)
}

// A one-line editor for passwords: it draws one '*' per character, so the
// text is never shown or copied into the element's cached text.
secret_box :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect := AUTO_RECT) -> UiResult {
	return edit_box(self, id, value, rect, false, true)
}

@(private)
shown_text :: proc(value: ^strings.Builder, masked: bool) -> string {
	if !masked do return strings.to_string(value^)
	return strings.repeat("*", utf8.rune_count(value.buf[:]), context.temp_allocator)
}

@(private)
highlight :: proc(box: ^UiBox) {
	color := box.active ? box.style.active_color : box.style.hover_color
	if (box.active || box.hovered) && color.a > 0 {
		box.style.color_top, box.style.color_bottom = color, color
		return
	}
	factor: f32 = box.active ? 0.8 : (box.hovered ? 1.15 : 1.0)
	for i in 0..<3 {
		box.style.color_top[i] = min(1, box.style.color_top[i] * factor)
		box.style.color_bottom[i] = min(1, box.style.color_bottom[i] * factor)
	}
}

@(private)
previous_rune :: proc(text: []u8, cursor: int) -> int {
	i := max(0, cursor - 1)
	for i > 0 && !utf8.rune_start(text[i]) do i -= 1
	return i
}

@(private)
next_rune :: proc(text: []u8, cursor: int) -> int {
	if cursor >= len(text) do return len(text)
	_, size := utf8.decode_rune(text[cursor:])
	return min(len(text), cursor + max(1, size))
}

@(private)
line_start :: proc(text: []u8, cursor: int) -> int {
	i := cursor
	for i > 0 && text[i - 1] != '\n' do i -= 1
	return i
}

@(private)
line_end :: proc(text: []u8, cursor: int) -> int {
	i := cursor
	for i < len(text) && text[i] != '\n' do i += 1
	return i
}

@(private)
erase_text :: proc(value: ^strings.Builder, first, last: int) {
	copy(value.buf[first:], value.buf[last:])
	resize(&value.buf, len(value.buf) - (last - first))
}

@(private)
insert_text :: proc(value: ^strings.Builder, cursor: ^int, text: []u8) {
	old_len := len(value.buf)
	resize(&value.buf, old_len + len(text))
	copy(value.buf[cursor^ + len(text):], value.buf[cursor^:old_len])
	copy(value.buf[cursor^:], text)
	cursor^ += len(text)
}

@(private)
insert_input :: proc(self: ^UiContext, value: ^strings.Builder, multiline: bool) -> (modified, newline: bool) {
	// Filter in the reusable event buffer, then move the editor's tail only once.
	text := self.input.text.buf[:]
	n := 0
	for i := 0; i < len(text); i += 1 {
		byte := text[i]
		if byte == '\r' && multiline {
			byte = '\n'
			if i + 1 < len(text) && text[i + 1] == '\n' do i += 1
		}
		if (byte < 32 || byte == 127) && !(multiline && (byte == '\n' || byte == '\t')) do continue
		text[n] = byte
		n += 1
		newline = newline || byte == '\n'
	}
	if n > 0 do insert_text(value, &self.caret, text[:n])
	return n > 0, newline
}

@(private)
edit_box :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect: Rect2d, multiline: bool, masked := false) -> UiResult {
	assert(value != nil && id != "" && !(masked && multiline))
	align := multiline ? UiAlignments{.TOP} : UiAlignments{.NONE}
	box := new_box(self, shown_text(value, masked), align, {.HOVERABLE, .CLICKABLE, .EDITABLE}, rect, id)
	if box.focused {
		if box.hovered && self.input.mouse_pressed[.LEFT] do self.caret = len(value.buf)
		self.caret = clamp(self.caret, 0, len(value.buf))
		for self.caret > 0 && self.caret < len(value.buf) && !utf8.rune_start(value.buf[self.caret]) do self.caret -= 1
		keys := &self.input.key_pressed
		if keys[.ESCAPE] {
			self.focus_id = 0
			box.focused = false
		} else {
			if keys[.LEFT] do self.caret = previous_rune(value.buf[:], self.caret)
			if keys[.RIGHT] do self.caret = next_rune(value.buf[:], self.caret)
			if keys[.HOME] do self.caret = self.input.key_down[.CTRL] ? 0 : line_start(value.buf[:], self.caret)
			if keys[.END] do self.caret = self.input.key_down[.CTRL] ? len(value.buf) : line_end(value.buf[:], self.caret)
			if multiline && (keys[.UP] || keys[.DOWN]) {
				start := line_start(value.buf[:], self.caret)
				column := 0
				for i := start; i < self.caret; i = next_rune(value.buf[:], i) do column += 1
				target := keys[.UP] ? max(0, start - 1) : min(len(value.buf), line_end(value.buf[:], self.caret) + 1)
				self.caret = line_start(value.buf[:], target)
				for column > 0 && self.caret < len(value.buf) && value.buf[self.caret] != '\n' {
					self.caret = next_rune(value.buf[:], self.caret)
					column -= 1
				}
			}
			modified := false
			if keys[.BACKSPACE] && self.caret > 0 {
				start := previous_rune(value.buf[:], self.caret)
				erase_text(value, start, self.caret)
				self.caret = start
				modified = true
			}
			if keys[.DELETE] && self.caret < len(value.buf) {
				erase_text(value, self.caret, next_rune(value.buf[:], self.caret))
				modified = true
			}
			inserted, newline := insert_input(self, value, multiline)
			modified = modified || inserted
			if keys[.RETURN] && multiline && !newline {
				insert_text(value, &self.caret, []u8{'\n'})
				modified = true
			}
			if modified do box.result = .MODIFIED
			if keys[.RETURN] && !multiline do box.result = .SUBMIT
			cache_text(self, box, shown_text(value, masked))
			position_text(box)
		}
	}
	if box.focused {
		if box._caret != self.caret {
			start := line_start(value.buf[:], self.caret)
			line: int
			for byte in value.buf[:start] do if byte == '\n' do line += 1
			line_height := measure(self, "M", box.style).y
			before := string(value.buf[start:self.caret])
			if masked do before = strings.repeat("*", utf8.rune_count(before), context.temp_allocator)
			box._caret_offset = {measure(self, before, box.style).x, f32(line) * line_height}
			box._caret = self.caret
		}
		// Keep the caret visible; offsets are derived from cached text metrics.
		inner_width := max(0, box.rect.width - 2 * box.style.padding - 1)
		inner_height := max(0, box.rect.height - 2 * box.style.padding)
		box.scroll_offset.x = max(0, box._caret_offset.x - inner_width)
		if multiline do box.scroll_offset.y = max(0, box._caret_offset.y + box.style.font_size - inner_height)
		box.text_pos -= box.scroll_offset
		box.caret_rect = {box.text_pos.x + box._caret_offset.x, box.text_pos.y + box._caret_offset.y, 1, box.style.font_size}
	}
	highlight(box)
	return box.result
}
