package app

import "core:strings"

import font_core "../font"
import "../ui"

gitaris_control_style :: proc(face: ^font_core.Face, scale: f32, primary := false) -> ui.UiStyle {
	style := ui.default_style
	style.font_id = ui.UiFont(uintptr(face))
	style.font_size = 13 * scale
	style.padding = 10 * scale
	// Buttons are pills: the renderer clamps the radius to half the height.
	style.radius = 999 * scale
	style.border = 0
	style.border_color = TEMPLATE_LINE
	style.focus_color = TEMPLATE_ACCENT
	style.text_color = primary ? TEMPLATE_LIGHT : TEMPLATE_TEXT
	style.color_top = primary ? TEMPLATE_ACCENT : TEMPLATE_BUTTON
	style.color_bottom = style.color_top
	style.hover_color = primary ? [4]f32{0.32, 0.32, 0.31, 1} : [4]f32{0.87, 0.87, 0.85, 1}
	style.active_color = primary ? TEMPLATE_DARK : [4]f32{0.83, 0.83, 0.81, 1}
	return style
}

// Text fields: light, gently rounded, with a hairline border.
gitaris_field_style :: proc(face: ^font_core.Face, scale: f32) -> ui.UiStyle {
	style := gitaris_control_style(face, scale)
	style.radius = 10 * scale
	style.border = scale
	style.color_top, style.color_bottom = TEMPLATE_LIGHT, TEMPLATE_LIGHT
	style.hover_color, style.active_color = TEMPLATE_LIGHT, TEMPLATE_LIGHT
	return style
}

gitaris_button :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string,
	rect: ui.Rect2d, scale: f32, primary := false, id := "") -> bool {
	ui.style_push(ctx, gitaris_control_style(face, scale, primary))
	result := ui.button(ctx, text, template_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

gitaris_row_button :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, id: string,
	rect: ui.Rect2d, selected: bool, scale: f32) -> bool {
	style := gitaris_control_style(face, scale)
	style.radius = 10 * scale
	style.color_top = selected ? TEMPLATE_SELECTED : TEMPLATE_CARD
	style.color_bottom = style.color_top
	style.hover_color = selected ? TEMPLATE_SELECTED : TEMPLATE_HOVER
	style.active_color = TEMPLATE_SELECTED
	style.border = 0
	ui.style_push(ctx, style)
	result := ui.button(ctx, "", template_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .SUBMIT
}

// A square checkbox without a label. Drawn after a row button, it receives the
// click itself (topmost hit testing), so checking never selects the row.
gitaris_check :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, id: string, value: ^bool,
	rect: ui.Rect2d, scale: f32) -> bool {
	style := gitaris_control_style(face, scale)
	style.padding = 4 * scale
	style.radius = 5 * scale
	style.color_top, style.color_bottom = TEMPLATE_LIGHT, TEMPLATE_LIGHT
	style.text_color = TEMPLATE_MUTED // Frame of the check square.
	ui.style_push(ctx, style)
	result := ui.check(ctx, "", value, template_rect(rect, scale), id = id)
	ui.style_pop(ctx)
	return result == .MODIFIED
}

gitaris_field :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, id, label, placeholder: string,
	value: ^strings.Builder, rect: ui.Rect2d, scale: f32, secret := false) -> ui.UiResult {
	if label != "" do template_label(ctx, face, label, {rect.x, rect.y - 22, rect.width, 18}, 12, TEMPLATE_MUTED, scale)
	ui.style_push(ctx, gitaris_field_style(face, scale))
	result := secret ? ui.secret_box(ctx, id, value, template_rect(rect, scale)) : ui.input_box(ctx, id, value, template_rect(rect, scale))
	ui.style_pop(ctx)
	if len(value.buf) == 0 {
		template_label(ctx, face, placeholder, {rect.x + 11, rect.y, rect.width - 22, rect.height}, 13, TEMPLATE_MUTED, scale)
	}
	return result
}

GITARIS_ERROR_TEXT :: [4]f32{0.56, 0.22, 0.20, 1}

gitaris_message :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, rect: ui.Rect2d, scale: f32,
	color := GITARIS_ERROR_TEXT) {
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
		template_label(ctx, face, remaining[:end], {rect.x, y, rect.width, 16}, 12, color, scale)
		remaining = strings.trim_space(remaining[end:])
		y += 17
	}
}

// Virtual rows keep large repositories within the immediate UI's element budget.
gitaris_scroll_begin :: proc(ctx: ^ui.UiContext, viewport: ui.Rect2d, count: int, row_height, scale: f32,
	content_width: f32 = 0) -> (first, last: int, offset: f32) {
	layout := ui.default_layout
	layout.rect = template_rect(viewport, scale)
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

gitaris_scroll_end :: proc(ctx: ^ui.UiContext, viewport: ui.Rect2d, scale: f32, horizontal := false) {
	ui.layout_end_scroll(ctx, horizontal)
	ui.layout_pop(ctx)
	window := &ctx.windows[ctx.window_index]
	if window.content_size.y > viewport.height * scale {
		thumb := max(22, viewport.height * viewport.height * scale / window.content_size.y)
		progress := window.scroll_offset.y / (window.content_size.y - viewport.height * scale)
		template_box(ctx, {viewport.x + viewport.width - 3, viewport.y + progress * (viewport.height - thumb), 3, thumb}, TEMPLATE_MUTED, 2, scale)
	}
	if horizontal && window.content_size.x > viewport.width * scale {
		thumb := max(22, viewport.width * viewport.width * scale / window.content_size.x)
		progress := window.scroll_offset.x / (window.content_size.x - viewport.width * scale)
		template_box(ctx, {viewport.x + progress * (viewport.width - thumb), viewport.y + viewport.height + 3, thumb, 3}, TEMPLATE_MUTED, 2, scale)
	}
}
