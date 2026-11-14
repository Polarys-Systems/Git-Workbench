package ui

import "core:strings"

AUTO_RECT :: Rect2d{-1, -1, -1, -1}

make_id :: proc(text: string, seed: UiId = 0) -> UiId {
	hash := u64(14695981039346656037) ~ u64(seed)
	for byte in transmute([]u8)text do hash = (hash ~ u64(byte)) * 1099511628211
	return UiId(hash == 0 ? 1 : hash)
}

@(private)
allocate_box :: proc(self: ^UiContext) -> ^UiBox {
	assert(self.in_frame && self.n_boxes < MAX_BOXES)
	box := &self.boxes[self.n_boxes]
	if self.n_boxes == self.used_boxes {
		box.text = strings.builder_make(self.allocator)
		self.used_boxes += 1
	}
	box^ = UiBox{
		text = box.text, text_size = box.text_size,
		_measured = box._measured, _font = box._font, _font_size = box._font_size,
		_caret = box._caret, _caret_offset = box._caret_offset,
		_animation = box._animation,
		style = self.styles[self.n_styles], window_index = self.window_index,
		zindex = i32(self.n_boxes),
	}
	self.n_boxes += 1
	return box
}

@(private)
measure :: proc(self: ^UiContext, text: string, style: UiStyle) -> [2]f32 {
	if self.measure_text != nil do return self.measure_text(style.font_id, text, style.font_size)
	// Monospace fallback. Supply real font metrics through init/set_text_measure.
	size := [2]f32{0, style.font_size}
	x: f32
	for r in text {
		if r == '\n' {
			size.x = max(size.x, x)
			x = 0
			size.y += style.font_size
		} else {
			x += style.font_size * 0.5
		}
	}
	size.x = max(size.x, x)
	return size
}

@(private)
cache_text :: proc(self: ^UiContext, box: ^UiBox, text: string) {
	if strings.to_string(box.text) != text {
		strings.builder_reset(&box.text)
		strings.write_string(&box.text, text)
		box._measured = false
	}
	if !box._measured || box._font != box.style.font_id || box._font_size != box.style.font_size {
		box.text_size = measure(self, text, box.style)
		box._font = box.style.font_id
		box._font_size = box.style.font_size
		box._measured = true
		box._caret = -1
	}
}

@(private)
position_text :: proc(box: ^UiBox) {
	pad := max(0, box.style.padding)
	left := box.rect.x + pad
	if box.icon != .NONE do left += box.icon_rect.width + pad
	width := max(0, box.rect.x + box.rect.width - pad - left)
	box.text_pos = {left, box.rect.y + (box.rect.height - box.text_size.y) * 0.5}
	if .RIGHT in box.alignment {
		box.text_pos.x += width - box.text_size.x
	} else if .CENTER in box.alignment {
		box.text_pos.x += (width - box.text_size.x) * 0.5
	}
	if .TOP in box.alignment {
		box.text_pos.y = box.rect.y + pad
	} else if .BOTTOM in box.alignment {
		box.text_pos.y = box.rect.y + box.rect.height - pad - box.text_size.y
	}
}

@(private)
layout_clip :: proc(self: ^UiContext) -> Rect2d {
	clip := self.screen
	// Intersect the small layout stack; nested layouts cannot escape their parent.
	for layout in self.layouts[:self.n_layouts + 1] do clip = rect_intersection(clip, layout.rect)
	return clip
}

@(private)
layout_next :: proc(self: ^UiContext, requested: Rect2d) -> Rect2d {
	layout := &self.layouts[self.n_layouts]
	rect := requested
	cell_width := layout.column_width >= 0 ? layout.column_width : layout.box_size.x
	if rect.width < 0 do rect.width = max(0, cell_width)
	if rect.height < 0 do rect.height = max(0, layout.box_size.y)
	if requested.x >= 0 && requested.y >= 0 do return rect
	if rect.x < 0 {
		rect.x = layout.content.x
		if .RIGHT in layout.alignment {
			rect.x += cell_width - rect.width
		} else if .CENTER in layout.alignment {
			rect.x += (cell_width - rect.width) * 0.5
		}
	}
	if rect.y < 0 {
		rect.y = layout.content.y
		if .BOTTOM in layout.alignment do rect.y += max(0, layout.box_size.y - rect.height)
	}
	layout.scrollable_content.x = max(layout.scrollable_content.x, rect.x + rect.width - layout.rect.x + layout.margin)
	layout.scrollable_content.y = max(layout.scrollable_content.y, rect.y + rect.height - layout.rect.y + layout.margin)
	layout._row_height = max(layout._row_height, rect.height)
	layout._column += 1
	if layout._column == layout._columns {
		layout.content.x = layout.rect.x + layout.margin
		layout.content.y += layout._row_height + layout.margin
		layout._column = 0
		layout._row_height = 0
	} else {
		layout.content.x += cell_width + layout.margin
	}
	if requested.x < 0 do rect.x -= layout.scroll_offset.x
	if requested.y < 0 do rect.y -= layout.scroll_offset.y
	return rect
}

// Borrowed, contiguous draw-order data, valid until the next begin()/destroy().
// Read only: mutating elements would invalidate the input/measurement caches.
elements :: proc(self: ^UiContext) -> []UiBox {
	return self.boxes[:self.n_boxes]
}

// Start cursor at zero. Returns nil at the end and skips fully clipped elements.
next_element :: proc(self: ^UiContext, cursor: ^int) -> ^UiBox {
	assert(cursor^ >= 0)
	for cursor^ < self.n_boxes {
		box := &self.boxes[cursor^]
		cursor^ += 1
		if box.boundary_rect.width > 0 && box.boundary_rect.height > 0 do return box
	}
	return nil
}
