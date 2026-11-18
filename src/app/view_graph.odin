package app

import "../ui"
import "../workspace"

GITARIS_GRAPH_SPACING :: 18
// Commit rows in the history list; the graph spans each row exactly.
GITARIS_ROW_HEIGHT :: 52
GITARIS_GRAPH_COLORS :: [?][4]f32{
	{0.22, 0.22, 0.21, 1}, {0.33, 0.47, 0.75, 1},
	{0.84, 0.42, 0.30, 1}, {0.44, 0.60, 0.16, 1},
	{0.58, 0.40, 0.70, 1}, {0.78, 0.60, 0.10, 1},
}

gitaris_graph_row :: proc(ctx: ^ui.UiContext, graph: workspace.Graph_Row, x, y, scale: f32,
	viewport: ui.Rect2d, connections: bool) {
	colors := GITARIS_GRAPH_COLORS
	if connections {
		for edge in graph.edges {
			a := [2]f32{x + edge.from.x * GITARIS_GRAPH_SPACING, y + edge.from.y * GITARIS_ROW_HEIGHT}
			b := [2]f32{x + edge.to.x * GITARIS_GRAPH_SPACING, y + edge.to.y * GITARIS_ROW_HEIGHT}
			// Skip offscreen lanes before creating UI elements; wide graphs remain
			// bounded by the viewport just like the virtualized commit rows.
			if max(a.x, b.x) + 3 < viewport.x || min(a.x, b.x) - 3 > viewport.x + viewport.width do continue
			ui.line(ctx, a * scale, b * scale, 2 * scale, colors[edge.color % len(colors)])
		}
	}
	center := [2]f32{x + f32(graph.lane) * GITARIS_GRAPH_SPACING, y + GITARIS_ROW_HEIGHT * 0.5}
	if center.x + 7 < viewport.x || center.x - 7 > viewport.x + viewport.width do return
	color := colors[graph.color % len(colors)]
	// Equal endpoints give a round node using the very same rectangle shader.
	ui.line(ctx, center * scale, center * scale, 10 * scale, color)
	ui.line(ctx, center * scale, center * scale, 4 * scale, TEMPLATE_CARD)
}
