package app

import "core:strings"

import "../font"
import "../ui"

// A single white atlas texel lets solid/gradient rectangles share the text batch.
draw_rect :: proc(batch: ^Text_Batch, rect: ui.Rect2d, top, bottom: [4]f32) -> bool {
	if rect.width <= 0 || rect.height <= 0 do return true
	if !batch.white_cached {
		placement, fits := atlas_find_space(batch, 3, 3)
		if !fits do return false
		bitmap := font.Glyph_Bitmap{width = 1, height = 1, pixels = []u8{255}}
		if !queue_glyph_upload(batch, &bitmap, placement.rect) do return false
		batch.white_uv = {
			(f32(placement.rect.offset.x) + 1.5) / f32(batch.atlas_width),
			(f32(placement.rect.offset.y) + 1.5) / f32(batch.atlas_height),
		}
		batch.atlas_cursor_x = placement.cursor_x
		batch.atlas_cursor_y = placement.cursor_y
		batch.atlas_row_bottom = placement.row_bottom
		batch.white_cached = true
	}
	return append_draw_quad(batch, {rect.x, rect.y}, {rect.x + rect.width, rect.y + rect.height},
		batch.white_uv, batch.white_uv, top, bottom)
}

draw_line :: proc(batch: ^Text_Batch, start, end: [2]f32, width: f32, color: [4]f32) -> bool {
	if width <= 0 do return true
	radius := width * 0.5
	// Leave one physical pixel for the antialias fringe. CPU clipping changes
	// only this quad, never the endpoints, so scrolling cannot move the caps.
	pad := radius + 1
	lo := [2]f32{min(start.x, end.x) - pad, min(start.y, end.y) - pad}
	hi := [2]f32{max(start.x, end.x) + pad, max(start.y, end.y) + pad}
	// Atlas UVs are nonnegative. A negative U selects the analytic line path
	// in the same shader/batch, avoiding a pipeline switch or draw per segment.
	uv := [2]f32{-radius, 0}
	return append_draw_quad(batch, lo, hi, uv, uv, color, color, {start.x, start.y, end.x, end.y})
}

// Font handles in this application are borrowed Face pointers.
ui_measure_text :: proc(id: ui.UiFont, text: string, size: f32) -> [2]f32 {
	face := (^font.Face)(uintptr(id))
	size_64 := u32(max(1, size * 64))
	height := font.line_metrics(face, size_64).line_height
	extent := [2]f32{0, height}
	x: f32
	for r in text {
		if r == '\r' do continue
		if r == '\n' {
			extent.x = max(extent.x, x)
			extent.y += height
			x = 0
			continue
		}
		glyph, found := font.glyph_index(face, r)
		if !found do glyph, found = font.glyph_index(face, '?')
		if found {
			advance, _ := font.glyph_advance(face, glyph, size_64)
			x += advance
		}
	}
	extent.x = max(extent.x, x)
	return extent
}

draw_ui :: proc(batch: ^Text_Batch, ctx: ^ui.UiContext) -> (ok: bool) {
	first := len(batch.vertices)
	old_clip, old_min, old_max := batch.clip_enabled, batch.clip_min, batch.clip_max
	defer {
		batch.clip_enabled, batch.clip_min, batch.clip_max = old_clip, old_min, old_max
		if !ok do resize(&batch.vertices, first)
	}
	batch.clip_enabled = true
	cursor := 0
	for box := ui.next_element(ctx, &cursor); box != nil; box = ui.next_element(ctx, &cursor) {
		batch.clip_min = {box.boundary_rect.x, box.boundary_rect.y}
		batch.clip_max = batch.clip_min + {box.boundary_rect.width, box.boundary_rect.height}
		if box.line_width > 0 {
			if !draw_line(batch, box.line_start, box.line_end, box.line_width, box.style.text_color) do return false
			continue
		}
		if box.draw_background {
			r := box.rect
			border := min(max(box.style.border, box.focused ? f32(1) : 0), min(r.width, r.height) * 0.5)
			if border > 0 {
				color := box.focused ? box.style.focus_color : box.style.border_color
				if !draw_rect(batch, r, color, color) do return false
				r = {r.x + border, r.y + border, r.width - 2 * border, r.height - 2 * border}
			}
			if !draw_rect(batch, r, box.style.color_top, box.style.color_bottom) do return false
		}
		if box.icon == .CHECK || box.icon == .CHECK_UNCHECKED {
			r := box.icon_rect
			color := box.style.text_color
			if !draw_rect(batch, r, color, color) do return false
			r = {r.x + 2, r.y + 2, r.width - 4, r.height - 4}
			color = box.icon == .CHECK ? box.style.focus_color : box.style.color_top
			if !draw_rect(batch, r, color, color) do return false
		}
		if len(box.text.buf) > 0 {
			face := (^font.Face)(uintptr(box.style.font_id))
			if !draw_text(batch, face, strings.to_string(box.text), box.text_pos, box.style.text_color, box.style.font_size) do return false
		}
		if box.caret_rect.width > 0 {
			if !draw_rect(batch, box.caret_rect, box.style.text_color, box.style.text_color) do return false
		}
	}
	return true
}
