package ui

// Widgets built on boxes: button, label, check box and the text inputs
// (single line, multi-line editor, secret/password box).

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
// Editors support mouse placement and dragging, Shift selection, Ctrl+A/C/X
// (copied text goes to self.clipboard) and Ctrl+V through input_text.
input_box :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect := AUTO_RECT) -> UiResult {
	result, _, _ := edit_box(self, id, value, rect, false)
	return result
}

textbox :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect := AUTO_RECT) -> UiResult {
	result, _, _ := edit_box(self, id, value, rect, true)
	return result
}

// A multiline editor for whole documents. Tab inserts a tab (see wants_tab),
// PageUp/PageDown move by a screen, and the view keeps its position in the
// caller's scroll storage (pixels), which the wheel and the caret update and a
// caller's scrollbar may set. content and view are the text extent and the
// visible text area, both in pixels, for drawing that scrollbar.
text_editor :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect: Rect2d,
	scroll: ^[2]f32) -> (result: UiResult, content, view: [2]f32) {
	assert(scroll != nil)
	return edit_box(self, id, value, rect, true, false, true, scroll)
}

// A one-line editor for passwords: it draws one '*' per character, so the
// text is never shown or copied into the element's cached text or clipboard.
secret_box :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect := AUTO_RECT) -> UiResult {
	result, _, _ := edit_box(self, id, value, rect, false, true)
	return result
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
rune_floor :: proc(text: []u8, cursor: int) -> int {
	i := clamp(cursor, 0, len(text))
	for i > 0 && i < len(text) && !utf8.rune_start(text[i]) do i -= 1
	return i
}

@(private)
count_lines :: proc(text: []u8) -> int {
	n := 0
	for byte in text do if byte == '\n' do n += 1
	return n
}

// Moves by whole lines, keeping the column (in runes) where the line allows.
@(private)
move_lines :: proc(text: []u8, cursor, delta: int) -> int {
	start := line_start(text, cursor)
	column := 0
	for i := start; i < cursor; i = next_rune(text, i) do column += 1
	for _ in 0..<abs(delta) {
		start = line_start(text, delta < 0 ? max(0, start - 1) : min(len(text), line_end(text, start) + 1))
	}
	result := start
	for column > 0 && result < len(text) && text[result] != '\n' {
		result = next_rune(text, result)
		column -= 1
	}
	return result
}

@(private)
box_line_height :: proc(self: ^UiContext, box: ^UiBox) -> f32 {
	if box._line_height <= 0 do box._line_height = measure(self, "M", box.style).y
	return box._line_height
}

// Offset of a position from the text origin: x within its line, y by line.
@(private)
text_offset :: proc(self: ^UiContext, box: ^UiBox, text: []u8, position, line: int, masked: bool) -> [2]f32 {
	before := string(text[line_start(text, position):position])
	if masked do before = strings.repeat("*", utf8.rune_count(before), context.temp_allocator)
	return {measure(self, before, box.style).x, f32(line) * box_line_height(self, box)}
}

// The caret position nearest to a point given relative to the text origin.
@(private)
caret_from_point :: proc(self: ^UiContext, box: ^UiBox, text: []u8, point: [2]f32, multiline: bool) -> int {
	start := 0
	if multiline && point.y > 0 {
		for line := int(point.y / box_line_height(self, box)); line > 0; line -= 1 {
			end := line_end(text, start)
			if end >= len(text) do break
			start = end + 1
		}
	}
	end := line_end(text, start)
	if end > start && text[end - 1] == '\r' do end -= 1
	// Prefix widths only grow, so a binary search keeps very long lines cheap.
	lo, hi := start, end
	for lo < hi {
		mid := (lo + hi + 1) / 2
		for mid > lo && mid < len(text) && !utf8.rune_start(text[mid]) do mid -= 1
		if mid == lo do mid = next_rune(text, lo)
		if measure(self, string(text[start:mid]), box.style).x <= point.x {
			lo = mid
		} else {
			hi = previous_rune(text, mid)
		}
	}
	if lo < end {
		next := next_rune(text, lo)
		left := measure(self, string(text[start:lo]), box.style).x
		right := measure(self, string(text[start:next]), box.style).x
		if point.x - left > right - point.x do lo = next
	}
	return lo
}

// Without caller storage the view follows the caret drawn last frame.
@(private)
caret_view_offset :: proc(box: ^UiBox, view: [2]f32, multiline: bool) -> [2]f32 {
	return {max(0, box._caret_offset.x - view.x), multiline ? max(0, box._caret_offset.y + box.style.font_size - view.y) : 0}
}

// The editable text field behind input_box, textbox, text_editor and
// secret_box. One call per frame: handles the mouse and keyboard while
// focused, keeps the caret in view, and lays out caret and selection.
// `scroll`, when given, stores the scroll position between frames.
@(private)
edit_box :: proc(self: ^UiContext, id: string, value: ^strings.Builder, rect: Rect2d, multiline: bool,
	masked := false, tabs := false, scroll: ^[2]f32 = nil) -> (result: UiResult, content, view: [2]f32) {
	assert(value != nil && id != "" && !(masked && multiline))
	align := multiline ? UiAlignments{.TOP} : UiAlignments{.NONE}
	box := new_box(self, shown_text(value, masked), align, {.HOVERABLE, .CLICKABLE, .EDITABLE}, rect, id)
	pad := max(0, box.style.padding)
	// The visible text area inside the padding.
	view = {max(0, box.rect.width - 2 * pad - 1), max(0, box.rect.height - 2 * pad)}
	if !box.focused && self.edit_id == box.id do self.edit_id = 0
	// Focus that just arrived, or a caret the application moved, starts
	// without a selection and brings the caret into view.
	external := box.focused && (self.edit_id != box.id || self.edit_caret != self.caret)

	// How far the text is scrolled: from the caller's storage (moved by the
	// mouse wheel), or else following the caret.
	offset: [2]f32
	if scroll != nil {
		offset = scroll^
		if self.input.scroll != {} && clip_rect(box.boundary_rect, self.mouse_pos) &&
			(!self.had_elements || self.hover_window == box.window_index) {
			offset -= self.input.scroll * box_line_height(self, box) * 3
			self.input.scroll = {}
		}
	} else if box.focused && self.edit_id == box.id {
		offset = caret_view_offset(box, view, multiline)
	}

	start_caret := self.caret
	if box.focused {
		if external do self.anchor = self.caret
		self.caret = rune_floor(value.buf[:], self.caret)
		self.anchor = rune_floor(value.buf[:], self.anchor)
		start_caret = self.caret
		edit_mouse(self, box, value.buf[:], offset, multiline, masked, external)
		if self.input.key_pressed[.ESCAPE] {
			self.focus_id = 0
			box.focused = false
		} else {
			edit_keys(self, box, value, view, multiline, masked)
			cache_text(self, box, shown_text(value, masked))
			position_text(box)
		}
	}
	if box.focused {
		if tabs do self.wants_tab = true
		if box._caret != self.caret {
			line := count_lines(value.buf[:line_start(value.buf[:], self.caret)])
			box._caret_offset = text_offset(self, box, value.buf[:], self.caret, line, masked)
			box._caret = self.caret
		}
	}

	content = box.text_size + {1, 0}
	if scroll != nil {
		if box.focused && (external || self.caret != start_caret || box.result == .MODIFIED) {
			offset = scroll_to_caret(offset, box._caret_offset, box_line_height(self, box), view)
		}
		offset.x = clamp(offset.x, 0, max(0, content.x - view.x))
		offset.y = clamp(offset.y, 0, max(0, content.y - view.y))
		scroll^ = offset
	} else if box.focused {
		offset = caret_view_offset(box, view, multiline)
	} else {
		offset = {}
	}
	box.scroll_offset = offset
	box.text_pos -= offset

	if box.focused {
		box.caret_rect = {box.text_pos.x + box._caret_offset.x, box.text_pos.y + box._caret_offset.y, 1, box.style.font_size}
		if self.anchor != self.caret do edit_selection_rects(self, box, value.buf[:], masked, pad)
		self.edit_id, self.edit_caret = box.id, self.caret
	}
	highlight(box)
	return box.result, content, view
}

// Pressing places the caret (and starts a new selection, unless Shift is
// held); dragging extends the selection.
@(private)
edit_mouse :: proc(self: ^UiContext, box: ^UiBox, text: []u8, offset: [2]f32, multiline, masked, external: bool) {
	if !(box.active && self.active_button == .LEFT && self.input.mouse_down[.LEFT]) do return
	// Hidden characters have no positions to click; a masked field puts the caret at the end.
	hit := len(text)
	if !masked do hit = caret_from_point(self, box, text, self.mouse_pos - (box.text_pos - offset), multiline)
	if box.result == .PRESSED && (external || !self.input.key_down[.SHIFT]) do self.anchor = hit
	self.caret = hit
}

// Keyboard editing: caret movement and selection, the clipboard, deleting,
// typing and Enter. Sets box.result to MODIFIED or SUBMIT.
@(private)
edit_keys :: proc(self: ^UiContext, box: ^UiBox, value: ^strings.Builder, view: [2]f32, multiline, masked: bool) {
	keys, down := &self.input.key_pressed, &self.input.key_down
	if edit_move_caret(self, box, value.buf[:], view, multiline) && !down[.SHIFT] do self.anchor = self.caret
	if down[.CTRL] && keys[.A] do self.anchor, self.caret = 0, len(value.buf)

	selected := self.anchor != self.caret
	first, last := min(self.anchor, self.caret), max(self.anchor, self.caret)
	// Copying or cutting a hidden password is not allowed.
	cut := down[.CTRL] && keys[.X] && !masked
	if down[.CTRL] && (keys[.C] || cut) && selected && !masked {
		strings.builder_reset(&self.clipboard)
		strings.write_string(&self.clipboard, string(value.buf[first:last]))
		self.clipboard_pending = true
	}

	modified := false
	// Typing, pasting, Enter, Backspace, Delete and cut replace a selection.
	replaces_selection := len(self.input.text.buf) > 0 || keys[.BACKSPACE] || keys[.DELETE] || cut || (multiline && keys[.RETURN])
	if selected && replaces_selection {
		erase_text(value, first, last)
		self.caret = first
		modified = true
	} else {
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
	}
	inserted, newline := insert_input(self, value, multiline)
	modified = modified || inserted
	if keys[.RETURN] && multiline && !newline {
		insert_text(value, &self.caret, []u8{'\n'})
		modified = true
	}
	if modified {
		box.result = .MODIFIED
		self.anchor = self.caret
	}
	if keys[.RETURN] && !multiline do box.result = .SUBMIT
}

// Left/Right, Home/End (Ctrl: whole text) and, when multi-line, Up/Down and
// PageUp/PageDown. Left/Right with a selection and no Shift jump to its
// edge. Returns whether a key moved the caret.
@(private)
edit_move_caret :: proc(self: ^UiContext, box: ^UiBox, text: []u8, view: [2]f32, multiline: bool) -> (moved: bool) {
	keys, down := &self.input.key_pressed, &self.input.key_down
	selected := self.anchor != self.caret
	first, last := min(self.anchor, self.caret), max(self.anchor, self.caret)
	if keys[.LEFT] {
		self.caret = selected && !down[.SHIFT] ? first : previous_rune(text, self.caret)
		moved = true
	}
	if keys[.RIGHT] {
		self.caret = selected && !down[.SHIFT] ? last : next_rune(text, self.caret)
		moved = true
	}
	if keys[.HOME] {
		self.caret = down[.CTRL] ? 0 : line_start(text, self.caret)
		moved = true
	}
	if keys[.END] {
		self.caret = down[.CTRL] ? len(text) : line_end(text, self.caret)
		moved = true
	}
	if !multiline do return
	if keys[.UP] do self.caret = move_lines(text, self.caret, -1)
	if keys[.DOWN] do self.caret = move_lines(text, self.caret, 1)
	if keys[.PAGE_UP] || keys[.PAGE_DOWN] {
		page := max(1, int(view.y / box_line_height(self, box)) - 1)
		self.caret = move_lines(text, self.caret, keys[.PAGE_UP] ? -page : page)
	}
	return moved || keys[.UP] || keys[.DOWN] || keys[.PAGE_UP] || keys[.PAGE_DOWN]
}

// The smallest change to `offset` that shows the caret inside `view`.
@(private)
scroll_to_caret :: proc(offset, caret: [2]f32, line_height: f32, view: [2]f32) -> [2]f32 {
	offset := offset
	if caret.x < offset.x do offset.x = caret.x
	if caret.x + 1 > offset.x + view.x do offset.x = caret.x + 1 - view.x
	if caret.y < offset.y do offset.y = caret.y
	if caret.y + line_height > offset.y + view.y do offset.y = caret.y + line_height - view.y
	return offset
}

// Up to three rectangles covering the selection: the rest of the first line,
// the full lines between, and the start of the last line.
@(private)
edit_selection_rects :: proc(self: ^UiContext, box: ^UiBox, text: []u8, masked: bool, pad: f32) {
	line_height := box_line_height(self, box)
	if box._anchor != self.anchor {
		// Lines between the two ends are counted from the caret's line,
		// so a selection costs its own length, not the document's.
		caret_line := int(box._caret_offset.y / line_height + 0.5)
		between := count_lines(text[min(self.anchor, self.caret):max(self.anchor, self.caret)])
		line := self.anchor < self.caret ? caret_line - between : caret_line + between
		box._anchor_offset = text_offset(self, box, text, self.anchor, line, masked)
		box._anchor = self.anchor
	}
	from, to := box._anchor_offset, box._caret_offset
	if self.anchor > self.caret do from, to = to, from
	origin := box.text_pos
	if from.y == to.y {
		box.selection_rects[0] = {origin.x + from.x, origin.y + from.y, to.x - from.x, line_height}
		return
	}
	right := box.rect.x + box.rect.width - pad
	box.selection_rects[0] = {origin.x + from.x, origin.y + from.y, max(0, right - origin.x - from.x), line_height}
	box.selection_rects[1] = {origin.x, origin.y + from.y + line_height, max(0, right - origin.x), to.y - from.y - line_height}
	box.selection_rects[2] = {origin.x, origin.y + to.y, to.x, line_height}
}
