package ui

import "core:mem"
import "core:strings"
import "core:testing"

@(test)
ui_explicit_interaction_colors :: proc(t: ^testing.T) {
	style := default_style
	style.color_top, style.color_bottom = {1, 1, 1, 1}, {1, 1, 1, 1}
	style.hover_color = {0.93, 0.92, 0.92, 1}
	style.active_color = {0.86, 0.86, 0.85, 1}
	box := UiBox{style = style, hovered = true}
	highlight(&box)
	testing.expect(t, box.style.color_top == style.hover_color && box.style.color_bottom == style.hover_color)
	box = UiBox{style = style, hovered = true, active = true}
	highlight(&box)
	testing.expect(t, box.style.color_top == style.active_color && box.style.color_bottom == style.active_color)
	box = UiBox{style = style}
	highlight(&box)
	testing.expect(t, box.style.color_top == style.color_top && box.style.color_bottom == style.color_bottom)
	// Styles without explicit fills retain the previous gradient behavior.
	box = UiBox{style = default_style, hovered = true}
	highlight(&box)
	testing.expect(t, abs(box.style.color_top.r - default_style.color_top.r * 1.15) < 0.001)
}

@(test)
ui_layout_and_render_iteration :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	checked := true
	begin(ui, 800, 600)
	{
		begin_window(ui, {100, 50, 300, 200}, "main")
		layout_row(ui, 2)
		button(ui, "Run")
		label(ui, "Status")
		check(ui, "Enabled", &checked)
		style_push(ui)
		style_push_radius(ui, 12)
		label(ui, "Styled")
		style_pop(ui)
		label(ui, "Clipped", {390, 230, 100, 40})
		label(ui, "Offscreen", {900, 700, 100, 40})
	}
	end(ui)
	boxes := elements(ui)
	testing.expect(t, len(boxes) == 7)
	testing.expect(t, boxes[1].rect == Rect2d{104, 54, 144, 40})
	testing.expect(t, boxes[2].rect == Rect2d{252, 54, 144, 40})
	testing.expect(t, boxes[3].rect == Rect2d{104, 98, 144, 40})
	testing.expect(t, boxes[3].icon == .CHECK && boxes[3].icon_rect.width > 0)
	testing.expect(t, boxes[3].text_pos.x > boxes[3].icon_rect.x + boxes[3].icon_rect.width)
	testing.expect(t, !boxes[2].draw_background && boxes[1].draw_background)
	testing.expect(t, boxes[4].style.radius == 12 && boxes[5].style.radius == default_style.radius)
	testing.expect(t, boxes[5].boundary_rect == Rect2d{390, 230, 10, 20})
	cursor, visited := 0, 0
	for box := next_element(ui, &cursor); box != nil; box = next_element(ui, &cursor) {
		testing.expect(t, box.zindex == i32(visited))
		visited += 1
	}
	testing.expect(t, visited == 6 && next_element(ui, &cursor) == nil)
	begin(ui, 800, 600)
	end(ui)
	testing.expect(t, len(elements(ui)) == 0)
}

@(private)
test_button_frame :: proc(ui: ^UiContext, id: string = "button") -> UiResult {
	begin(ui, 400, 300)
	result := button(ui, "Click", {10, 10, 100, 40}, id = id)
	end(ui)
	return result
}

@(test)
ui_click_capture_and_stable_ids :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	input_mouse_move(ui, 20, 20)
	test_button_frame(ui)
	input_mouse_button(ui, .LEFT, true)
	testing.expect(t, test_button_frame(ui) == .PRESSED)
	testing.expect(t, test_button_frame(ui) == .ACTIVE)
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_button_frame(ui) == .SUBMIT)
	testing.expect(t, test_button_frame(ui) == .NOT_ACTIVE)
	input_mouse_button(ui, .LEFT, true)
	test_button_frame(ui)
	input_mouse_move(ui, 200, 200)
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_button_frame(ui) == .NOT_ACTIVE)
	input_mouse_move(ui, 20, 20)
	input_mouse_button(ui, .LEFT, true)
	test_button_frame(ui)
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_button_frame(ui, "replacement") == .NOT_ACTIVE)
	testing.expect(t, ui.active_id == 0 && ui.focus_id == 0)
	// A down/up pair in a single frame still activates once.
	input_mouse_button(ui, .LEFT, true)
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_button_frame(ui, "replacement") == .SUBMIT)
}

@(private)
test_overlap_frame :: proc(ui: ^UiContext, cover := false) -> [2]UiResult {
	result: [2]UiResult
	begin(ui, 400, 300)
	{
		begin_window(ui, {0, 0, 200, 200}, "bottom")
		result[0] = button(ui, "Click", {10, 10, 100, 40})
	}
	{
		begin_window(ui, {0, 0, 200, 200}, "top")
		if cover {
			label(ui, "Cover", {10, 10, 100, 40})
		} else {
			result[1] = button(ui, "Click", {10, 10, 100, 40})
		}
	}
	end(ui)
	return result
}

@(test)
ui_topmost_window_owns_input :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	input_mouse_move(ui, 20, 20)
	test_overlap_frame(ui)
	input_mouse_button(ui, .LEFT, true)
	testing.expect(t, test_overlap_frame(ui) == [2]UiResult{.NOT_ACTIVE, .PRESSED})
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_overlap_frame(ui) == [2]UiResult{.NOT_ACTIVE, .SUBMIT})
	test_overlap_frame(ui, true)
	input_mouse_button(ui, .LEFT, true)
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_overlap_frame(ui, true)[0] == .NOT_ACTIVE)
}

@(private)
test_check_frame :: proc(ui: ^UiContext, value: ^bool) -> UiResult {
	begin(ui, 400, 300)
	result := check(ui, "Enabled", value, {10, 10, 160, 40})
	end(ui)
	return result
}

@(test)
ui_check_changes_on_activation :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	value := false
	input_mouse_move(ui, 20, 20)
	test_check_frame(ui, &value)
	input_mouse_button(ui, .LEFT, true)
	testing.expect(t, test_check_frame(ui, &value) == .PRESSED && !value)
	input_mouse_button(ui, .LEFT, false)
	testing.expect(t, test_check_frame(ui, &value) == .MODIFIED && value)
	input_key(ui, .SPACE, true)
	testing.expect(t, test_check_frame(ui, &value) == .MODIFIED && !value)
}

@(private)
test_editor_frame :: proc(ui: ^UiContext, value: ^strings.Builder, multiline := false) -> UiResult {
	begin(ui, 400, 300)
	result: UiResult
	if multiline {
		result = textbox(ui, "edit", value, {10, 10, 100, 50})
	} else {
		result = input_box(ui, "edit", value, {10, 10, 100, 40})
	}
	end(ui)
	return result
}

@(test)
ui_editor_utf8_and_focus :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	strings.write_string(&value, "abé🦊")
	// Clicking far right of the text places the caret at its end.
	input_mouse_move(ui, 100, 20)
	input_mouse_button(ui, .LEFT, true)
	test_editor_frame(ui, &value)
	testing.expect(t, ui.caret == len("abé🦊"))
	input_mouse_button(ui, .LEFT, false)
	input_key(ui, .LEFT, true)
	input_text(ui, "!")
	testing.expect(t, test_editor_frame(ui, &value) == .MODIFIED)
	testing.expect(t, strings.to_string(value) == "abé!🦊")
	input_key(ui, .BACKSPACE, true)
	test_editor_frame(ui, &value)
	input_key(ui, .BACKSPACE, true, true)
	test_editor_frame(ui, &value)
	testing.expect(t, strings.to_string(value) == "ab🦊")
	input_key(ui, .DELETE, true)
	test_editor_frame(ui, &value)
	testing.expect(t, strings.to_string(value) == "ab")
	input_text(ui, "x\r\ny")
	input_key(ui, .RETURN, true)
	testing.expect(t, test_editor_frame(ui, &value) == .SUBMIT)
	testing.expect(t, strings.to_string(value) == "abxy")
	input_key(ui, .ESCAPE, true)
	input_text(ui, "ignored")
	test_editor_frame(ui, &value)
	testing.expect(t, ui.focus_id == 0 && !elements(ui)[0].focused)
	testing.expect(t, strings.to_string(value) == "abxy")
}

@(test)
ui_multiline_editing_and_caret :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	input_mouse_move(ui, 20, 20)
	input_mouse_button(ui, .LEFT, true)
	input_text(ui, "éa\r\n🦊b\nc")
	testing.expect(t, test_editor_frame(ui, &value, true) == .MODIFIED)
	testing.expect(t, strings.to_string(value) == "éa\n🦊b\nc")
	box := &elements(ui)[0]
	testing.expect(t, box.caret_rect.y + box.caret_rect.height <= box.rect.y + box.rect.height - box.style.padding)
	input_mouse_button(ui, .LEFT, false)
	input_key(ui, .UP, true)
	test_editor_frame(ui, &value, true)
	testing.expect(t, ui.caret == len("éa\n🦊"))
	input_text(ui, "!")
	test_editor_frame(ui, &value, true)
	testing.expect(t, strings.to_string(value) == "éa\n🦊!b\nc")
	input_key(ui, .HOME, true)
	test_editor_frame(ui, &value, true)
	testing.expect(t, ui.caret == len("éa\n"))
	input_key(ui, .RETURN, true)
	test_editor_frame(ui, &value, true)
	testing.expect(t, strings.to_string(value) == "éa\n\n🦊!b\nc")
}

@(private)
test_measure :: proc(font: UiFont, text: string, size: f32) -> [2]f32 {
	calls := (^int)(uintptr(font))
	calls^ += 1
	return {f32(len(text)) * size * 0.5, size}
}

@(private)
test_cached_frame :: proc(ui: ^UiContext, font: UiFont, text: string, size: f32 = 16) {
	begin(ui, 400, 300)
	style_push_font(ui, font)
	ui.styles[ui.n_styles].font_size = size
	label(ui, text)
	end(ui)
}

@(private)
test_controls_frame :: proc(ui: ^UiContext, font: UiFont, value: ^strings.Builder) {
	begin(ui, 400, 300)
	{
		// Window backgrounds do not invoke the text measurement callback.
		begin_window(ui, {0, 0, 400, 300}, "all controls")
		style_push_font(ui, font)
		button(ui, "Save")
		label(ui, "Status")
		checked := true
		check(ui, "Enabled", &checked)
		input_box(ui, "name", value)
		textbox(ui, "notes", value)
	}
	end(ui)
}

@(test)
ui_text_cache_and_allocation_lifetime :: proc(t: ^testing.T) {
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	ui := init(mem.tracking_allocator(&tracking), test_measure)
	calls: int
	font := UiFont(uintptr(&calls))
	test_cached_frame(ui, font, "cached")
	allocations := tracking.total_allocation_count
	for _ in 0..<100 do test_cached_frame(ui, font, "cached")
	testing.expect(t, calls == 1)
	testing.expect(t, tracking.total_allocation_count == allocations)
	test_cached_frame(ui, font, "change")
	testing.expect(t, calls == 2)
	test_cached_frame(ui, font, "change", 20)
	testing.expect(t, calls == 3 && elements(ui)[0].text_size == [2]f32{60, 20})
	other_calls: int
	test_cached_frame(ui, UiFont(uintptr(&other_calls)), "change", 20)
	testing.expect(t, other_calls == 1)
	set_text_measure(ui, test_measure)
	test_cached_frame(ui, font, "change", 20)
	testing.expect(t, calls == 4)
	// Element text owns its snapshot rather than borrowing the caller's storage.
	source := strings.builder_make()
	strings.write_string(&source, "owned")
	test_cached_frame(ui, font, strings.to_string(source))
	source.buf[0] = 'X'
	strings.builder_destroy(&source)
	testing.expect(t, strings.to_string(elements(ui)[0].text) == "owned")
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	strings.write_string(&value, "editing")
	test_controls_frame(ui, font, &value)
	input_mouse_move(ui, 20, 145)
	input_mouse_button(ui, .LEFT, true)
	test_controls_frame(ui, font, &value)
	input_mouse_button(ui, .LEFT, false)
	test_controls_frame(ui, font, &value)
	testing.expect(t, elements(ui)[4].focused && elements(ui)[4].caret_rect.width == 1)
	allocations = tracking.total_allocation_count
	measurements := calls
	for _ in 0..<100 do test_controls_frame(ui, font, &value)
	testing.expect(t, calls == measurements && tracking.total_allocation_count == allocations)
	destroy(ui)
	testing.expect(t, tracking.current_memory_allocated == 0 && len(tracking.allocation_map) == 0)
}

@(private)
test_scroll_frame :: proc(ui: ^UiContext) {
	begin(ui, 400, 300)
	{
		begin_window(ui, {10, 10, 160, 100}, "scroll")
		layout_begin_scroll(ui, false)
		for _ in 0..<5 do label(ui, "Row")
		layout_end_scroll(ui, false)
	}
	end(ui)
}

@(test)
ui_scroll_clips_and_reuses_extent :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	input_mouse_move(ui, 20, 20)
	test_scroll_frame(ui)
	input_scroll(ui, 0, -100)
	test_scroll_frame(ui)
	testing.expect(t, ui.windows[0].scroll_offset.y == 124)
	testing.expect(t, elements(ui)[1].rect.y == -110)
	testing.expect(t, elements(ui)[1].boundary_rect.height == 0)
	testing.expect(t, elements(ui)[5].rect.y == 66)
	cursor, count := 0, 0
	for box := next_element(ui, &cursor); box != nil; box = next_element(ui, &cursor) do count += 1
	testing.expect(t, count == 4)
	input_scroll(ui, 0, 100)
	test_scroll_frame(ui)
	testing.expect(t, ui.windows[0].scroll_offset.y == 0 && elements(ui)[1].rect.y == 14)
}

@(test)
ui_secret_box_masks_text :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	defer free_all(context.temp_allocator)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	frame :: proc(ui: ^UiContext, value: ^strings.Builder) -> ^UiBox {
		begin(ui, 400, 300)
		_ = secret_box(ui, "secret", value, {10, 10, 100, 40})
		end(ui)
		for &box in elements(ui) do if .EDITABLE in box.actions do return &box
		return nil
	}
	input_mouse_move(ui, 20, 20)
	input_mouse_button(ui, .LEFT, true)
	frame(ui, &value)
	input_mouse_button(ui, .LEFT, false)
	input_text(ui, "pä ss")
	box := frame(ui, &value)
	testing.expect(t, strings.to_string(value) == "pä ss")
	testing.expect(t, box != nil && strings.to_string(box.text) == "*****")
}

@(test)
ui_editor_mouse_selection_and_clipboard :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	strings.write_string(&value, "hello world")
	// Fallback metrics: 8px per character; the text starts at x = 16.
	input_mouse_move(ui, 33, 30)
	input_mouse_button(ui, .LEFT, true)
	test_editor_frame(ui, &value)
	testing.expect(t, ui.caret == 2 && ui.anchor == 2)
	input_mouse_move(ui, 56, 30)
	test_editor_frame(ui, &value)
	input_mouse_button(ui, .LEFT, false)
	test_editor_frame(ui, &value)
	testing.expect(t, ui.anchor == 2 && ui.caret == 5)
	box := &elements(ui)[0]
	testing.expect(t, box.selection_rects[0].width == 24 && box.selection_rects[0].x == 32)
	input_key(ui, .CTRL, true)
	input_key(ui, .C, true)
	test_editor_frame(ui, &value)
	testing.expect(t, ui.clipboard_pending && strings.to_string(ui.clipboard) == "llo")
	input_text(ui, "LL")
	testing.expect(t, test_editor_frame(ui, &value) == .MODIFIED)
	testing.expect(t, strings.to_string(value) == "heLL world" && ui.caret == 4 && ui.anchor == 4)
	input_key(ui, .A, true)
	test_editor_frame(ui, &value)
	testing.expect(t, ui.anchor == 0 && ui.caret == len("heLL world"))
	input_key(ui, .X, true)
	test_editor_frame(ui, &value)
	testing.expect(t, strings.to_string(value) == "" && strings.to_string(ui.clipboard) == "heLL world")
	input_key(ui, .CTRL, false)
	input_text(ui, "abc")
	test_editor_frame(ui, &value)
	input_key(ui, .SHIFT, true)
	input_key(ui, .LEFT, true)
	test_editor_frame(ui, &value)
	input_key(ui, .LEFT, true, true)
	test_editor_frame(ui, &value)
	testing.expect(t, ui.anchor == 3 && ui.caret == 1)
	input_key(ui, .SHIFT, false)
	input_key(ui, .BACKSPACE, true)
	test_editor_frame(ui, &value)
	testing.expect(t, strings.to_string(value) == "a" && ui.caret == 1)
	// Moving the caret from the application drops the selection.
	input_key(ui, .SHIFT, true)
	input_key(ui, .HOME, true)
	test_editor_frame(ui, &value)
	ui.caret = 1
	test_editor_frame(ui, &value)
	testing.expect(t, ui.anchor == 1 && elements(ui)[0].selection_rects[0].width == 0)
}

@(private)
test_document_frame :: proc(ui: ^UiContext, value: ^strings.Builder, scroll: ^[2]f32) -> (UiResult, [2]f32, [2]f32) {
	begin(ui, 400, 300)
	result, content, view := text_editor(ui, "doc", value, {10, 10, 200, 100}, scroll)
	end(ui)
	return result, content, view
}

@(test)
ui_document_editor_scrolls_pages_and_tabs :: proc(t: ^testing.T) {
	ui := init()
	defer destroy(ui)
	value := strings.builder_make()
	defer strings.builder_destroy(&value)
	for i in 0..<30 {
		if i > 0 do strings.write_byte(&value, '\n')
		strings.write_string(&value, "line")
		strings.write_byte(&value, u8('0' + i / 10))
		strings.write_byte(&value, u8('0' + i % 10))
	}
	scroll: [2]f32
	_, content, view := test_document_frame(ui, &value, &scroll)
	testing.expect(t, content.y == 480 && view == [2]f32{187, 88})
	input_mouse_move(ui, 50, 50)
	input_scroll(ui, 0, -1)
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, scroll.y == 48)
	// The click lands on the fourth line, as it is drawn after scrolling.
	input_mouse_move(ui, 17, 21)
	input_mouse_button(ui, .LEFT, true)
	test_document_frame(ui, &value, &scroll)
	input_mouse_button(ui, .LEFT, false)
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, ui.caret == 21 && scroll.y == 48)
	input_key(ui, .SHIFT, true)
	input_key(ui, .DOWN, true)
	test_document_frame(ui, &value, &scroll)
	input_key(ui, .DOWN, true, true)
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, ui.anchor == 21 && ui.caret == 35)
	rects := elements(ui)[0].selection_rects
	testing.expect(t, rects[0].height == 16 && rects[1].height == 16 && rects[2].width == 0)
	input_key(ui, .SHIFT, false)
	input_key(ui, .PAGE_DOWN, true)
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, ui.caret == 63 && ui.anchor == 63 && scroll.y == 72)
	input_key(ui, .CTRL, true)
	input_key(ui, .END, true)
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, ui.caret == len(value.buf) && scroll.y == 392)
	testing.expect(t, ui.wants_tab)
	input_key(ui, .CTRL, false)
	input_text(ui, "\t")
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, strings.has_suffix(strings.to_string(value), "line29\t"))
	// A scrollbar may set the view; it is kept within the document.
	scroll.y = 10_000
	test_document_frame(ui, &value, &scroll)
	testing.expect(t, scroll.y == 392)
}
