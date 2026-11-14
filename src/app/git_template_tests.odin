package app

import "core:strings"
import "core:testing"

import font_core "../font"
import "../ui"

@(test)
template_fonts_load :: proc(t: ^testing.T) {
	fonts := [?][]byte{TEMPLATE_BODY_FONT, TEMPLATE_TITLE_FONT, TEMPLATE_ICON_FONT, GITARIS_WELCOME_FONT}
	for data, i in fonts {
		face, loaded := font_core.face_load_from_data(u32(i), data)
		if !testing.expect(t, loaded) do return
		defer font_core.face_destroy(&face)
		glyph, found := font_core.glyph_index(&face, i == 2 ? '\uf401' : 'S')
		testing.expect(t, found)
		testing.expect(t, font_core.get_glyph_info(&face, 28 * 64, glyph).width > 0)
	}
}

@(test)
template_search_filters_scrolled_history :: proc(t: ^testing.T) {
	ctx := ui.init()
	defer ui.destroy(ctx)
	body_face, title_face, icon_face: font_core.Face
	state := Git_Template{search = strings.builder_make()}
	defer strings.builder_destroy(&state.search)
	scales := [?]f32{1, 2}
	for scale in scales {
		strings.builder_reset(&state.search)
		git_template_ui(ctx, &body_face, &title_face, &icon_face, &state, 1000 * scale, 720 * scale, scale)
		ui.input_mouse_move(ctx, 600 * scale, 550 * scale)
		ui.input_scroll(ctx, 0, -20)
		git_template_ui(ctx, &body_face, &title_face, &icon_face, &state, 1000 * scale, 720 * scale, scale)
		testing.expect(t, ctx.windows[0].scroll_offset.y > 0)
		ui.input_mouse_move(ctx, 600 * scale, 420 * scale)
		// Let the previous-frame hit test see the moved pointer before clicking.
		git_template_ui(ctx, &body_face, &title_face, &icon_face, &state, 1000 * scale, 720 * scale, scale)
		ui.input_mouse_button(ctx, .LEFT, true)
		ui.input_text(ctx, "KEYBOARD")
		git_template_ui(ctx, &body_face, &title_face, &icon_face, &state, 1000 * scale, 720 * scale, scale)
		ui.input_mouse_button(ctx, .LEFT, false)
		testing.expect(t, strings.to_string(state.search) == "KEYBOARD")
		testing.expect(t, ctx.windows[0].scroll_offset.y == 0)
		found := false
		for box in ui.elements(ctx) {
			if strings.to_string(box.text) == "Add keyboard navigation" {
				found = true
				testing.expect(t, box.boundary_rect.height > 0)
			}
			testing.expect(t, strings.to_string(box.text) != "Initial commit")
		}
		testing.expect(t, found)
	}
}
