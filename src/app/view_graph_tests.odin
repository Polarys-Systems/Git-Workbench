package app

import "core:fmt"
import "core:strings"
import "core:testing"

import "../ui"
import "../workspace"

@(test)
history_graph_clips_wide_lanes_and_omits_filtered_connections :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	ctx := ui.init()
	defer ui.destroy(ctx)
	state := Gitaris{ready = true, search = strings.builder_make()}
	defer strings.builder_destroy(&state.search)
	state.model.config = {"keys", "project", "Reader", "reader@example.invalid"}
	append(&state.model.branches, workspace.Branch{name = "main", ref_name = "refs/heads/main"})
	defer delete(state.model.branches)
	state.model.graph.width = 32
	edges := make([dynamic]workspace.Graph_Edge)
	defer delete(edges)
	for i in 0..<32 do append(&edges, workspace.Graph_Edge{{f32(i), 0}, {f32(i), 1}, i})
	append(&edges, workspace.Graph_Edge{{0, 0.5}, {1, 1}, 1})
	for i in 0..<3000 {
		append(&state.model.commits, workspace.Commit{
			message = fmt.tprintf("Commit %04d", i), hash = fmt.tprintf("%040d", i), author = "Reader", date = "2026-10-23",
			graph = {lane = 0, color = 0, edges = edges},
		})
	}
	defer delete(state.model.commits)
	// The commit list viewport inside the main panel (see gitaris_history_ui).
	panel := gitaris_main_rect(1000, 720)
	left, right := panel.x + GITARIS_PAD, panel.x + panel.width - GITARIS_PAD
	top, bottom := panel.y + 14 + 110, panel.y + panel.height - 44 - 6
	scales := [?]f32{1, 2}
	for scale in scales {
		strings.builder_reset(&state.search)
		ctx.windows[2].scroll_offset = {}
		gitaris_test_frame(ctx, &state, scale)
		segments := 0
		for box in ui.elements(ctx) do if box.line_width > 0 && box.line_start != box.line_end do segments += 1
		// Only visible rows (about 11 here, 33 lanes each) create elements, not 3000.
		testing.expectf(t, segments > 0 && ctx.n_boxes < 600, "segments %d boxes %d", segments, ctx.n_boxes)
		gitaris_changes_test_click(t, ctx, &state, nil, "→", 1000, scale)
		testing.expect(t, ctx.windows[2].scroll_offset.x > 0)
		ui.input_mouse_move(ctx, 650 * scale, 450 * scale)
		ui.input_scroll(ctx, 0, -1000)
		gitaris_test_frame(ctx, &state, scale)
		testing.expect(t, ctx.windows[2].scroll_offset.y > 0 && ctx.n_boxes < 600)
		for box in ui.elements(ctx) {
			if box.line_width <= 0 || box.boundary_rect.width <= 0 || box.boundary_rect.height <= 0 do continue
			testing.expect(t, box.actions == {} && !box.draw_background)
			testing.expect(t, box.boundary_rect.x >= left * scale && box.boundary_rect.x + box.boundary_rect.width <= right * scale)
			testing.expect(t, box.boundary_rect.y >= top * scale && box.boundary_rect.y + box.boundary_rect.height <= bottom * scale)
		}
		gitaris_set_field(&state.search, "Commit 0003")
		ctx.windows[2].scroll_offset = {}
		gitaris_test_frame(ctx, &state, scale)
		for box in ui.elements(ctx) do if box.line_width > 0 do testing.expect(t, box.line_start == box.line_end)
	}
}
