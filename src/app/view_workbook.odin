package app

import "core:fmt"
import "core:strconv"
import "core:strings"

import font_core "../font"
import "../ui"
import "../workspace"
import xlsx "../xlsx"

// Workbook diffs shown like a spreadsheet: lettered columns, numbered rows,
// gridlines, sheet tabs and a formula bar. Added rows are green, removed rows
// red, and the cells that changed within a row are amber; the formula bar
// shows the selected cell's formula and what it was before.

GRID_ROW :: 24
GRID_HEADER :: 24
GRID_ROW_HEADER :: 58
GRID_MIN_COLUMN :: 64
GRID_MAX_COLUMN :: 320
GRID_BAR :: 48
GRID_TABS :: 30

GRID_CELL :: [4]f32{1, 1, 1, 1}
GRID_LINE :: [4]f32{0.87, 0.87, 0.85, 1}
GRID_GAP_LINE :: [4]f32{0.70, 0.70, 0.68, 1}
GRID_HEADER_FILL :: [4]f32{0.94, 0.94, 0.92, 1}
GRID_HEADER_ACTIVE :: [4]f32{0.86, 0.91, 0.84, 1}
GRID_MODIFIED_ROW :: [4]f32{1.0, 0.975, 0.90, 1}
GRID_CHANGED :: [4]f32{0.99, 0.86, 0.55, 1}
GRID_CHANGED_TEXT :: [4]f32{0.55, 0.36, 0.05, 1}
GRID_SELECTION :: [4]f32{0.13, 0.45, 0.25, 1}

// Column letters, e.g. 28 -> AB.
gitaris_column_name :: proc(col: int) -> string {
	buf: [4]u8
	return strings.clone(xlsx.column_letters(col, buf[:]), context.temp_allocator)
}

// Resets the viewer when another workbook diff is shown.
gitaris_grid_sync :: proc(state: ^Gitaris, key: string) {
	if state.grid.key == key do return
	delete(state.grid.key)
	text, changes_only := state.grid.text, state.grid.changes_only
	state.grid = {key = strings.clone(key), row = -1, text = text, changes_only = changes_only}
	state.grid.sheet = state.model.changes.file.grid.first_changed
}

@(private = "file")
grid_is_number :: proc(text: string) -> bool {
	if text == "" do return false
	_, ok := strconv.parse_f64(text)
	return ok
}

// What a cell shows in the grid, and in which color.
@(private = "file")
grid_cell_text :: proc(row: workspace.Grid_Row, cell: workspace.Grid_Cell) -> (string, [4]f32) {
	text := cell.value
	if text == "" && cell.formula != "" do text = fmt.tprintf("=%s", cell.formula)
	switch row.kind {
	case .ADDED: return text, GITARIS_ADD_TEXT
	case .DELETED: return text, GITARIS_DELETE_TEXT
	case .MODIFIED:
		if cell.changed && text == "" {
			// Cleared: show what was there, as removed.
			old := cell.old_value
			if old == "" && cell.old_formula != "" do old = fmt.tprintf("=%s", cell.old_formula)
			return old, GITARIS_DELETE_TEXT
		}
		return text, cell.changed ? GRID_CHANGED_TEXT : TEMPLATE_TEXT
	case .SAME:
	}
	return text, TEMPLATE_TEXT
}

@(private = "file")
grid_formula_text :: proc(value, formula: string) -> string {
	if formula == "" do return value
	if value == "" do return fmt.tprintf("=%s", formula)
	return fmt.tprintf("=%s   →  %s", formula, value)
}

@(private = "file")
grid_find_cell :: proc(row: workspace.Grid_Row, col: int) -> (workspace.Grid_Cell, bool) {
	for cell in row.cells {
		if cell.col == col do return cell, true
		if cell.col > col do break
	}
	return {}, false
}

// Index of `row` in the shown list (all rows, or only changed ones); -1 when hidden.
@(private = "file")
grid_list_index :: proc(sheet: ^workspace.Grid_Sheet, changes_only: bool, row: int) -> int {
	if row < 0 do return -1
	if !changes_only do return row < len(sheet.rows) ? row : -1
	for index, i in sheet.changes do if index == row do return i
	return -1
}

// Selects a changed row (and its first changed cell) and scrolls to it.
@(private = "file")
grid_select_change :: proc(state: ^Gitaris, sheet: ^workspace.Grid_Sheet, forward: bool) {
	if len(sheet.changes) == 0 do return
	g := &state.grid
	target := forward ? sheet.changes[0] : sheet.changes[len(sheet.changes) - 1]
	if g.row >= 0 {
		if forward {
			for index in sheet.changes do if index > g.row { target = index; break }
		} else {
			#reverse for index in sheet.changes do if index < g.row { target = index; break }
		}
	}
	g.row = target
	g.col = 1
	row := sheet.rows[target]
	if len(row.cells) > 0 do g.col = row.cells[0].col
	for cell in row.cells do if cell.changed { g.col = cell.col; break }
}

gitaris_workbook_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Gitaris,
	x, y, w, bottom, scale: f32) {
	book := &state.model.changes.file.grid
	g := &state.grid
	g.sheet = clamp(g.sheet, 0, len(book.sheets) - 1)
	sheet := &book.sheets[g.sheet]
	if g.row >= len(sheet.rows) do g.row = -1
	count := g.changes_only ? len(sheet.changes) : len(sheet.rows)
	row_at := proc(sheet: ^workspace.Grid_Sheet, changes_only: bool, i: int) -> int {
		return changes_only ? sheet.changes[i] : i
	}

	gx, gy := x, y + GRID_BAR + 8
	gw, gh := w, bottom - GRID_TABS - 6 - gy
	view := ui.Rect2d{gx + GRID_ROW_HEADER, gy + GRID_HEADER, gw - GRID_ROW_HEADER, gh - GRID_HEADER}

	// Column edges in logical pixels: sized to their widest value, then
	// empty columns to fill the view, as a spreadsheet does.
	edges := make([dynamic]f32, 1, context.temp_allocator)
	for chars in sheet.widths {
		append(&edges, edges[len(edges) - 1] + clamp(f32(chars) * 7 + 18, GRID_MIN_COLUMN, GRID_MAX_COLUMN))
	}
	for edges[len(edges) - 1] < view.width || len(edges) < 2 do append(&edges, edges[len(edges) - 1] + GRID_MIN_COLUMN)
	columns := len(edges) - 1
	g.col = clamp(g.col, 1, columns)

	window := &ctx.windows[ctx.window_index]
	grid_id := ui.make_id("grid-cells", window.id)
	selected := grid_list_index(sheet, g.changes_only, g.row)
	// Arrow keys move the selection once the grid has been clicked.
	keys := &ctx.input.key_pressed
	if ctx.focus_id == grid_id && count > 0 {
		moved := false
		if keys[.DOWN] { selected = min(count - 1, max(0, selected + 1)); moved = true }
		if keys[.UP] { selected = max(0, selected - 1); moved = true }
		if keys[.RIGHT] { g.col = min(columns, g.col + 1); moved = true }
		if keys[.LEFT] { g.col = max(1, g.col - 1); moved = true }
		if keys[.HOME] { g.col = 1; moved = true }
		if moved {
			selected = max(selected, 0)
			g.row = row_at(sheet, g.changes_only, selected)
			top := f32(selected) * GRID_ROW * scale
			if top < window.scroll_offset.y do window.scroll_offset.y = top
			if top + GRID_ROW * scale > window.scroll_offset.y + view.height * scale do window.scroll_offset.y = top + (GRID_ROW - view.height) * scale
			left, right := edges[g.col - 1] * scale, edges[g.col] * scale
			if left < window.scroll_offset.x do window.scroll_offset.x = left
			if right > window.scroll_offset.x + view.width * scale do window.scroll_offset.x = right - view.width * scale
		}
	}

	// Cells.
	template_box(ctx, view, GRID_CELL, 0, scale)
	first, last, offset := gitaris_scroll_begin(ctx, view, count, GRID_ROW, scale, edges[columns])
	hx := ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	c0, c1 := 1, columns
	for c0 < columns && edges[c0] <= hx do c0 += 1
	for c1 > c0 && edges[c1 - 1] >= hx + view.width do c1 -= 1
	content_bottom := min(view.y + view.height, view.y + f32(count) * GRID_ROW - offset)
	for i in first..<last {
		row := sheet.rows[row_at(sheet, g.changes_only, i)]
		ry := view.y + f32(i) * GRID_ROW - offset
		switch row.kind {
		case .ADDED: template_box(ctx, {view.x, ry, view.width, GRID_ROW}, GITARIS_ADDITION, 0, scale)
		case .DELETED: template_box(ctx, {view.x, ry, view.width, GRID_ROW}, GITARIS_DELETION, 0, scale)
		case .MODIFIED: template_box(ctx, {view.x, ry, view.width, GRID_ROW}, GRID_MODIFIED_ROW, 0, scale)
		case .SAME:
		}
		for cell in row.cells {
			if cell.col < c0 do continue
			if cell.col > c1 do break
			cx := view.x + edges[cell.col - 1] - hx
			cw := edges[cell.col] - edges[cell.col - 1]
			if row.kind == .MODIFIED && cell.changed do template_box(ctx, {cx, ry, cw, GRID_ROW}, GRID_CHANGED, 0, scale)
			text, color := grid_cell_text(row, cell)
			align := grid_is_number(text) ? ui.UiAlignments{.RIGHT} : ui.UiAlignments{.NONE}
			template_label(ctx, face, text, {cx + 6, ry, cw - 12, GRID_ROW}, 12, color, scale, align)
		}
		template_box(ctx, {view.x, ry + GRID_ROW - 1, view.width, 1}, GRID_LINE, 0, scale)
		// Rows that are not consecutive in the sheet (empty rows between).
		if i > 0 {
			prev := sheet.rows[row_at(sheet, g.changes_only, i - 1)]
			number := row.row > 0 ? row.row : row.old_row
			before := prev.row > 0 ? prev.row : prev.old_row
			if number != before + 1 && number != before do template_box(ctx, {view.x, ry - 1, view.width, 2}, GRID_GAP_LINE, 0, scale)
		}
	}
	for c in c0..=c1 {
		template_box(ctx, {view.x + edges[c] - hx - 1, view.y, 1, max(0, content_bottom - view.y)}, GRID_LINE, 0, scale)
	}
	if selected >= first && selected < last {
		sx := view.x + edges[g.col - 1] - hx - 1
		sy := view.y + f32(selected) * GRID_ROW - offset - 1
		sw := edges[g.col] - edges[g.col - 1] + 1
		template_box(ctx, {sx, sy, sw, 2}, GRID_SELECTION, 0, scale)
		template_box(ctx, {sx, sy + GRID_ROW - 1, sw, 2}, GRID_SELECTION, 0, scale)
		template_box(ctx, {sx, sy, 2, GRID_ROW + 1}, GRID_SELECTION, 0, scale)
		template_box(ctx, {sx + sw - 1, sy, 2, GRID_ROW + 1}, GRID_SELECTION, 0, scale)
	}
	if count == 0 {
		empty := g.changes_only ? "No changed rows on this sheet." : "This sheet has no cell values (empty, or a chart sheet)."
		template_label(ctx, face, empty, {view.x, view.y + 24, view.width, 30}, 13, TEMPLATE_MUTED, scale, {.CENTER})
	}
	{
		// One invisible target over the cells picks the cell under the pointer.
		style := gitaris_control_style(face, scale)
		style.radius = 0
		style.color_top, style.color_bottom = {}, {}
		style.hover_color, style.active_color = {}, {}
		// Focused (for arrow keys) without a ring: the selection outline shows it.
		style.focus_color = {}
		ui.style_push(ctx, style)
		if ui.button(ctx, "", template_rect(view, scale), id = "grid-cells") == .SUBMIT && count > 0 {
			mx, my := ctx.mouse_pos.x / scale, ctx.mouse_pos.y / scale
			i := int((my - view.y + offset) / GRID_ROW)
			if i >= 0 && i < count && mx >= view.x {
				col := 1
				for col < columns && edges[col] <= mx - view.x + hx do col += 1
				g.row, g.col = row_at(sheet, g.changes_only, i), col
			}
		}
		ui.style_pop(ctx)
	}
	gitaris_scroll_end(ctx, view, scale, true)

	// Column letters, scrolling sideways with the cells.
	clip := ui.default_layout
	clip.rect = template_rect({view.x, gy, view.width, GRID_HEADER}, scale)
	ui.layout_push(ctx, clip)
	template_box(ctx, {view.x, gy, view.width, GRID_HEADER}, GRID_HEADER_FILL, 0, scale)
	for c in c0..=c1 {
		cx := view.x + edges[c - 1] - hx
		cw := edges[c] - edges[c - 1]
		if c == g.col && g.row >= 0 do template_box(ctx, {cx, gy, cw, GRID_HEADER}, GRID_HEADER_ACTIVE, 0, scale)
		template_label(ctx, face, gitaris_column_name(c), {cx, gy, cw, GRID_HEADER}, 11, TEMPLATE_MUTED, scale, {.CENTER})
		template_box(ctx, {cx + cw - 1, gy + 4, 1, GRID_HEADER - 8}, GRID_LINE, 0, scale)
	}
	ui.layout_pop(ctx)

	// Row numbers, with a colored change bar, scrolling with the cells.
	clip.rect = template_rect({gx, view.y, GRID_ROW_HEADER, view.height}, scale)
	ui.layout_push(ctx, clip)
	template_box(ctx, {gx, view.y, GRID_ROW_HEADER, view.height}, GRID_HEADER_FILL, 0, scale)
	for i in first..<last {
		row := sheet.rows[row_at(sheet, g.changes_only, i)]
		ry := view.y + f32(i) * GRID_ROW - offset
		if i == selected do template_box(ctx, {gx, ry, GRID_ROW_HEADER, GRID_ROW}, GRID_HEADER_ACTIVE, 0, scale)
		bar, number := TEMPLATE_MUTED, fmt.tprintf("%d", row.row)
		switch row.kind {
		case .ADDED: bar = GITARIS_ADDITION_STRONG
		case .DELETED: bar, number = GITARIS_DELETION_STRONG, fmt.tprintf("−%d", row.old_row)
		case .MODIFIED: bar = GRID_CHANGED
		case .SAME:
		}
		if row.kind != .SAME do template_box(ctx, {gx, ry + 1, 4, GRID_ROW - 2}, bar, 0, scale)
		color := row.kind == .DELETED ? GITARIS_DELETE_TEXT : TEMPLATE_MUTED
		template_label(ctx, mono, number, {gx + 6, ry, GRID_ROW_HEADER - 14, GRID_ROW}, 11, color, scale, {.RIGHT})
		template_box(ctx, {gx, ry + GRID_ROW - 1, GRID_ROW_HEADER, 1}, GRID_LINE, 0, scale)
	}
	ui.layout_pop(ctx)
	template_box(ctx, {gx, gy, GRID_ROW_HEADER, GRID_HEADER}, GRID_HEADER_FILL, 0, scale)
	template_box(ctx, {gx, gy + GRID_HEADER - 1, gw, 1}, GRID_GAP_LINE, 0, scale)
	template_box(ctx, {gx + GRID_ROW_HEADER - 1, gy, 1, gh}, GRID_GAP_LINE, 0, scale)

	gitaris_formula_bar(ctx, face, title, mono, state, sheet, x, y, w, scale)
	gitaris_sheet_tabs(ctx, face, state, book, x, bottom - GRID_TABS, w, scale)
}

@(private = "file")
gitaris_formula_bar :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Gitaris,
	sheet: ^workspace.Grid_Sheet, x, y, w, scale: f32) {
	g := &state.grid
	nav_w: f32 = 236
	bw := w - nav_w - 10
	template_box(ctx, {x, y, 78, GRID_BAR}, GRID_CELL, 8, scale)
	template_box(ctx, {x + 84, y, bw - 84, GRID_BAR}, GRID_CELL, 8, scale)
	template_label(ctx, mono, "fx", {x + 92, y + 4, 24, 20}, 12, TEMPLATE_MUTED, scale)
	line1, line2 := "Select a cell to see its formula and what it was before.", ""
	color1, color2 := TEMPLATE_MUTED, TEMPLATE_MUTED
	reference := "—"
	if g.row >= 0 && g.row < len(sheet.rows) {
		row := sheet.rows[g.row]
		number := row.row > 0 ? row.row : row.old_row
		reference = fmt.tprintf("%s%d", gitaris_column_name(g.col), number)
		cell, found := grid_find_cell(row, g.col)
		line1 = found ? grid_formula_text(cell.value, cell.formula) : ""
		color1 = TEMPLATE_TEXT
		switch row.kind {
		case .SAME:
			line2 = "Unchanged"
			if row.old_row > 0 && row.old_row != row.row do line2 = fmt.tprintf("Unchanged · was row %d", row.old_row)
		case .ADDED:
			line2, color2 = "Row added in this version", GITARIS_ADD_TEXT
		case .DELETED:
			line2, color2 = fmt.tprintf("Row %d removed in this version", row.old_row), GITARIS_DELETE_TEXT
			reference = fmt.tprintf("%s%d", gitaris_column_name(g.col), row.old_row)
		case .MODIFIED:
			if found && cell.changed {
				old := grid_formula_text(cell.old_value, cell.old_formula)
				line2, color2 = fmt.tprintf("Was:  %s", old != "" ? old : "(empty)"), GITARIS_DELETE_TEXT
				if line1 == "" do line1, color1 = "(cleared)", TEMPLATE_MUTED
			} else {
				line2 = "Unchanged cell in a changed row"
			}
			if row.old_row != row.row do line2 = fmt.tprintf("%s  ·  was row %d", line2, row.old_row)
		}
		if line1 == "" do line1, color1 = "(empty)", TEMPLATE_MUTED
	} else {
		total := sheet.added_rows + sheet.removed_rows + sheet.modified_rows
		line2 = total > 0 ? "Use ↑ ↓ beside this bar to step through the changes, or click any cell." : "No cell values changed on this sheet."
	}
	template_label(ctx, title, reference, {x, y, 78, GRID_BAR}, 13, TEMPLATE_TEXT, scale, {.CENTER})
	template_label(ctx, mono, line1, {x + 120, y + 4, bw - 132, 20}, 12, color1, scale)
	template_label(ctx, mono, line2, {x + 120, y + 24, bw - 132, 20}, 11, color2, scale)

	// Step through changes; optionally hide unchanged rows.
	nx := x + w - nav_w
	position := grid_list_index_in(sheet.changes, g.row)
	counter := len(sheet.changes) == 0 ? "No changes" : (position >= 0 ? fmt.tprintf("Change %d of %d", position + 1, len(sheet.changes)) : fmt.tprintf("%d changed row%s", len(sheet.changes), len(sheet.changes) == 1 ? "" : "s"))
	if gitaris_button(ctx, face, "↑", {nx, y, 32, 24}, scale, id = "grid-prev") do grid_step(ctx, state, sheet, false, scale)
	if gitaris_button(ctx, face, "↓", {nx + 36, y, 32, 24}, scale, id = "grid-next") do grid_step(ctx, state, sheet, true, scale)
	template_label(ctx, face, counter, {nx + 76, y, nav_w - 76, 24}, 11, TEMPLATE_TEXT, scale)
	if gitaris_check(ctx, face, "grid-changes-only", &g.changes_only, {nx, y + 27, 20, 20}, scale) {
		gitaris_reset_windows(ctx, "commit-diff")
	}
	template_label(ctx, face, "Changed rows only", {nx + 26, y + 26, nav_w - 26, 22}, 12, TEMPLATE_TEXT, scale)
}

@(private = "file")
grid_list_index_in :: proc(list: []int, row: int) -> int {
	for index, i in list do if index == row do return i
	return -1
}

// Moves to the next/previous change and scrolls it into view.
// Called inside the grid's window; the scroll applies from the next frame.
@(private = "file")
grid_step :: proc(ctx: ^ui.UiContext, state: ^Gitaris, sheet: ^workspace.Grid_Sheet, forward: bool, scale: f32) {
	grid_select_change(state, sheet, forward)
	g := &state.grid
	i := grid_list_index(sheet, g.changes_only, g.row)
	if i < 0 do return
	window := &ctx.windows[ctx.window_index]
	window.scroll_offset.y = max(0, (f32(i) - 4) * GRID_ROW * scale)
	// Arrow keys continue from here.
	ctx.focus_id = ui.make_id("grid-cells", window.id)
}

@(private = "file")
gitaris_sheet_tabs :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Gitaris, book: ^workspace.Workbook_Grid,
	x, y, w, scale: f32) {
	g := &state.grid
	template_box(ctx, {x, y - 1, w, 1}, GRID_GAP_LINE, 0, scale)
	sheet := &book.sheets[g.sheet]
	stats_w: f32 = 210
	stats := fmt.tprintf("+%d  −%d  ~%d rows", sheet.added_rows, sheet.removed_rows, sheet.modified_rows)
	template_label(ctx, face, stats, {x + w - stats_w, y + 2, stats_w, GRID_TABS - 4}, 12, TEMPLATE_MUTED, scale, {.RIGHT})
	limit := x + w - stats_w - 8
	tx := x
	g.first_tab = clamp(g.first_tab, 0, len(book.sheets) - 1)
	if g.first_tab > 0 {
		if gitaris_button(ctx, face, "‹", {tx, y + 2, 26, 24}, scale, id = "grid-tabs-left") do g.first_tab -= 1
		tx += 30
	}
	for i in g.first_tab..<len(book.sheets) {
		s := &book.sheets[i]
		marker := ""
		switch {
		case s.added: marker = "new"
		case s.removed: marker = "removed"
		case len(s.changes) > 0: marker = fmt.tprintf("%d", len(s.changes))
		}
		tw := template_text_width(ctx, face, s.name, 12, scale) + 28
		mw: f32 = marker != "" ? template_text_width(ctx, face, marker, 10, scale) + 14 : 0
		if tx + tw + mw > limit - 30 {
			if gitaris_button(ctx, face, "›", {limit - 26, y + 2, 26, 24}, scale, id = "grid-tabs-right") do g.first_tab += 1
			break
		}
		active := i == g.sheet
		style := gitaris_control_style(face, scale)
		style.radius = 0
		style.padding = 14 * scale
		style.font_size = 12 * scale
		style.color_top = active ? GRID_CELL : GRID_HEADER_FILL
		style.color_bottom = style.color_top
		style.hover_color = active ? GRID_CELL : TEMPLATE_HOVER
		style.text_color = active ? TEMPLATE_TEXT : TEMPLATE_MUTED
		ui.style_push(ctx, style)
		if ui.button(ctx, s.name, template_rect({tx, y, tw + mw, GRID_TABS - 2}, scale), {.NONE}, id = fmt.tprintf("grid-tab-%d", i)) == .SUBMIT && !active {
			g.sheet, g.row = i, -1
			gitaris_reset_windows(ctx, "commit-diff")
		}
		ui.style_pop(ctx)
		if active do template_box(ctx, {tx, y + GRID_TABS - 4, tw + mw, 3}, GRID_SELECTION, 0, scale)
		if marker != "" {
			fill, color := GRID_CHANGED, GRID_CHANGED_TEXT
			if s.added do fill, color = GITARIS_ADDITION_STRONG, GITARIS_ADD_TEXT
			if s.removed do fill, color = GITARIS_DELETION_STRONG, GITARIS_DELETE_TEXT
			template_tag(ctx, face, marker, tx + tw - 10, y + 6, fill, color, scale, 16)
		}
		template_box(ctx, {tx + tw + mw, y + 4, 1, GRID_TABS - 10}, GRID_LINE, 0, scale)
		tx += tw + mw + 1
	}
}
