package app

// Draws one row of the commit graph (lanes, edges and the commit node).

import "../ui"
import "../workspace"

GRAPH_LANE_SPACING :: 18
// Commit rows in the history list; the graph spans each row exactly.
COMMIT_ROW_HEIGHT :: 52

workbench_graph_row :: proc(ctx: ^ui.UiContext, graph: workspace.Graph_Row, x, y, scale: f32,
	viewport: ui.Rect2d, connections: bool) {
	colors := THEME_GRAPH_COLORS
	if connections {
		for edge in graph.edges {
			a := [2]f32{x + edge.from.x * GRAPH_LANE_SPACING, y + edge.from.y * COMMIT_ROW_HEIGHT}
			b := [2]f32{x + edge.to.x * GRAPH_LANE_SPACING, y + edge.to.y * COMMIT_ROW_HEIGHT}
			// Skip offscreen lanes before creating UI elements; wide graphs remain
			// bounded by the viewport just like the virtualized commit rows.
			if max(a.x, b.x) + 3 < viewport.x || min(a.x, b.x) - 3 > viewport.x + viewport.width do continue
			ui.line(ctx, a * scale, b * scale, 2 * scale, colors[edge.color % len(colors)])
		}
	}
	center := [2]f32{x + f32(graph.lane) * GRAPH_LANE_SPACING, y + COMMIT_ROW_HEIGHT * 0.5}
	if center.x + 7 < viewport.x || center.x - 7 > viewport.x + viewport.width do return
	color := colors[graph.color % len(colors)]
	// Equal endpoints give a round node using the very same rectangle shader.
	ui.line(ctx, center * scale, center * scale, 10 * scale, color)
	ui.line(ctx, center * scale, center * scale, 4 * scale, THEME_CARD)
}
