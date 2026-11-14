package font

import "core:os"
import "core:testing"

test_stb_face :: proc(t: ^testing.T, path: string) {
	data, read_error := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_error == nil)
	if read_error != nil {
		return
	}
	defer delete(data)

	face, loaded := face_load_from_data(0, data)
	testing.expect(t, loaded)
	if !loaded {
		return
	}
	defer face_destroy(&face)
	testing.expect(t, face.stb_valid)
	if !face.stb_valid {
		return
	}
	face.backend = .STB

	glyph, found := glyph_index(&face, 'A')
	testing.expect(t, found)
	if !found {
		return
	}
	advance, measured := glyph_advance(&face, glyph, 12 * 64)
	testing.expect(t, measured)
	testing.expect(t, advance > 0)
	metrics := line_metrics(&face, 12 * 64)
	testing.expect(t, metrics.line_height > 0)
	bitmap, rasterized := rasterize_glyph(&face, 12 * 64, glyph)
	testing.expect(t, rasterized)
	testing.expect(t, bitmap.width > 0 && bitmap.height > 0)
	info := get_glyph_info(&face, 12 * 64, glyph)
	testing.expect(t, bitmap.info == info)
	testing.expect(t, info.advance_x == advance)
	testing.expect(t, info.xoff2 - info.xoff == f32(info.width))
	testing.expect(t, info.yoff2 - info.yoff == f32(info.height))

	// Bounds-only queries must agree with rasterization at different sizes,
	// including empty glyphs such as spaces.
	runes := [?]rune{'A', 'g', ' '}
	sizes := [?]u32{8 * 64, 24 * 64}
	for r in runes {
		idx, has_glyph := glyph_index(&face, r)
		testing.expect(t, has_glyph)
		if !has_glyph {
			continue
		}
		for size in sizes {
			glyph_info := get_glyph_info(&face, size, idx)
			glyph_bitmap, ok := rasterize_glyph(&face, size, idx, context.allocator)
			defer delete(glyph_bitmap.pixels)
			testing.expect(t, ok)
			testing.expect(t, glyph_bitmap.info == glyph_info)
			testing.expect(t, len(glyph_bitmap.pixels) == int(glyph_info.width * glyph_info.height))
			if r == ' ' {
				testing.expect(t, glyph_info.width == 0 && glyph_info.height == 0)
				testing.expect(t, glyph_info.advance_x > 0)
			}
		}
	}
	testing.expect(t, get_glyph_info(&face, 12 * 64, 0) == Glyph_Info{})
	testing.expect(t, get_glyph_info(&face, 12 * 64, -1) == Glyph_Info{})
}

@(test)
font_load_from_file_owns_data :: proc(t: ^testing.T) {
	face, loaded := face_load_from_file(7, "./assets/fonts/RobotoMono.ttf")
	testing.expect(t, loaded)
	if !loaded do return
	defer face_destroy(&face)
	testing.expect(t, face.id == 7 && face.path == "./assets/fonts/RobotoMono.ttf")
	testing.expect(t, len(face.data) > 0 && face.stb_valid)
	face.backend = .STB
	idx, found := glyph_index(&face, 'A')
	testing.expect(t, found)
	testing.expect(t, get_glyph_info(&face, 16 * 64, idx).width > 0)
	_, missing := face_load_from_file(0, "./assets/fonts/missing-font-for-test.ttf")
	testing.expect(t, !missing)
}

@(test)
font_stb_glyph_info_invalid_face :: proc(t: ^testing.T) {
	testing.expect(t, get_glyph_info(nil, 12 * 64, 1) == Glyph_Info{})
	face: Face
	testing.expect(t, get_glyph_info(&face, 12 * 64, 1) == Glyph_Info{})
}

@(test)
font_stb_supports_shipped_formats :: proc(t: ^testing.T) {
	test_stb_face(t, "./assets/fonts/RobotoMono.ttf")
	test_stb_face(
		t,
		"./assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Regular.otf",
	)
}
