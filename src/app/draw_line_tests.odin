package app

import "core:testing"

import "../ui"

@(test)
line_quads_keep_endpoints_when_clipped_and_need_no_atlas_upload :: proc(t: ^testing.T) {
	batch := text_test_batch(16, 16)
	defer text_test_free_batch(&batch)
	batch.clip_enabled = true
	batch.clip_min, batch.clip_max = {20, 30}, {60, 70}
	testing.expect(t, draw_line(&batch, {10, 10}, {90, 90}, 3, {1, 0, 0, 1}))
	testing.expect(t, len(batch.vertices) == 6 && len(batch.pending_glyph_uploads) == 0)
	for vertex in batch.vertices {
		testing.expect(t, vertex.pos.x >= 20 && vertex.pos.x <= 60 && vertex.pos.y >= 30 && vertex.pos.y <= 70)
		testing.expect(t, vertex.uv == [2]f32{-1.5, 0} && vertex.line == [4]f32{10, 10, 90, 90})
	}
	testing.expect(t, draw_line(&batch, {40, 40}, {40, 40}, 10, {1, 1, 1, 1}))
	testing.expect(t, len(batch.vertices) == 12 && batch.vertices[6].pos == [2]f32{34, 34})
	testing.expect(t, draw_line(&batch, {-10, -10}, {-1, -1}, 2, {1, 1, 1, 1}))
	testing.expect(t, draw_line(&batch, {40, 40}, {40, 40}, 0, {1, 1, 1, 1}) && len(batch.vertices) == 12)
}

@(test)
ui_lines_are_clipped_decorations_in_the_existing_batch :: proc(t: ^testing.T) {
	batch := text_test_batch(16, 16)
	defer text_test_free_batch(&batch)
	ctx := ui.init()
	defer ui.destroy(ctx)
	ui.begin(ctx, 100, 100)
	box := ui.line(ctx, {-10, -10}, {50, 70}, 2, {1, 1, 1, 1})
	testing.expect(t, box != nil && box.actions == {} && !box.draw_background)
	testing.expect(t, box.rect.x == 0 && box.rect.y == 0)
	ui.end(ctx)
	testing.expect(t, draw_ui(&batch, ctx) && len(batch.vertices) == 6)
	testing.expect(t, batch.vertices[0].line == [4]f32{-10, -10, 50, 70})
}
