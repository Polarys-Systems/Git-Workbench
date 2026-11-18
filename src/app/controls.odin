package app

// Reusable controls shared by every view: buttons, list rows, checkboxes,
// text fields, messages, and scroll areas with draggable scrollbars.

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../ui"

workbench_control_style :: proc(face: ^font_core.Face, scale: f32, primary := false) -> ui.UiStyle {
	style := ui.default_style
	style.font_id = ui.UiFont(uintptr(face))
	style.font_size = 13 * scale
	style.padding = 10 * scale
	// Buttons are pills: the renderer clamps the radius to half the height.
	style.radius = 999 * scale
	style.border = 0
	style.border_color = THEME_LINE
	style.focus_color = THEME_ACCENT
	style.text_color = primary ? THEME_LIGHT : THEME_TEXT
	style.color_top = primary ? THEME_ACCENT : THEME_BUTTON
	style.color_bottom = style.color_top
	style.hover_color = primary ? [4]f32{0.32, 0.32, 0.31, 1} : [4]f32{0.87, 0.87, 0.85, 1}
	style.active_color = primary ? THEME_DARK : [4]f32{0.83, 0.83, 0.81, 1}
	return style
}

// Text fields: light, gently rounded, with a hairline border.
workbench_field_style :: proc(face: ^font_core.Face, scale: f32) -> ui.UiStyle {
	style := workbench_control_style(face, scale)
	style.radius = 10 * scale
	style.border = scale
	style.color_top, style.color_bottom = THEME_LIGHT, THEME_LIGHT
	style.hover_color, style.active_color = THEME_LIGHT, THEME_LIGHT
	return style
}

workbench_button :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string,
	rect: ui.Rect2d, scale: f32, primary := false, id := "") -> bool {
	ui.style_push(ctx, workbench_control_style(face, scale, primary))
	result := ui.button(ctx, text, theme_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

workbench_row_button :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, id: string,
	rect: ui.Rect2d, selected: bool, scale: f32) -> bool {
	style := workbench_control_style(face, scale)
	style.radius = 10 * scale
	style.color_top = selected ? THEME_SELECTED : THEME_CARD
	style.color_bottom = style.color_top
	style.hover_color = selected ? THEME_SELECTED : THEME_HOVER
	style.active_color = THEME_SELECTED
	style.border = 0
	ui.style_push(ctx, style)
	result := ui.button(ctx, "", theme_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

// A square checkbox without a label. Drawn after a row button, it receives the
// click itself (topmost hit testing), so checking never selects the row.
workbench_check :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, id: string, value: ^bool,
	rect: ui.Rect2d, scale: f32) -> bool {
	style := workbench_control_style(face, scale)
	style.padding = 4 * scale
	style.radius = 5 * scale
	style.color_top, style.color_bottom = THEME_LIGHT, THEME_LIGHT
	style.text_color = THEME_MUTED // Frame of the check square.
	ui.style_push(ctx, style)
	result := ui.check(ctx, "", value, theme_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .MODIFIED
}

workbench_field :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, id, label, placeholder: string,
	value: ^strings.Builder, rect: ui.Rect2d, scale: f32, secret := false) -> ui.UiResult {
	if label != "" do theme_label(ctx, face, label, {rect.x, rect.y - 22, rect.width, 18}, 12, THEME_MUTED, scale)
	ui.style_push(ctx, workbench_field_style(face, scale))
	result := secret ? ui.secret_box(ctx, id, value, theme_rect(rect, scale)) : ui.input_box(ctx, id, value, theme_rect(rect, scale))
	ui.style_pop(ctx)
	if len(value.buf) == 0 {
		theme_label(ctx, face, placeholder, {rect.x + 11, rect.y, rect.width - 22, rect.height}, 13, THEME_MUTED, scale)
	}
	return result
}

workbench_message :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, rect: ui.Rect2d, scale: f32,
	color := THEME_ERROR_TEXT) {
	// Use the same font metrics as the renderer, including non-ASCII paths.
	remaining := text
	y := rect.y
	for remaining != "" && y + 16 <= rect.y + rect.height {
		end, last_space := 0, 0
		for _, offset in remaining {
			if offset == 0 do continue
			if remaining[offset] == ' ' do last_space = offset
			width := ctx.measure_text != nil ? ctx.measure_text(ui.UiFont(uintptr(face)), remaining[:offset], 12 * scale).x / scale : f32(offset) * 6
			if width > rect.width {
				end = last_space > 0 ? last_space : offset
				break
			}
		}
		if end == 0 do end = len(remaining)
		theme_label(ctx, face, remaining[:end], {rect.x, y, rect.width, 16}, 12, color, scale)
		remaining = strings.trim_space(remaining[end:])
		y += 17
	}
}

// Virtual rows keep large repositories within the immediate UI's element budget.
workbench_scroll_begin :: proc(ctx: ^ui.UiContext, viewport: ui.Rect2d, count: int, row_height, scale: f32,
	content_width: f32 = 0) -> (first, last: int, offset: f32) {
	layout := ui.default_layout
	layout.rect = theme_rect(viewport, scale)
	layout.margin = 0
	layout.box_size = {viewport.width * scale, row_height * scale}
	ui.layout_push(ctx, layout)
	width := max(viewport.width, content_width)
	ctx.windows[ctx.window_index].content_size = {width * scale, f32(count) * row_height * scale}
	ui.layout_begin_scroll(ctx, content_width > 0)
	current := &ctx.layouts[ctx.n_layouts]
	current.scrollable_content = {width * scale, f32(count) * row_height * scale}
	offset = current.scroll_offset.y / scale
	first = min(count, int(offset / row_height))
	last = min(count, first + int(viewport.height / row_height) + 2)
	return
}

workbench_scroll_end :: proc(ctx: ^ui.UiContext, viewport: ui.Rect2d, scale: f32, horizontal := false) {
	ui.layout_end_scroll(ctx, horizontal)
	ui.layout_pop(ctx)
	window := &ctx.windows[ctx.window_index]
	// The bars keep their old place: 3px inside the right edge, and just below
	// the viewport. Their tracks are wider than the bars to be easy to grab.
	workbench_scrollbar(ctx, fmt.tprintf("scroll-y-%v-%v", viewport.x, viewport.y),
		{viewport.x + viewport.width - 10, viewport.y, 10, viewport.height},
		viewport.height * scale, window.content_size.y, &window.scroll_offset.y, true, scale)
	if horizontal {
		workbench_scrollbar(ctx, fmt.tprintf("scroll-x-%v-%v", viewport.x, viewport.y),
			{viewport.x, viewport.y + viewport.height, viewport.width, 6},
			viewport.width * scale, window.content_size.x, &window.scroll_offset.x, false, scale)
	}
}

// Where the pointer held the thumb, so dragging does not make it jump.
@(private = "file")
workbench_scroll_grab: f32

// A scrollbar whose thumb can be dragged; pressing the track elsewhere centers
// the thumb there and keeps dragging. The bar is drawn along the far (right or
// bottom) edge of track, in logical units; view, content and offset are pixels.
// keep_focus hands keyboard focus back to an editor after a press.
workbench_scrollbar :: proc(ctx: ^ui.UiContext, id: string, track: ui.Rect2d, view, content: f32,
	offset: ^f32, vertical: bool, scale: f32, keep_focus: ui.UiId = 0) {
	if content <= view || view <= 0 do return
	length := vertical ? track.height : track.width
	thumb := min(length, max(22, length * view / content))
	travel := max(1, length - thumb)
	range := content - view
	// Hover and drag state from the previous frame decide the drawn thickness;
	// the invisible hit box must be the topmost element over the track.
	box_id := ui.make_id(id, ctx.window_index >= 0 ? ctx.windows[ctx.window_index].id : 0)
	engaged := ctx.hover_id == box_id || ctx.active_id == box_id
	size: f32 = engaged ? 6 : 3
	start := clamp(offset^ / range, 0, 1) * travel
	bar := vertical ? ui.Rect2d{track.x + track.width - size, track.y + start, size, thumb} :
		ui.Rect2d{track.x + start, track.y + track.height - size, thumb, size}
	theme_box(ctx, bar, engaged ? THEME_TEXT : THEME_MUTED, size * 0.5, scale)
	box := ui.new_box(ctx, "", {}, {.HOVERABLE, .CLICKABLE}, theme_rect(track, scale), id)
	box.draw_background = false
	if box.result == .PRESSED {
		if keep_focus != 0 do ctx.focus_id = keep_focus
		position := (vertical ? ctx.mouse_pos.y : ctx.mouse_pos.x) / scale - (vertical ? track.y : track.x)
		workbench_scroll_grab = position >= start && position <= start + thumb ? position - start : thumb * 0.5
	}
	if box.active && ctx.input.mouse_down[.LEFT] {
		position := (vertical ? ctx.mouse_pos.y : ctx.mouse_pos.x) / scale - (vertical ? track.y : track.x)
		offset^ = clamp((position - workbench_scroll_grab) / travel, 0, 1) * range
	}
}
