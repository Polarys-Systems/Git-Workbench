package app

import "core:math"
import "core:mem"
import "core:os"
import "core:testing"

import "../font"
import "../gpu"
import "../ui"

text_test_face :: proc(t: ^testing.T) -> (font.Face, bool) {
	data, err := os.read_entire_file("./assets/fonts/RobotoMono.ttf", context.allocator)
	testing.expect(t, err == nil)
	if err != nil do return {}, false
	defer delete(data)
	face, loaded := font.face_load_from_data(0, data)
	testing.expect(t, loaded)
	if loaded do face.backend = .STB
	return face, loaded
}

text_test_batch :: proc(width, height: u32) -> Text_Batch {
	return Text_Batch{
		glyphs = make(map[Glyph_Cache_Key]Cached_Glyph),
		pending_pixels = make([dynamic]u8, 0, 64),
		pending_glyph_uploads = make([dynamic]Pending_Glyph_Upload),
		vertices = make([dynamic]Text_Vertex),
		atlas_width = width,
		atlas_height = height,
		allocator = context.allocator,
	}
}

text_test_free_batch :: proc(batch: ^Text_Batch) {
	delete(batch.glyphs)
	delete(batch.pending_pixels)
	delete(batch.pending_glyph_uploads)
	delete(batch.vertices)
}

Text_Test_Allocator :: struct {
	backing: mem.Allocator,
	fail: bool,
}

text_test_allocator_proc :: proc(
	data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	state := (^Text_Test_Allocator)(data)
	if state.fail && size > 0 &&
	   (mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed) {
		return nil, .Out_Of_Memory
	}
	return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(test)
text_atlas_placement_is_non_mutating :: proc(t: ^testing.T) {
	batch := Text_Batch{
		atlas_width = 32, atlas_height = 32,
		atlas_cursor_x = 20, atlas_cursor_y = 4, atlas_row_bottom = 16,
	}
	// A shorter glyph must not reduce the height of the current shelf.
	short, fits := atlas_find_space(&batch, 12, 3)
	testing.expect(t, fits && short.cursor_x == 32 && short.cursor_y == 4 && short.row_bottom == 16)
	testing.expect(t, short.rect.offset.x == 20 && short.rect.offset.y == 4)
	wrapped, wraps := atlas_find_space(&batch, 13, 8)
	testing.expect(t, wraps && wrapped.cursor_x == 13 && wrapped.cursor_y == 16 && wrapped.row_bottom == 24)
	testing.expect(t, wrapped.rect.offset.x == 0 && wrapped.rect.offset.y == 16)
	_, too_wide := atlas_find_space(&batch, 33, 1)
	_, too_tall := atlas_find_space(&batch, 13, 17)
	_, empty := atlas_find_space(&batch, 0, 1)
	testing.expect(t, !too_wide && !too_tall && !empty)
	testing.expect(t, batch.atlas_cursor_x == 20 && batch.atlas_cursor_y == 4 && batch.atlas_row_bottom == 16)
}

@(test)
text_cache_rolls_back_failed_allocations_and_retries :: proc(t: ^testing.T) {
	face, loaded := text_test_face(t)
	if !loaded do return
	defer font.face_destroy(&face)
	idx, _ := font.glyph_index(&face, 'A')
	// Fail each independently allocated queue/map. The bitmap and padded
	// temporary continue using the regular allocator to reach these paths.
	for target in 0..<3 {
		state := Text_Test_Allocator{backing = context.allocator}
		allocator := mem.Allocator{procedure = text_test_allocator_proc, data = &state}
		batch := text_test_batch(64, 64)
		defer text_test_free_batch(&batch)
		switch target {
		case 0:
			delete(batch.pending_pixels)
			batch.pending_pixels = make([dynamic]u8, 0, 0, allocator)
		case 1:
			delete(batch.pending_glyph_uploads)
			batch.pending_glyph_uploads = make([dynamic]Pending_Glyph_Upload, 0, 0, allocator)
		case 2:
			delete(batch.glyphs)
			batch.glyphs = make(map[Glyph_Cache_Key]Cached_Glyph, allocator)
		}
		state.fail = true
		_, cached := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
		testing.expect(t, !cached)
		testing.expect(t, len(batch.glyphs) == 0)
		testing.expect(t, len(batch.pending_pixels) == 0 && len(batch.pending_glyph_uploads) == 0)
		testing.expect(t, batch.atlas_cursor_x == 0 && batch.atlas_cursor_y == 0 && batch.atlas_row_bottom == 0)

		state.fail = false
		glyph, retried := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
		testing.expect(t, retried && glyph.width > 0)
		testing.expect(t, len(batch.glyphs) == 1 && len(batch.pending_glyph_uploads) == 1)
		testing.expect(t, len(batch.pending_pixels) > 0 && batch.atlas_cursor_x > 0)
		// A hit must not allocate or enqueue another upload.
		state.fail = true
		again, hit := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
		testing.expect(t, hit && again == glyph)
		testing.expect(t, len(batch.pending_glyph_uploads) == 1)
		state.fail = false
	}
}

@(test)
text_cache_appends_padded_bitmap_once :: proc(t: ^testing.T) {
	face, loaded := text_test_face(t)
	if !loaded do return
	defer font.face_destroy(&face)
	batch := text_test_batch(64, 64)
	defer text_test_free_batch(&batch)
	idx, found := font.glyph_index(&face, 'A')
	testing.expect(t, found)
	glyph, ok := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
	testing.expect(t, ok)
	if !ok do return
	testing.expect(t, len(batch.pending_glyph_uploads) == 1)
	upload := batch.pending_glyph_uploads[0]
	testing.expect(t, upload.data_offset == 0)
	testing.expect(t, upload.rect.offset.x == 0 && upload.rect.offset.y == 0)
	testing.expect(t, upload.data_size == int((glyph.width + 2) * (glyph.height + 2)))
	testing.expect(t, len(batch.pending_pixels) == upload.data_size)
	testing.expect(t, glyph.uv_min == [2]f32{1.0 / 64, 1.0 / 64})
	testing.expect(t, glyph.uv_max == [2]f32{f32(1 + glyph.width) / 64, f32(1 + glyph.height) / 64})
	bitmap, rasterized := font.rasterize_glyph(&face, 16 * 64, idx, context.allocator)
	defer delete(bitmap.pixels)
	testing.expect(t, rasterized)
	width, height := int(upload.rect.extent.width), int(upload.rect.extent.height)
	for y in 0..<height {
		for x in 0..<width {
			expected: byte
			if x > 0 && x < width - 1 && y > 0 && y < height - 1 {
				expected = bitmap.pixels[(y - 1) * int(bitmap.width) + x - 1]
			}
			testing.expect(t, batch.pending_pixels[y * width + x] == expected)
		}
	}
	cursor := [3]u32{batch.atlas_cursor_x, batch.atlas_cursor_y, batch.atlas_row_bottom}
	again, cached := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
	testing.expect(t, cached && again == glyph)
	testing.expect(t, len(batch.glyphs) == 1)
	testing.expect(t, len(batch.pending_glyph_uploads) == 1)
	testing.expect(t, len(batch.pending_pixels) == upload.data_size)
	testing.expect(t, cursor == [3]u32{batch.atlas_cursor_x, batch.atlas_cursor_y, batch.atlas_row_bottom})
}

@(test)
text_cache_distinguishes_faces_and_sizes :: proc(t: ^testing.T) {
	face_a, loaded_a := text_test_face(t)
	if !loaded_a do return
	defer font.face_destroy(&face_a)
	face_b, loaded_b := text_test_face(t)
	if !loaded_b do return
	defer font.face_destroy(&face_b)
	batch := text_test_batch(128, 128)
	defer text_test_free_batch(&batch)
	idx, _ := font.glyph_index(&face_a, 'A')
	a, ok_a := get_or_cache_glyph(&batch, &face_a, 16 * 64, idx)
	b, ok_b := get_or_cache_glyph(&batch, &face_b, 16 * 64, idx)
	c, ok_c := get_or_cache_glyph(&batch, &face_a, 24 * 64, idx)
	testing.expect(t, ok_a && ok_b && ok_c)
	testing.expect(t, len(batch.glyphs) == 3)
	testing.expect(t, len(batch.pending_glyph_uploads) == 3)
	testing.expect(t, a.uv_min != b.uv_min && b.uv_min != c.uv_min)
}

@(test)
text_cache_spaces_need_no_texture_upload :: proc(t: ^testing.T) {
	face, loaded := text_test_face(t)
	if !loaded do return
	defer font.face_destroy(&face)
	batch := text_test_batch(64, 64)
	defer text_test_free_batch(&batch)
	idx, _ := font.glyph_index(&face, ' ')
	glyph, ok := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
	testing.expect(t, ok && glyph.width == 0 && glyph.height == 0 && glyph.advance_x > 0)
	_, cached := get_or_cache_glyph(&batch, &face, 16 * 64, idx)
	testing.expect(t, cached)
	testing.expect(t, len(batch.glyphs) == 1)
	testing.expect(t, len(batch.pending_pixels) == 0 && len(batch.pending_glyph_uploads) == 0)
	testing.expect(t, batch.atlas_cursor_x == 0 && batch.atlas_row_bottom == 0)
}

@(test)
text_cache_wraps_and_rolls_back_when_full :: proc(t: ^testing.T) {
	face_a, loaded_a := text_test_face(t)
	if !loaded_a do return
	defer font.face_destroy(&face_a)
	face_b, loaded_b := text_test_face(t)
	if !loaded_b do return
	defer font.face_destroy(&face_b)
	face_c, loaded_c := text_test_face(t)
	if !loaded_c do return
	defer font.face_destroy(&face_c)
	idx, _ := font.glyph_index(&face_a, 'A')
	info := font.get_glyph_info(&face_a, 16 * 64, idx)
	width, height := u32(info.width + 2), u32(info.height + 2)
	batch := text_test_batch(width, height * 2)
	defer text_test_free_batch(&batch)
	_, ok_a := get_or_cache_glyph(&batch, &face_a, 16 * 64, idx)
	_, ok_b := get_or_cache_glyph(&batch, &face_b, 16 * 64, idx)
	testing.expect(t, ok_a && ok_b)
	testing.expect(t, batch.atlas_cursor_y == height && batch.atlas_row_bottom == height * 2)
	testing.expect(t, batch.pending_glyph_uploads[1].rect.offset.y == i32(height))
	data_len := len(batch.pending_pixels)
	_, ok_c := get_or_cache_glyph(&batch, &face_c, 16 * 64, idx)
	testing.expect(t, !ok_c)
	testing.expect(t, len(batch.glyphs) == 2)
	testing.expect(t, len(batch.pending_glyph_uploads) == 2 && len(batch.pending_pixels) == data_len)
	testing.expect(t, batch.atlas_cursor_y == height && batch.atlas_row_bottom == height * 2)
	_, retry := get_or_cache_glyph(&batch, &face_c, 16 * 64, idx)
	testing.expect(t, !retry)
}

@(test)
text_draw_builds_quads_with_spaces_and_newlines :: proc(t: ^testing.T) {
	face, loaded := text_test_face(t)
	if !loaded do return
	defer font.face_destroy(&face)
	batch := text_test_batch(128, 128)
	defer text_test_free_batch(&batch)
	color := [4]f32{0.2, 0.4, 0.6, 0.8}
	ok := draw_text(&batch, &face, "A A\r\nA", {10, 20}, color, 16)
	testing.expect(t, ok)
	if !ok do return
	testing.expect(t, len(batch.vertices) == 18)
	testing.expect(t, len(batch.pending_glyph_uploads) == 1)
	idx_a, _ := font.glyph_index(&face, 'A')
	idx_space, _ := font.glyph_index(&face, ' ')
	a := font.get_glyph_info(&face, 16 * 64, idx_a)
	space := font.get_glyph_info(&face, 16 * 64, idx_space)
	metrics := font.line_metrics(&face, 16 * 64)
	testing.expect(t, batch.vertices[0].pos == [2]f32{math.round(10 + a.xoff), math.round(20 + metrics.ascent + a.yoff)})
	testing.expect(t, batch.vertices[6].pos[0] == math.round(10 + a.advance_x + space.advance_x + a.xoff))
	testing.expect(t, batch.vertices[12].pos[0] == batch.vertices[0].pos[0])
	testing.expect(t, batch.vertices[12].pos[1] == math.round(20 + metrics.ascent + metrics.line_height + a.yoff))
	for vertex in batch.vertices do testing.expect(t, vertex.color == color)
	testing.expect(t, batch.vertices[0].uv == batch.vertices[6].uv)
	testing.expect(t, batch.vertices[0] == batch.vertices[3])
	testing.expect(t, batch.vertices[2] == batch.vertices[4])
}

@(test)
text_draw_snaps_quads_without_accumulating_advance_error :: proc(t: ^testing.T) {
	face, loaded := text_test_face(t)
	if !loaded do return
	defer font.face_destroy(&face)
	batch := text_test_batch(512, 512)
	defer text_test_free_batch(&batch)
	idx, _ := font.glyph_index(&face, 'A')
	sizes := [?]u32{10, 12, 14, 16, 18, 20, 24, 32, 48}
	positions := [?][2]f32{{10.25, 20.375}, {-7.25, -4.375}}
	text := "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	for size in sizes {
		info := font.get_glyph_info(&face, size * 64, idx)
		metrics := font.line_metrics(&face, size * 64)
		for pos in positions {
			clear(&batch.vertices)
			ok := draw_text(&batch, &face, text, pos, {1, 1, 1, 1}, f32(size))
			testing.expect(t, ok)
			if !ok do return
			testing.expect(t, len(batch.vertices) == len(text) * 6)
			pen := [2]f32{pos[0], pos[1] + metrics.ascent}
			for i in 0..<len(text) {
				p0 := batch.vertices[i * 6].pos
				p1 := batch.vertices[i * 6 + 2].pos
				testing.expect(t, p0 == [2]f32{math.round(pen[0] + info.xoff), math.round(pen[1] + info.yoff)})
				// Snapping must not resize the bitmap's quad or its UV rectangle.
				testing.expect(t, p1 - p0 == [2]f32{f32(info.width), f32(info.height)})
				testing.expect(t, batch.vertices[i * 6].uv == batch.vertices[0].uv)
				pen[0] += info.advance_x
			}
			for vertex in batch.vertices {
				testing.expect(t, vertex.pos[0] == math.round(vertex.pos[0]))
				testing.expect(t, vertex.pos[1] == math.round(vertex.pos[1]))
			}
		}
	}
	testing.expect(t, len(batch.pending_glyph_uploads) == len(sizes))
}

@(test)
text_draw_rejects_invalid_input_and_rolls_back_geometry :: proc(t: ^testing.T) {
	face, loaded := text_test_face(t)
	if !loaded do return
	defer font.face_destroy(&face)
	batch := text_test_batch(128, 128)
	defer text_test_free_batch(&batch)
	testing.expect(t, !draw_text(&batch, &face, "A", {}, {}, 0))
	testing.expect(t, !draw_text(&batch, &face, "A", {}, {}, math.inf_f32(1)))
	first_vertex := MAX_TEXT_VERTEX_BYTES / size_of(Text_Vertex) - 12
	resize(&batch.vertices, first_vertex)
	testing.expect(t, !draw_text(&batch, &face, "AAA", {}, {1, 1, 1, 1}, 16))
	testing.expect(t, len(batch.vertices) == first_vertex)
	testing.expect(t, len(batch.pending_glyph_uploads) == 1)
	testing.expect(t, text_prepare_render(&batch) == gpu.Result.ERROR_INVALID_ARGUMENT)
	testing.expect(t, len(batch.vertices) == first_vertex)
}

@(test)
draw_quad_clips_uvs_and_gradient :: proc(t: ^testing.T) {
	batch := text_test_batch(16, 16)
	defer text_test_free_batch(&batch)
	batch.clip_enabled = true
	batch.clip_min, batch.clip_max = {25, 40}, {75, 80}
	queued := append_draw_quad(&batch, {0, 0}, {100, 100}, {0, 0}, {1, 1}, {0, 0, 0, 1}, {1, 1, 1, 1})
	testing.expect(t, queued && len(batch.vertices) == 6)
	testing.expect(t, batch.vertices[0] == Text_Vertex{{25, 40}, {0.25, 0.4}, {0.4, 0.4, 0.4, 1}, {}})
	testing.expect(t, batch.vertices[2] == Text_Vertex{{75, 80}, {0.75, 0.8}, {0.8, 0.8, 0.8, 1}, {}})
	testing.expect(t, append_draw_quad(&batch, {0, 0}, {10, 10}, {}, {}, {}, {}))
	testing.expect(t, append_draw_quad(&batch, {25, 40}, {25, 80}, {}, {}, {}, {}))
	testing.expect(t, len(batch.vertices) == 6)
}

@(test)
draw_rect_reuses_white_atlas_texel :: proc(t: ^testing.T) {
	batch := text_test_batch(16, 16)
	defer text_test_free_batch(&batch)
	for _ in 0..<10 {
		testing.expect(t, draw_rect(&batch, {10, 20, 100, 40}, {1, 0, 0, 1}, {0, 0, 1, 1}))
	}
	testing.expect(t, len(batch.vertices) == 60 && len(batch.pending_glyph_uploads) == 1)
	testing.expect(t, len(batch.pending_pixels) == 9)
	for pixel, i in batch.pending_pixels do testing.expect(t, pixel == (i == 4 ? u8(255) : 0))
	for vertex in batch.vertices do testing.expect(t, vertex.uv == [2]f32{1.5 / 16, 1.5 / 16})
}

@(test)
draw_ui_uses_themed_border_and_focus_colors :: proc(t: ^testing.T) {
	batch := text_test_batch(16, 16)
	defer text_test_free_batch(&batch)
	ctx := ui.init()
	defer ui.destroy(ctx)
	style := ui.default_style
	style.border = 1
	style.border_color = {0.86, 0.86, 0.85, 1}
	style.focus_color = {0.12, 0.45, 0.79, 1}
	style.color_top, style.color_bottom = {1, 1, 1, 1}, {1, 1, 1, 1}
	ui.begin(ctx, 100, 100)
	ui.style_push(ctx, style)
	box := ui.new_box(ctx, "", {}, {}, {10, 10, 40, 30})
	ui.style_pop(ctx)
	ui.end(ctx)
	focus_states := [?]bool{false, true}
	for focused in focus_states {
		box.focused = focused
		resize(&batch.vertices, 0)
		if !testing.expect(t, draw_ui(&batch, ctx)) do return
		if !testing.expect(t, len(batch.vertices) == 12) do return
		testing.expect(t, batch.vertices[0].color == (focused ? style.focus_color : style.border_color))
		testing.expect(t, batch.vertices[6].color == style.color_top)
	}
}
