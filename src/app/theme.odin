package app

// The look of the application: embedded fonts, the color palette, shared
// layout sizes, and the small drawing helpers every view uses.
//
// All sizes passed to these helpers are in logical pixels; `scale` converts
// them to physical pixels for high-DPI displays.

import font_core "../font"
import "../ui"

// ---------------------------------------------------------------------------
// Fonts
//
// Fonts are embedded at compile time so the executable does not depend on the
// working directory. #load paths are relative to this source file.

THEME_BODY_FONT :: #load("../../assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Regular.otf")
THEME_TITLE_FONT :: #load("../../assets/fonts/Satoshi_Complete/Satoshi_Complete/Fonts/OTF/Satoshi-Bold.otf")
THEME_ICON_FONT :: #load("../../assets/fonts/SymbolsNerdFontMono-Regular.ttf")
// Large serif heading on the welcome screen.
THEME_WELCOME_FONT :: #load("../../assets/fonts/Gambarino_Complete/Fonts/OTF/Gambarino-Regular.otf")
// Monospaced font for diffs and the commit description.
THEME_DIFF_FONT :: #load("../../assets/fonts/GeistMono/GeistMono-Regular.ttf")

// ---------------------------------------------------------------------------
// Colors (RGBA, sRGB, 0..1)
//
// Warm light grays with near-white cards, charcoal for primary and active
// controls, and lime as the single highlight color.

THEME_SURFACE :: [4]f32{0.89, 0.89, 0.87, 1}
THEME_BACKGROUND :: THEME_SURFACE // Window clear color: the page.
THEME_CARD :: [4]f32{0.965, 0.965, 0.955, 1}
THEME_TEXT :: [4]f32{0.12, 0.12, 0.12, 1}
THEME_MUTED :: [4]f32{0.45, 0.45, 0.43, 1}
THEME_LINE :: [4]f32{0.85, 0.85, 0.83, 1}
THEME_LIGHT :: [4]f32{0.99, 0.99, 0.98, 1}
THEME_ACCENT :: [4]f32{0.22, 0.22, 0.21, 1}
// Selected rows: a pale wash of the lime highlight.
THEME_SELECTED :: [4]f32{0.93, 0.95, 0.78, 1}
THEME_HOVER :: [4]f32{0.92, 0.92, 0.90, 1}
// Secondary buttons sit on cards; this keeps them visible without borders.
THEME_BUTTON :: [4]f32{0.91, 0.91, 0.89, 1}
THEME_DARK :: [4]f32{0.17, 0.17, 0.16, 1}
THEME_HIGHLIGHT :: [4]f32{0.86, 0.93, 0.20, 1}
THEME_WARNING :: [4]f32{0.85, 0.45, 0.30, 1}
THEME_ERROR_TEXT :: [4]f32{0.56, 0.22, 0.20, 1}

// Diff lines: pale backgrounds for whole lines, stronger ones for the
// changed part of a line, and darker text for the +/- markers.
THEME_ADDITION :: [4]f32{0.84, 0.93, 0.80, 1}
THEME_DELETION :: [4]f32{0.97, 0.85, 0.82, 1}
THEME_ADDITION_STRONG :: [4]f32{0.66, 0.85, 0.58, 1}
THEME_DELETION_STRONG :: [4]f32{0.94, 0.66, 0.60, 1}
THEME_ADDITION_TEXT :: [4]f32{0.20, 0.42, 0.14, 1}
THEME_DELETION_TEXT :: [4]f32{0.62, 0.22, 0.16, 1}

// Lane colors of the commit graph, reused in order.
THEME_GRAPH_COLORS :: [?][4]f32{
	{0.22, 0.22, 0.21, 1}, {0.33, 0.47, 0.75, 1},
	{0.84, 0.42, 0.30, 1}, {0.44, 0.60, 0.16, 1},
	{0.58, 0.40, 0.70, 1}, {0.78, 0.60, 0.10, 1},
}

// ---------------------------------------------------------------------------
// Shared layout sizes (logical pixels)

MENU_HEIGHT :: 52   // Menu bar along the top of the window.
SIDEBAR_WIDTH :: 248 // Branch/tag sidebar on the left of the workspace.
PANEL_GAP :: 12     // Outer margin and gap between panels.
PANEL_PADDING :: 16 // Padding inside a panel.

// ---------------------------------------------------------------------------
// Drawing helpers

// Converts a rectangle from logical to physical pixels.
theme_rect :: proc(rect: ui.Rect2d, scale: f32) -> ui.Rect2d {
	return {rect.x * scale, rect.y * scale, rect.width * scale, rect.height * scale}
}

// Text with no background, padding or interaction.
theme_label :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, rect: ui.Rect2d,
	size: f32, color: [4]f32, scale: f32, align := ui.UiAlignments{.NONE}) {
	style := ui.default_style
	style.font_id = ui.UiFont(uintptr(face))
	style.font_size = size * scale
	style.text_color = color
	style.padding = 0
	ui.style_push(ctx, style)
	ui.label(ctx, text, theme_rect(rect, scale), align)
	ui.style_pop(ctx)
}

// A filled, optionally rounded and bordered rectangle. When `bottom` is
// given, the fill fades vertically from `color` to `bottom`.
theme_box :: proc(ctx: ^ui.UiContext, rect: ui.Rect2d, color: [4]f32, radius, scale: f32,
	border: f32 = 0, bottom: [4]f32 = {}) {
	style := ui.default_style
	style.color_top = color
	style.color_bottom = bottom.a > 0 ? bottom : color
	style.radius = radius * scale
	style.border = border * scale
	style.border_color = THEME_LIGHT
	ui.style_push(ctx, style)
	ui.new_box(ctx, "", {}, {}, theme_rect(rect, scale))
	ui.style_pop(ctx)
}

// A card with a soft shadow.
theme_panel :: proc(ctx: ^ui.UiContext, rect: ui.Rect2d, color: [4]f32, radius, scale: f32) {
	// Two faint, slightly lowered layers lift the card off the page.
	for layer := 2; layer > 0; layer -= 1 {
		spread := f32(layer) * 1.5
		shadow := ui.Rect2d{rect.x - spread, rect.y - spread * 0.5, rect.width + spread * 2, rect.height + spread * 2.5}
		theme_box(ctx, shadow, {0.10, 0.10, 0.08, 0.035}, radius + spread, scale)
	}
	theme_box(ctx, rect, color, radius, scale)
}

// A small rounded tag, e.g. HEAD or SUBMODULE. Returns its width.
theme_tag :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, x, y: f32,
	fill, color: [4]f32, scale: f32, height: f32 = 18) -> f32 {
	width := theme_text_width(ctx, face, text, 10, scale) + 14
	theme_box(ctx, {x, y, width, height}, fill, height * 0.5, scale)
	theme_label(ctx, face, text, {x, y, width, height}, 10, color, scale, {.CENTER})
	return width
}

// Logical width of text at a logical font size (falls back to an estimate in tests).
theme_text_width :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, text: string, size, scale: f32) -> f32 {
	if ctx.measure_text == nil || face == nil do return f32(len(text)) * size * 0.55
	return ctx.measure_text(ui.UiFont(uintptr(face)), text, size * scale).x / scale
}
