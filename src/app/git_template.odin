package app

import "core:fmt"
import "core:strings"

import font_core "../font"
import "../ui"

// Fonts are embedded at compile time so the executable does not depend on the
// working directory. #load paths are relative to this source file.
TEMPLATE_BODY_FONT :: #load("../../assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Regular.otf")
TEMPLATE_TITLE_FONT :: #load("../../assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Bold.otf")
TEMPLATE_ICON_FONT :: #load("../../assets/fonts/SymbolsNerdFontMono-Regular.ttf")

TEMPLATE_BACKGROUND :: [4]f32{0.72, 0.74, 0.72, 1}
TEMPLATE_SURFACE :: [4]f32{0.84, 0.86, 0.84, 1}
TEMPLATE_CARD :: [4]f32{0.89, 0.90, 0.88, 1}
TEMPLATE_TEXT :: [4]f32{0.15, 0.17, 0.16, 1}
TEMPLATE_MUTED :: [4]f32{0.40, 0.44, 0.41, 1}
TEMPLATE_LINE :: [4]f32{0.76, 0.79, 0.76, 1}
TEMPLATE_LIGHT :: [4]f32{0.94, 0.96, 0.93, 1}
TEMPLATE_ACCENT :: [4]f32{0.28, 0.43, 0.35, 1}
TEMPLATE_SELECTED :: [4]f32{0.79, 0.85, 0.81, 1}
TEMPLATE_DARK :: [4]f32{0.15, 0.17, 0.16, 1}

Git_Template :: struct {
	search: strings.Builder,
}

Template_Commit :: struct {
	message, hash, time: string,
}

// Deliberately sample data: this is a visual template, not repository state.
TEMPLATE_COMMITS :: [?]Template_Commit{
	{"Refine the workspace layout", "a8c42f1", "2 hours ago"},
	{"Add keyboard navigation", "e31b9d4", "4 hours ago"},
	{"Polish text rendering", "7f2d6a0", "Yesterday"},
	{"Keep scrolling smooth", "b6e1c83", "Yesterday"},
	{"Introduce the UI components", "3d9a72e", "2 days ago"},
	{"Set up the font atlas", "c04f8b2", "3 days ago"},
	{"Create the application window", "91e5d6c", "4 days ago"},
	{"Initial commit", "5ab20d9", "5 days ago"},
}

template_rect :: proc(rect: ui.Rect2d, scale: f32) -> ui.Rect2d {
	return {rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale}
}

template_label :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, rect: ui.Rect2d,
	size: f32, color: [4]f32, scale: f32, align := ui.UiAlignments{.NONE}) {
	style := ui.default_style
	style.font_id = ui.UiFont(uintptr(face))
	style.font_size = size * scale
	style.text_color = color
	style.padding = 0
	ui.style_push(ctx, style)
	ui.label(ctx, text, template_rect(rect, scale), align)
	ui.style_pop(ctx)
}

template_box :: proc(ctx: ^ui.UiContext, rect: ui.Rect2d, color: [4]f32, radius, scale: f32,
	border: f32 = 0, bottom: [4]f32 = {}) {
	style := ui.default_style
	style.color_top = color
	style.color_bottom = bottom.a > 0 ? bottom : color
	style.radius = radius * scale
	style.border = border * scale
	style.border_color = TEMPLATE_LIGHT
	ui.style_push(ctx, style)
	ui.new_box(ctx, "", {}, {}, template_rect(rect, scale))
	ui.style_pop(ctx)
}

template_panel :: proc(ctx: ^ui.UiContext, rect: ui.Rect2d, color: [4]f32, radius, scale: f32) {
	// A few translucent layers give the quiet, raised edges of the reference.
	for i := 4; i > 0; i -= 1 {
		d := f32(i) * 2
		template_box(ctx, {rect.x - d, rect.y - d * 0.25, rect.width + d * 2, rect.height + d * 2},
			{0.16, 0.20, 0.17, 0.025}, radius + d, scale)
	}
	template_box(ctx, rect, color, radius, scale, 1,
		{color.r - 0.025, color.g - 0.025, color.b - 0.025, color.a})
}

git_template_ui :: proc(ctx: ^ui.UiContext, face, title, icons: ^font_core.Face,
	state: ^Git_Template, width, height, scale: f32) {
	w, h := width / scale, height / scale
	side_x: f32 = 136
	side_w: f32 = 222
	main_x: f32 = 390
	x := main_x + 32
	cw := w - x - 58

	ui.begin(ctx, width, height)
	{
		base := ui.default_style
		base.color_top, base.color_bottom = TEMPLATE_BACKGROUND, TEMPLATE_BACKGROUND
		base.radius = 0
		ui.style_push(ctx, base)
		{
			ui.begin_window(ctx, {0, 0, width, height}, "git-workspace")
			template_panel(ctx, {24, 24, 72, h - 48}, TEMPLATE_SURFACE, 24, scale)
			template_panel(ctx, {112, 24, w - 136, h - 48}, TEMPLATE_SURFACE, 24, scale)
			template_box(ctx, {main_x, 34, w - main_x - 34, h - 68}, {0.86, 0.88, 0.85, 1}, 19, scale, 1)

			// Narrow charcoal rail; the other destinations remain visual placeholders.
			template_panel(ctx, {34, 36, 52, h - 132}, TEMPLATE_DARK, 17, scale)
			template_label(ctx, icons, "\uf1d3", {40, 52, 40, 40}, 26, TEMPLATE_LIGHT, scale, {.CENTER})
			template_box(ctx, {47, 112, 26, 1}, {0.32, 0.35, 0.32, 1}, 0, scale)
			template_box(ctx, {40, 137, 40, 42}, {0.32, 0.36, 0.32, 1}, 10, scale, 0,
				{0.25, 0.28, 0.25, 1})
			rail_icons := [?]string{"\uf401", "\uf126", "\uf1da", "\uf0c2"}
			for icon, i in rail_icons {
				template_label(ctx, icons, icon, {40, 138 + f32(i) * 62, 40, 40}, 20,
					i == 0 ? TEMPLATE_LIGHT : [4]f32{0.64, 0.68, 0.64, 1}, scale, {.CENTER})
			}
			template_label(ctx, face, "P", {40, h - 146, 40, 28}, 13, {0.57, 0.62, 0.58, 1}, scale, {.CENTER})
			template_box(ctx, {40, h - 79, 40, 40}, TEMPLATE_DARK, 13, scale)
			template_label(ctx, icons, "\uf013", {40, h - 79, 40, 40}, 20, TEMPLATE_LIGHT, scale, {.CENTER})

			// Repository sidebar.
			dots := [?][4]f32{{0.75, 0.53, 0.52, 1}, {0.78, 0.71, 0.48, 1}, {0.49, 0.68, 0.57, 1}}
			for color, i in dots do template_box(ctx, {side_x + f32(i) * 19, 47, 9, 9}, color, 5, scale)
			template_panel(ctx, {side_x, 88, 42, 42}, TEMPLATE_DARK, 21, scale)
			template_label(ctx, icons, "\uf126", {side_x, 88, 42, 42}, 20, TEMPLATE_LIGHT, scale, {.CENTER})
			template_label(ctx, title, "Polaris", {side_x + 56, 87, 160, 28}, 23, TEMPLATE_TEXT, scale)
			template_label(ctx, face, "Local workspace", {side_x + 56, 115, 160, 20}, 13, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "Repository", {side_x, 167, side_w, 24}, 13, TEMPLATE_MUTED, scale)
			template_label(ctx, icons, "\uf07b", {side_x + 2, 204, 24, 28}, 18, TEMPLATE_MUTED, scale)
			template_label(ctx, title, "Git-Workbench", {side_x + 36, 200, side_w - 36, 26}, 16, TEMPLATE_TEXT, scale)
			template_label(ctx, face, "~/devel/Git-Workbench", {side_x + 36, 226, side_w - 36, 20}, 12, TEMPLATE_MUTED, scale)
			template_panel(ctx, {side_x - 4, 267, side_w + 8, 44}, TEMPLATE_SELECTED, 10, scale)
			template_label(ctx, icons, "\uf1da", {side_x + 10, 267, 24, 44}, 17, TEMPLATE_TEXT, scale)
			template_label(ctx, title, "History", {side_x + 46, 267, 124, 44}, 16, TEMPLATE_TEXT, scale)
			template_box(ctx, {side_x + side_w - 30, 278, 24, 24}, {0.88, 0.92, 0.88, 1}, 12, scale)
			template_label(ctx, face, "8", {side_x + side_w - 30, 278, 24, 24}, 12, TEMPLATE_MUTED, scale, {.CENTER})
			template_label(ctx, icons, "\uf192", {side_x + 10, 318, 24, 40}, 17, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "Working tree", {side_x + 46, 318, 144, 40}, 16, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "3", {side_x + side_w - 30, 318, 24, 40}, 12, TEMPLATE_MUTED, scale, {.CENTER})
			template_box(ctx, {side_x, 378, side_w, 1}, TEMPLATE_LINE, 0, scale)
			template_label(ctx, face, "Branches", {side_x, 397, side_w, 24}, 13, TEMPLATE_MUTED, scale)
			template_label(ctx, icons, "\uf126", {side_x + 10, 432, 24, 34}, 16, TEMPLATE_ACCENT, scale)
			template_label(ctx, title, "main", {side_x + 46, 432, 110, 34}, 16, TEMPLATE_TEXT, scale)
			template_box(ctx, {side_x + side_w - 52, 438, 52, 23}, TEMPLATE_SELECTED, 6, scale)
			template_label(ctx, face, "HEAD", {side_x + side_w - 52, 438, 52, 23}, 10, TEMPLATE_ACCENT, scale, {.CENTER})
			template_label(ctx, icons, "\uf126", {side_x + 10, 475, 24, 34}, 16, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "feature / ui", {side_x + 46, 475, 160, 34}, 15, TEMPLATE_MUTED, scale)
			template_box(ctx, {side_x, 533, side_w, 1}, TEMPLATE_LINE, 0, scale)
			template_label(ctx, face, "Remotes", {side_x, 552, side_w, 24}, 13, TEMPLATE_MUTED, scale)
			template_label(ctx, icons, "\uf0c2", {side_x + 10, 585, 24, 34}, 16, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "origin", {side_x + 46, 585, 160, 34}, 15, TEMPLATE_MUTED, scale)
			template_box(ctx, {side_x + 2, h - 65, 6, 6}, TEMPLATE_ACCENT, 3, scale)
			template_label(ctx, face, "Local repository", {side_x + 20, h - 76, side_w - 20, 28}, 12, TEMPLATE_MUTED, scale)

			// One main view, with two small context cards and the commit history.
			template_label(ctx, face, "REPOSITORY  /  OVERVIEW", {x, 67, cw - 140, 24}, 11, TEMPLATE_MUTED, scale)
			template_box(ctx, {x + cw - 120, 65, 120, 28}, TEMPLATE_SURFACE, 14, scale)
			template_label(ctx, face, "Template preview", {x + cw - 120, 65, 120, 28}, 11, TEMPLATE_MUTED, scale, {.CENTER})
			template_label(ctx, title, "Git-Workbench", {x, 101, cw, 49}, 34, TEMPLATE_TEXT, scale)
			template_label(ctx, face, "A little clarity for your code.", {x, 152, cw, 26}, 16, TEMPLATE_MUTED, scale)
			card_w := (cw - 18) * 0.5
			template_panel(ctx, {x, 204, card_w, 123}, TEMPLATE_CARD, 14, scale)
			template_label(ctx, face, "Working tree", {x + 20, 218, card_w - 40, 26}, 15, TEMPLATE_TEXT, scale)
			template_label(ctx, face, "03", {x + 18, 247, 78, 60}, 48, TEMPLATE_TEXT, scale)
			template_label(ctx, face, "files changed", {x + 99, 264, card_w - 115, 28}, 13, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "2 modified  /  1 added", {x + 20, 303, card_w - 40, 18}, 11, TEMPLATE_MUTED, scale)
			branch_x := x + card_w + 18
			template_panel(ctx, {branch_x, 204, card_w, 123}, TEMPLATE_CARD, 14, scale)
			template_label(ctx, face, "Current branch", {branch_x + 20, 218, card_w - 40, 26}, 15, TEMPLATE_TEXT, scale)
			template_label(ctx, icons, "\uf126", {branch_x + 20, 254, 28, 40}, 25, TEMPLATE_ACCENT, scale)
			template_label(ctx, face, "main", {branch_x + 62, 247, card_w - 80, 50}, 33, TEMPLATE_TEXT, scale)
			template_label(ctx, face, "Up to date with origin/main", {branch_x + 20, 303, card_w - 40, 18}, 11, TEMPLATE_ACCENT, scale)
			template_label(ctx, title, "Commit history", {x, 352, cw, 36}, 23, TEMPLATE_TEXT, scale)

			search_style := base
			search_style.font_id = ui.UiFont(uintptr(face))
			search_style.font_size = 14 * scale
			search_style.padding = 12 * scale
			search_style.radius = 9 * scale
			search_style.border = scale
			search_style.border_color = TEMPLATE_LINE
			search_style.focus_color = TEMPLATE_ACCENT
			search_style.text_color = TEMPLATE_TEXT
			search_style.color_top, search_style.color_bottom = TEMPLATE_SURFACE, TEMPLATE_SURFACE
			search_style.hover_color, search_style.active_color = TEMPLATE_SURFACE, TEMPLATE_SURFACE
			template_label(ctx, icons, "\uf002", {x, 399, 28, 40}, 18, TEMPLATE_MUTED, scale)
			ui.style_push(ctx, search_style)
			if ui.input_box(ctx, "commit-search", &state.search, template_rect({x + 36, 399, cw - 36, 40}, scale)) == .MODIFIED {
				ctx.windows[ctx.window_index].scroll_offset = {}
			}
			ui.style_pop(ctx)
			if len(state.search.buf) == 0 {
				template_label(ctx, face, "Search commits...", {x + 49, 399, cw - 62, 40}, 14, TEMPLATE_MUTED, scale)
			}

			template_panel(ctx, {x, 457, cw, h - 537}, TEMPLATE_CARD, 14, scale)
			template_label(ctx, face, "COMMIT", {x + 24, 469, cw - 150, 24}, 10, TEMPLATE_MUTED, scale)
			template_label(ctx, face, "REVISION", {x + cw - 100, 469, 76, 24}, 10, TEMPLATE_MUTED, scale, {.RIGHT})
			template_box(ctx, {x + 18, 503, cw - 36, 1}, TEMPLATE_LINE, 0, scale)
			viewport := ui.Rect2d{x + 12, 510, cw - 24, h - 610}
			layout := ui.default_layout
			layout.rect = template_rect(viewport, scale)
			layout.margin = 0
			layout.box_size = {viewport.width * scale, 62 * scale}
			ui.layout_push(ctx, layout)
			ui.layout_begin_scroll(ctx, false)
			matches := 0
			query := strings.to_lower(strings.trim_space(strings.to_string(state.search)), context.temp_allocator)
			for commit, i in TEMPLATE_COMMITS {
				if query != "" && !strings.contains(strings.to_lower(commit.message, context.temp_allocator), query) &&
					!strings.contains(commit.hash, query) {
					continue
				}
				// An automatic layout row establishes scrolling; its children use that position.
				row := ui.label(ctx, "", {-1, -1, -1, 62 * scale}).rect
				ry := row.y / scale
				if i == 0 do template_box(ctx, {viewport.x, ry + 2, viewport.width, 58}, TEMPLATE_SELECTED, 8, scale)
				template_box(ctx, {x + 31, ry, 2, 62}, TEMPLATE_LINE, 0, scale)
				template_box(ctx, {x + 27, ry + 24, 10, 10}, i == 0 ? TEMPLATE_ACCENT : TEMPLATE_MUTED, 5, scale)
				template_box(ctx, {x + 30, ry + 27, 4, 4}, TEMPLATE_CARD, 2, scale)
				template_label(ctx, face, commit.message, {x + 52, ry + 7, cw - 164, 26}, 15, TEMPLATE_TEXT, scale)
				template_label(ctx, face, fmt.tprintf("You  /  %s", commit.time), {x + 52, ry + 32, cw - 164, 20}, 11, TEMPLATE_MUTED, scale)
				template_label(ctx, face, commit.hash, {x + cw - 100, ry + 16, 76, 26}, 12, TEMPLATE_MUTED, scale, {.RIGHT})
				matches += 1
			}
			if matches == 0 {
				template_label(ctx, face, "No matching commits", {viewport.x, viewport.y + 20, viewport.width, 32}, 16, TEMPLATE_TEXT, scale, {.CENTER})
			}
			ui.layout_end_scroll(ctx, false)
			ui.layout_pop(ctx)
			scroll := &ctx.windows[ctx.window_index]
			if scroll.content_size.y > viewport.height * scale {
				thumb := max(22, viewport.height * viewport.height * scale / scroll.content_size.y)
				progress := scroll.scroll_offset.y / (scroll.content_size.y - viewport.height * scale)
				template_box(ctx, {x + cw - 7, viewport.y + progress * (viewport.height - thumb), 3, thumb}, TEMPLATE_LINE, 2, scale)
			}
			template_label(ctx, face, "Sample repository data", {x, h - 70, cw - 100, 24}, 11, TEMPLATE_MUTED, scale)
			template_label(ctx, face, fmt.tprintf("%d commits", matches), {x + cw - 100, h - 70, 100, 24}, 11, TEMPLATE_MUTED, scale, {.RIGHT})
		}
		ui.style_pop(ctx)
	}
	ui.end(ctx)
}
