package app

import "../ui"
import "../workspace"

GITARIS_GRAPH_SPACING :: 20
GITARIS_GRAPH_COLORS :: [?][4]f32{
	{0.24, 0.43, 0.33, 1}, {0.25, 0.43, 0.66, 1},
	{0.65, 0.32, 0.23, 1}, {0.52, 0.35, 0.65, 1},
	{0.58, 0.46, 0.17, 1}, {0.17, 0.50, 0.52, 1},
}

gitaris_graph_row :: proc(ctx: ^ui.UiContext, graph: workspace.Graph_Row, x, y, scale: f32,
	viewport: ui.Rect2d, connections: bool) {
	colors := GITARIS_GRAPH_COLORS
	if connections {
		for edge in graph.edges {
			a := [2]f32{x + edge.from.x * GITARIS_GRAPH_SPACING, y + edge.from.y * 72}
			b := [2]f32{x + edge.to.x * GITARIS_GRAPH_SPACING, y + edge.to.y * 72}
			// Skip offscreen lanes before creating UI elements; wide graphs remain
			// bounded by the viewport just like the virtualized commit rows.
			if max(a.x, b.x) + 3 < viewport.x || min(a.x, b.x) - 3 > viewport.x + viewport.width do continue
			ui.line(ctx, a * scale, b * scale, 2 * scale, colors[edge.color % len(colors)])
		}
	}
	center := [2]f32{x + f32(graph.lane) * GITARIS_GRAPH_SPACING, y + 36}
	if center.x + 7 < viewport.x || center.x - 7 > viewport.x + viewport.width do return
	color := colors[graph.color % len(colors)]
	// Equal endpoints give a round node using the very same rectangle shader.
	ui.line(ctx, center * scale, center * scale, 10 * scale, color)
	ui.line(ctx, center * scale, center * scale, 4 * scale, TEMPLATE_SURFACE)
}
