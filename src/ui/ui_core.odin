package ui

import "base:runtime"
import "core:strings"

// --------------------------------------------------------------- //
// Default configs
MAX_BOXES      :: #config(MAX_BOXES, 4096)
MAX_WINDOWS    :: #config(MAX_WINDOWS, 128)
MAX_STYLES     :: #config(MAX_STYLES, 128)
MAX_LAYOUT     :: #config(MAX_LAYOUT, 128)

// --------------------------------------------------------------- //

UiResult :: enum {
	OK,
	ACTIVE,
	NOT_ACTIVE,
	SUBMIT,
	MODIFIED,
	PRESSED,
	RELEASED,
}

// --------------------------------------------------------------- //

UiAlignment :: enum {
	NONE,
	RIGHT,
	CENTER,
	TOP,
	BOTTOM,
}

UiAlignments :: bit_set[UiAlignment;u8]

// --------------------------------------------------------------- //

UiAction :: enum {
	NONE,
	HOVERABLE,
	CLICKABLE,
	RIGHT_CLICKABLE,
	SCROLLABLE,
	RESIZABLE,
	CLOSABLE,
	NO_CLIPPING,
	EDITABLE,
}

UiActions :: bit_set[UiAction;u16]

// --------------------------------------------------------------- //

UiIcon :: enum {
	NONE,
	CHECK,
	CHECK_UNCHECKED,
	RESIZE,
	CLOSE,
}

// --------------------------------------------------------------- //

Rect2d :: struct {
	x, y:          f32,
	width, height: f32,
}

rect2d_set_start :: proc(self: ^Rect2d, x, y: f32) {
	self.x = x
	self.y = y
}

rect2d_set_offset :: proc(self: ^Rect2d, w, h: f32) {
	self.width = w
	self.height = h
}

rect2d_init :: proc {
	rect2d_init_simple,
	rect2d_init_vec2,
	rect2d_init_vec4,
}

rect2d_init_simple :: proc(x, y, w, h: f32) -> Rect2d {
	return Rect2d{x, y, w, h}
}

rect2d_init_vec2 :: proc(top_left: [2]f32, size: [2]f32) -> Rect2d {
	return Rect2d{top_left.x, top_left.y, size.x, size.y}
}

rect2d_init_vec4 :: proc(vec_rect: [4]f32) -> Rect2d {
	return Rect2d{vec_rect.x, vec_rect.y, vec_rect.z, vec_rect.w}
}

// --------------------------------------------------------------- //

UiFont :: distinct uintptr
UiId :: distinct u64
UiMeasureText :: #type proc(font: UiFont, text: string, size: f32) -> [2]f32

// --------------------------------------------------------------- //

UiStyle :: struct {
	font_id:      UiFont,
	font_size:    f32,
	text_color:   [4]f32,
	padding:      f32,
	color_top:    [4]f32,
	color_bottom: [4]f32,
	border_color: [4]f32,
	focus_color:  [4]f32,
	// Optional solid interaction fills; alpha zero keeps legacy highlighting.
	hover_color:  [4]f32,
	active_color: [4]f32,
	transition_duration: f32,
	radius:       f32,
	edge:         f32,
	border:       f32,
}

// --------------------------------------------------------------- //

default_style :: UiStyle {
	font_id      = 0,
	font_size    = 16,
	text_color   = {1, 1, 1, 1},
	padding      = 6,
	color_top    = {0.2, 0.2, 0.2, 1.0},
	color_bottom = {0.15, 0.15, 0.15, 1.0},
	border_color = {0.23, 0.28, 0.36, 1},
	focus_color  = {0.4, 0.7, 1, 1},
	transition_duration = 0.14,
	radius       = 4,
	edge         = 2,
	border       = 0,
}

// --------------------------------------------------------------- //

UiBox :: struct {
	id:            UiId,
	zindex:        i32,
	rect:          Rect2d,
	boundary_rect: Rect2d,
	scroll_offset: [2]f32,
	text:          strings.Builder,
	style:         UiStyle,
	alignment:     UiAlignments,
	actions:       UiActions,
	icon:          UiIcon,
	icon_rect:     Rect2d,
	text_pos:      [2]f32,
	text_size:     [2]f32,
	caret_rect:    Rect2d,
	// Up to three rectangles (first line, whole middle lines, last line).
	selection_rects: [3]Rect2d,
	line_start, line_end: [2]f32,
	line_width: f32,
	result:        UiResult,
	draw_background: bool,
	hovered, active, focused: bool,
	window_index:  i32,
	// Per-slot caches survive begin(); text storage only grows when needed.
	_measured:     bool,
	_font:         UiFont,
	_font_size:    f32,
	_caret:        int,
	_caret_offset: [2]f32,
	_anchor:       int,
	_anchor_offset: [2]f32,
	_line_height:  f32,
	_animation: UiStyleAnimation,
}

UiWindow :: struct {
	id: UiId,
	scroll_offset, content_size: [2]f32,
	style_depth, layout_depth: i32,
}

// --------------------------------------------------------------- //

UiLayout :: struct {
	rect:               Rect2d,
	content:            Rect2d,
	margin:             f32,
	alignment:          UiAlignments,
	box_size:           [2]f32,
	scrollable_content: [2]f32,
	column_width:       f32,
	scroll_offset:      [2]f32,
	_columns, _column:  int,
	_row_height:        f32,
	_scrolling:         bool,
}

// --------------------------------------------------------------- //

default_layout :: UiLayout {
	rect      = {-1, -1, -1, -1},
	content   = {-1, -1, 0, 0},
	box_size  = {140, 40},
	margin    = 4,
	alignment = {.NONE},
	column_width = -1,
}

// --------------------------------------------------------------- //

UiContext :: struct {
	allocator:       runtime.Allocator,
	screen:          Rect2d,
	delta_time:      f32,
	animations_enabled: bool,
	delta_mouse:     [2]f32,
	mouse_pos:       [2]f32,
	windows:         [MAX_WINDOWS]UiWindow,
	boxes:           [MAX_BOXES]UiBox,
	n_boxes, used_boxes: int,
	n_windows:       i32,
	window_index:    i32,
	measure_text:    UiMeasureText,
	input:           UiInput,
	active_id, focus_id, hover_id: UiId,
	active_button:   Mouse_Button,
	caret:           int,
	// The other end of the selection in the focused editor; equal to caret
	// when nothing is selected. edit_id/edit_caret detect caret changes made
	// by the application, which clear the selection.
	anchor:          int,
	edit_id:         UiId,
	edit_caret:      int,
	// Set by the focused editor when Tab should insert a tab character rather
	// than move focus. Read by the platform layer between frames.
	wants_tab:       bool,
	// Copy/cut output for the platform clipboard; clear clipboard_pending
	// after taking the text.
	clipboard:       strings.Builder,
	clipboard_pending: bool,
	hover_window:    i32,
	had_elements, pointer_claimed: bool,
	active_seen, focus_seen, in_frame: bool,

	// styling
	//
	styles:          [MAX_STYLES]UiStyle,
	n_styles:        i32,

	// layout
	//
	layouts:         [MAX_LAYOUT]UiLayout,
	n_layouts:       i32,
}

// --------------------------------------------------------------- //

clip_rect :: proc(rect: Rect2d, point: [2]f32) -> bool {
	return rect.width > 0 && rect.height > 0 &&
		point.x >= rect.x && point.x < rect.x + rect.width &&
		point.y >= rect.y && point.y < rect.y + rect.height
}

rect_intersection :: proc(a, b: Rect2d) -> Rect2d {
	x, y := max(a.x, b.x), max(a.y, b.y)
	return {x, y, max(0, min(a.x + a.width, b.x + b.width) - x),
		max(0, min(a.y + a.height, b.y + b.height) - y)}
}

// --------------------------------------------------------------- //

init :: proc(allocator := context.allocator, measure_text: UiMeasureText = nil) -> (context_t: ^UiContext) {
	context_t = new(UiContext, allocator)
	context_t.allocator = allocator
	context_t.measure_text = measure_text
	context_t.animations_enabled = true
	context_t.window_index = -1
	context_t.input.text = strings.builder_make(allocator)
	context_t.clipboard = strings.builder_make(allocator)
	return context_t
}

destroy :: proc(self: ^UiContext) {
	if self == nil do return
	for &box in self.boxes[:self.used_boxes] do strings.builder_destroy(&box.text)
	strings.builder_destroy(&self.input.text)
	strings.builder_destroy(&self.clipboard)
	free(self, self.allocator)
}

// Call when the measuring backend or its font metrics change.
set_text_measure :: proc(self: ^UiContext, measure_text: UiMeasureText) {
	self.measure_text = measure_text
	for &box in self.boxes[:self.used_boxes] do box._measured = false
}

// --------------------------------------------------------------- //

begin :: proc(self: ^UiContext, window_w, window_h: f32) {
	assert(!self.in_frame)
	self.in_frame = true
	self.screen.width = max(0, window_w)
	self.screen.height = max(0, window_h)
	// Previous-frame geometry gives topmost hit testing without sorting or a tree.
	self.had_elements = self.n_boxes > 0
	self.hover_id = 0
	self.hover_window = -1
	for i := self.n_boxes - 1; i >= 0; i -= 1 {
		box := &self.boxes[i]
		if clip_rect(box.rect, self.mouse_pos) && clip_rect(box.boundary_rect, self.mouse_pos) {
			self.hover_window = box.window_index
			if box.actions != {} || box.draw_background {
				self.hover_id = box.id
				break
			}
		}
	}
	if self.input.mouse_pressed[.LEFT] && self.hover_id != self.focus_id do self.focus_id = 0
	self.n_boxes = 0
	self.n_windows = 0
	self.window_index = -1
	self.pointer_claimed = false
	self.active_seen = false
	self.focus_seen = false
	self.wants_tab = false
	self.n_styles = 0
	self.styles[0] = default_style
	self.n_layouts = -1
	layout_push(self)
}

// --------------------------------------------------------------- //

end :: proc(self: ^UiContext) {
	assert(self.in_frame && self.window_index == -1)
	assert(self.n_styles == 0 && self.n_layouts == 0, "Unbalanced UI stacks")
	assert(!self.layouts[0]._scrolling)
	if !self.active_seen || !self.input.mouse_down[self.active_button] do self.active_id = 0
	if !self.focus_seen do self.focus_id = 0
	for &box in self.boxes[:self.n_boxes] do animate_style(self, &box)
	// Disappearing/virtualized controls must not resurrect an old transition.
	for &box in self.boxes[self.n_boxes:self.used_boxes] do box._animation = {}
	self.in_frame = false
	input_reset(self)
}

// --------------------------------------------------------------- //

@(deferred_out = end_window)
begin_window :: proc(self: ^UiContext, win_rect: Rect2d, id: string = "") -> (^UiContext, bool) {
	assert(self.in_frame && self.window_index == -1, "Windows cannot be nested")
	assert(self.n_windows < MAX_WINDOWS)
	self.window_index = self.n_windows
	self.n_windows += 1
	window := &self.windows[self.window_index]
	window_id := id == "" ? UiId(self.n_windows) : make_id(id)
	if window.id != window_id do window^ = {}
	window.id = window_id
	window.style_depth = self.n_styles
	window.layout_depth = self.n_layouts
	box := allocate_box(self)
	box.id = window.id
	box.rect = win_rect
	box.boundary_rect = rect_intersection(win_rect, self.screen)
	box.draw_background = true
	strings.builder_reset(&box.text)
	box.text_size = {}
	box._measured = false
	style_push(self, self.styles[self.n_styles])
	layout := default_layout
	layout.rect = win_rect
	layout_push(self, layout)
	return self, true
}

// --------------------------------------------------------------- //

end_window :: proc(self: ^UiContext, opened: bool) {
	if !opened do return
	assert(self.window_index >= 0)
	window := &self.windows[self.window_index]
	assert(self.n_styles == window.style_depth + 1 && self.n_layouts == window.layout_depth + 1,
		"Pop window styles/layouts before leaving its scope")
	assert(!self.layouts[self.n_layouts]._scrolling)
	style_pop(self)
	layout_pop(self)
	self.window_index = -1
}

// --------------------------------------------------------------- //

new_box :: proc(
	self: ^UiContext,
	str: string,
	alignment: UiAlignments,
	actions: UiActions,
	rect: Rect2d,
	id: string = "",
) -> ^UiBox {
	box := allocate_box(self)
	seed := self.window_index >= 0 ? self.windows[self.window_index].id : UiId(0)
	box.id = make_id(id == "" ? str : id, seed)
	box.alignment = alignment
	box.actions = actions
	box.rect = layout_next(self, rect)
	clip := .NO_CLIPPING in actions ? self.screen : layout_clip(self)
	box.boundary_rect = rect_intersection(box.rect, clip)
	box.draw_background = true
	box.result = interact(self, box)
	cache_text(self, box, str)
	position_text(box)
	return box
}

// --------------------------------------------------------------- //

button_am :: button

// --------------------------------------------------------------- //

set_screen :: proc(self: ^UiContext, screen: Rect2d) {
	self.screen = screen
}

// --------------------------------------------------------------- //

set_delta_time :: proc(self: ^UiContext, delta_time: f32) {
	self.delta_time = delta_time
}

// --------------------------------------------------------------- //

set_delta_mouse :: proc(self: ^UiContext, delta_mouse: [2]f32) {
	self.delta_mouse[0] = delta_mouse[0]
	self.delta_mouse[1] = delta_mouse[1]
}

// --------------------------------------------------------------- //

set_mouse_pos :: proc(self: ^UiContext, mouse_pos: [2]f32) {
	self.mouse_pos[0] = mouse_pos[0]
	self.mouse_pos[1] = mouse_pos[1]
}

// --------------------------------------------------------------- //

style_push :: proc(self: ^UiContext, style: UiStyle = default_style) {
	assert(self.n_styles + 1 < MAX_STYLES)
	self.n_styles += 1

	self.styles[self.n_styles] = style
}

style_pop :: proc(self: ^UiContext) {
	assert(self.n_styles > 0)
	self.n_styles -= 1
}

// --------------------------------------------------------------- //

style_push_font :: proc(self: ^UiContext, font: UiFont) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].font_id = font
}

// --------------------------------------------------------------- //

style_push_color :: proc(self: ^UiContext, color_top: [4]f32, color_bottom: [4]f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].color_top[0] = color_top[0]
	self.styles[self.n_styles].color_top[1] = color_top[1]
	self.styles[self.n_styles].color_top[2] = color_top[2]
	self.styles[self.n_styles].color_top[3] = color_top[3]

	self.styles[self.n_styles].color_bottom[0] = color_bottom[0]
	self.styles[self.n_styles].color_bottom[1] = color_bottom[1]
	self.styles[self.n_styles].color_bottom[2] = color_bottom[2]
	self.styles[self.n_styles].color_bottom[3] = color_bottom[3]
}

// --------------------------------------------------------------- //

style_push_radius :: proc(self: ^UiContext, radius: f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].radius = radius
}

// --------------------------------------------------------------- //

style_push_border :: proc(self: ^UiContext, border: f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].border = border
}

// --------------------------------------------------------------- //

style_push_edge :: proc(self: ^UiContext, edge: f32) {
	assert(self.n_styles >= 0)

	self.styles[self.n_styles].edge = edge
}

// --------------------------------------------------------------- //

layout_push :: proc(self: ^UiContext, layout := default_layout) {
	assert(self.n_layouts + 1 < MAX_LAYOUT)
	parent_rect := self.n_layouts >= 0 ? self.layouts[self.n_layouts].rect : self.screen
	self.n_layouts += 1
	self.layouts[self.n_layouts] = layout
	next := &self.layouts[self.n_layouts]
	if next.rect.width < 0 do next.rect = parent_rect
	if next.content.x < 0 do next.content.x = next.rect.x + next.margin
	if next.content.y < 0 do next.content.y = next.rect.y + next.margin
	next._columns = max(1, next._columns)
}

layout_pop :: proc(self: ^UiContext) {
	assert(self.n_layouts > 0 && !self.layouts[self.n_layouts]._scrolling)
	self.n_layouts -= 1
}

// --------------------------------------------------------------- //

layout_push_content :: proc(self: ^UiContext, content: Rect2d) {
	assert(self.n_layouts >= 0)

	self.layouts[self.n_layouts].content = content
}

// --------------------------------------------------------------- //

layout_push_rect :: proc(self: ^UiContext, rect: Rect2d) {
	assert(self.n_layouts >= 0)

	self.layouts[self.n_layouts].rect = rect
	self.layouts[self.n_layouts].content = {rect.x + self.layouts[self.n_layouts].margin,
		rect.y + self.layouts[self.n_layouts].margin, 0, 0}
	self.layouts[self.n_layouts]._column = 0
	self.layouts[self.n_layouts]._row_height = 0
}

// --------------------------------------------------------------- //

layout_push_box_size :: proc(self: ^UiContext, box_size: [2]f32) {
	assert(self.n_layouts >= 0)

	self.layouts[self.n_layouts].box_size[0] = box_size[0]
	self.layouts[self.n_layouts].box_size[1] = box_size[1]
}

// --------------------------------------------------------------- //

layout_push_margin :: proc(self: ^UiContext, margin: f32) {
	assert(self.n_layouts >= 0)
	layout := &self.layouts[self.n_layouts]
	delta := max(0, margin) - layout.margin
	layout.content.x += delta
	layout.content.y += delta
	layout.margin = max(0, margin)
}

// --------------------------------------------------------------- //

layout_push_alignment :: proc(self: ^UiContext, alignments: UiAlignments) {
	assert(self.n_layouts >= 0)

	self.layouts[self.n_layouts].alignment = alignments
}

// --------------------------------------------------------------- //

layout_begin_scroll :: proc(self: ^UiContext, auto_h_scroll := true) {
	assert(self.window_index >= 0, "Scrolling requires a window")
	layout := &self.layouts[self.n_layouts]
	assert(!layout._scrolling)
	layout._scrolling = true
	window := &self.windows[self.window_index]
	if clip_rect(layout_clip(self), self.mouse_pos) &&
		(!self.had_elements || self.hover_window == self.window_index) {
		window.scroll_offset -= self.input.scroll * max(1, layout.box_size.y)
		self.input.scroll = {}
	}
	window.scroll_offset.x = auto_h_scroll ? clamp(window.scroll_offset.x, 0, max(0, window.content_size.x - layout.rect.width)) : 0
	window.scroll_offset.y = clamp(window.scroll_offset.y, 0, max(0, window.content_size.y - layout.rect.height))
	layout.scroll_offset = window.scroll_offset
	layout.scrollable_content = {}
}

// --------------------------------------------------------------- //

layout_end_scroll :: proc(self: ^UiContext, auto_h_scroll := true) {
	layout := &self.layouts[self.n_layouts]
	assert(layout._scrolling && self.window_index >= 0)
	window := &self.windows[self.window_index]
	window.content_size = layout.scrollable_content
	window.scroll_offset.x = auto_h_scroll ? clamp(layout.scroll_offset.x, 0, max(0, window.content_size.x - layout.rect.width)) : 0
	window.scroll_offset.y = clamp(layout.scroll_offset.y, 0, max(0, window.content_size.y - layout.rect.height))
	layout.scroll_offset = {}
	layout._scrolling = false
}

// --------------------------------------------------------------- //

layout_row :: proc(self: ^UiContext, n_columns := 1) {
	assert(self.n_layouts >= 0 && self.n_layouts < MAX_LAYOUT)
	assert(n_columns > 0)
	layout := &self.layouts[self.n_layouts]
	if layout._column > 0 do layout.content.y += layout._row_height + layout.margin
	layout.content.x = layout.rect.x + layout.margin
	layout._column = 0
	layout._row_height = 0
	layout._columns = n_columns
	layout.column_width = max(0, (layout.rect.width - layout.margin * f32(n_columns + 1)) / f32(n_columns))
}
