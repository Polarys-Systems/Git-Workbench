package app

import "core:testing"

import font_core "../font"

@(test)
theme_fonts_load :: proc(t: ^testing.T) {
	fonts := [?][]byte{THEME_BODY_FONT, THEME_TITLE_FONT, THEME_ICON_FONT, THEME_WELCOME_FONT}
	for data, i in fonts {
		face, loaded := font_core.face_load_from_data(u32(i), data)
		if !testing.expect(t, loaded) do return
		defer font_core.face_destroy(&face)
		glyph, found := font_core.glyph_index(&face, i == 2 ? '\uf401' : 'S')
		testing.expect(t, found)
		testing.expect(t, font_core.get_glyph_info(&face, 28 * 64, glyph).width > 0)
	}
}
