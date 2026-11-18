package app

// Spreadsheet diff for Excel workbooks: grid of cells, formula bar,
// change navigation and sheet tabs.

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

// Sizes in logical pixels.
GRID_ROW_HEIGHT :: 24
GRID_COLUMN_LETTERS_HEIGHT :: 24 // The A, B, C… header row.
GRID_ROW_NUMBERS_WIDTH :: 58 // The 1, 2, 3… header column.
GRID_MIN_COLUMN_WIDTH :: 64
GRID_MAX_COLUMN_WIDTH :: 320
GRID_FORMULA_BAR_HEIGHT :: 48
GRID_TABS_HEIGHT :: 30 // Sheet tabs along the bottom.

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
workbench_column_name :: proc(col: int) -> string {
	buf: [4]u8
	return strings.clone(xlsx.column_letters(col, buf[:]), context.temp_allocator)
}

// Resets the viewer when another workbook diff is shown.
workbench_grid_sync :: proc(state: ^Workbench, key: string) {
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
	case .ADDED: return text, THEME_ADDITION_TEXT
	case .DELETED: return text, THEME_DELETION_TEXT
	case .MODIFIED:
		if cell.changed && text == "" {
			// Cleared: show what was there, as removed.
			old := cell.old_value
			if old == "" && cell.old_formula != "" do old = fmt.tprintf("=%s", cell.old_formula)
			return old, THEME_DELETION_TEXT
		}
		return text, cell.changed ? GRID_CHANGED_TEXT : THEME_TEXT
	case .SAME:
	}
	return text, THEME_TEXT
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
grid_select_change :: proc(state: ^Workbench, sheet: ^workspace.Grid_Sheet, forward: bool) {
	if len(sheet.changes) == 0 do return
	grid := &state.grid
	target := forward ? sheet.changes[0] : sheet.changes[len(sheet.changes) - 1]
	if grid.row >= 0 {
		if forward {
			for index in sheet.changes do if index > grid.row { target = index; break }
		} else {
			#reverse for index in sheet.changes do if index < grid.row { target = index; break }
		}
	}
	grid.row = target
	grid.col = 1
	row := sheet.rows[target]
	if len(row.cells) > 0 do grid.col = row.cells[0].col
	for cell in row.cells do if cell.changed { grid.col = cell.col; break }
}

// Everything the grid's parts need to agree on for one frame.
@(private = "file")
Grid_View :: struct {
	sheet: ^workspace.Grid_Sheet,
	changes_only: bool,
	count: int, // Rows shown: all of them, or only the changed ones.
	// Column edges in logical pixels: column c spans edges[c-1]..edges[c].
	edges: []f32,
	columns: int,
	frame: ui.Rect2d, // The whole grid, with column letters and row numbers.
	cells: ui.Rect2d, // Just the cells.
	selected: int, // Index of the selected row in the shown list; -1 for none.
	// Visible part, known once the cells' scroll area has begun.
	first, last: int, // Shown rows first..<last.
	offset: f32, // Vertical scroll within the first row.
	scroll_x: f32,
	first_col, last_col: int,
}

// Index into sheet.rows of the i-th shown row.
@(private = "file")
grid_row_at :: proc(view: Grid_View, i: int) -> int {
	return view.changes_only ? view.sheet.changes[i] : i
}

@(private = "file")
grid_row_y :: proc(view: Grid_View, i: int) -> f32 {
	return view.cells.y + f32(i) * GRID_ROW_HEIGHT - view.offset
}

@(private = "file")
grid_column_x :: proc(view: Grid_View, col: int) -> f32 {
	return view.cells.x + view.edges[col - 1] - view.scroll_x
}

@(private = "file")
grid_column_w :: proc(view: Grid_View, col: int) -> f32 {
	return view.edges[col] - view.edges[col - 1]
}

// The spreadsheet view of a workbook diff, from the formula bar at `y` down to
// the sheet tabs above `bottom`.
workbench_workbook_ui :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench,
	x, y, w, bottom, scale: f32) {
	book := &state.model.changes.file.grid
	grid := &state.grid
	grid.sheet = clamp(grid.sheet, 0, len(book.sheets) - 1)
	sheet := &book.sheets[grid.sheet]
	if grid.row >= len(sheet.rows) do grid.row = -1

	frame_y := y + GRID_FORMULA_BAR_HEIGHT + 8
	frame := ui.Rect2d{x, frame_y, w, bottom - GRID_TABS_HEIGHT - 6 - frame_y}
	view := Grid_View{
		sheet = sheet,
		changes_only = grid.changes_only,
		count = grid.changes_only ? len(sheet.changes) : len(sheet.rows),
		frame = frame,
		cells = {frame.x + GRID_ROW_NUMBERS_WIDTH, frame.y + GRID_COLUMN_LETTERS_HEIGHT,
			frame.width - GRID_ROW_NUMBERS_WIDTH, frame.height - GRID_COLUMN_LETTERS_HEIGHT},
	}
	view.edges = grid_column_edges(sheet, view.cells.width)
	view.columns = len(view.edges) - 1
	grid.col = clamp(grid.col, 1, view.columns)
	view.selected = grid_list_index(sheet, grid.changes_only, grid.row)

	grid_keyboard(ctx, state, &view, scale)
	grid_cells(ctx, face, state, &view, scale)
	grid_column_letters(ctx, face, state, view, scale)
	grid_row_numbers(ctx, mono, view, scale)
	// Corner above the row numbers, and the lines framing the headers.
	theme_box(ctx, {frame.x, frame.y, GRID_ROW_NUMBERS_WIDTH, GRID_COLUMN_LETTERS_HEIGHT}, GRID_HEADER_FILL, 0, scale)
	theme_box(ctx, {frame.x, frame.y + GRID_COLUMN_LETTERS_HEIGHT - 1, frame.width, 1}, GRID_GAP_LINE, 0, scale)
	theme_box(ctx, {frame.x + GRID_ROW_NUMBERS_WIDTH - 1, frame.y, 1, frame.height}, GRID_GAP_LINE, 0, scale)

	workbench_formula_bar(ctx, face, title, mono, state, sheet, x, y, w, scale)
	workbench_sheet_tabs(ctx, face, state, book, x, bottom - GRID_TABS_HEIGHT, w, scale)
}

// Columns are sized to their widest value; then empty columns fill the rest
// of the view, as a spreadsheet does.
@(private = "file")
grid_column_edges :: proc(sheet: ^workspace.Grid_Sheet, view_width: f32) -> []f32 {
	edges := make([dynamic]f32, 1, context.temp_allocator)
	last :: proc(edges: [dynamic]f32) -> f32 { return edges[len(edges) - 1] }
	for chars in sheet.widths {
		append(&edges, last(edges) + clamp(f32(chars) * 7 + 18, GRID_MIN_COLUMN_WIDTH, GRID_MAX_COLUMN_WIDTH))
	}
	for last(edges) < view_width || len(edges) < 2 do append(&edges, last(edges) + GRID_MIN_COLUMN_WIDTH)
	return edges[:]
}

// Arrow keys and Home move the selection once the grid has been clicked,
// scrolling to keep the selected cell in view.
@(private = "file")
grid_keyboard :: proc(ctx: ^ui.UiContext, state: ^Workbench, view: ^Grid_View, scale: f32) {
	grid := &state.grid
	window := &ctx.windows[ctx.window_index]
	if ctx.focus_id != ui.make_id("grid-cells", window.id) || view.count == 0 do return
	keys := &ctx.input.key_pressed
	moved := false
	if keys[.DOWN] { view.selected = min(view.count - 1, max(0, view.selected + 1)); moved = true }
	if keys[.UP] { view.selected = max(0, view.selected - 1); moved = true }
	if keys[.RIGHT] { grid.col = min(view.columns, grid.col + 1); moved = true }
	if keys[.LEFT] { grid.col = max(1, grid.col - 1); moved = true }
	if keys[.HOME] { grid.col = 1; moved = true }
	if !moved do return

	view.selected = max(view.selected, 0)
	grid.row = grid_row_at(view^, view.selected)
	scroll := &window.scroll_offset
	top := f32(view.selected) * GRID_ROW_HEIGHT * scale
	if top < scroll.y do scroll.y = top
	if top + GRID_ROW_HEIGHT * scale > scroll.y + view.cells.height * scale {
		scroll.y = top + (GRID_ROW_HEIGHT - view.cells.height) * scale
	}
	left, right := view.edges[grid.col - 1] * scale, view.edges[grid.col] * scale
	if left < scroll.x do scroll.x = left
	if right > scroll.x + view.cells.width * scale do scroll.x = right - view.cells.width * scale
}

// The scrolling cell area: row colors, cell values, gridlines, the selection
// outline, and one invisible button that selects the clicked cell.
@(private = "file")
grid_cells :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, view: ^Grid_View, scale: f32) {
	grid := &state.grid
	cells := view.cells
	theme_box(ctx, cells, GRID_CELL, 0, scale)
	view.first, view.last, view.offset = workbench_scroll_begin(ctx, cells, view.count, GRID_ROW_HEIGHT, scale, view.edges[view.columns])
	view.scroll_x = ctx.layouts[ctx.n_layouts].scroll_offset.x / scale
	// Only the columns in view are drawn.
	view.first_col, view.last_col = 1, view.columns
	for view.first_col < view.columns && view.edges[view.first_col] <= view.scroll_x do view.first_col += 1
	for view.last_col > view.first_col && view.edges[view.last_col - 1] >= view.scroll_x + cells.width do view.last_col -= 1

	for i in view.first..<view.last {
		grid_row(ctx, face, view^, i, scale)
	}
	// Vertical gridlines stop below the last row.
	content_bottom := min(cells.y + cells.height, cells.y + f32(view.count) * GRID_ROW_HEIGHT - view.offset)
	for c in view.first_col..=view.last_col {
		theme_box(ctx, {cells.x + view.edges[c] - view.scroll_x - 1, cells.y, 1, max(0, content_bottom - cells.y)}, GRID_LINE, 0, scale)
	}
	if view.selected >= view.first && view.selected < view.last {
		x := grid_column_x(view^, grid.col) - 1
		y := grid_row_y(view^, view.selected) - 1
		w := grid_column_w(view^, grid.col) + 1
		h: f32 = GRID_ROW_HEIGHT + 1
		theme_box(ctx, {x, y, w, 2}, GRID_SELECTION, 0, scale)
		theme_box(ctx, {x, y + h - 2, w, 2}, GRID_SELECTION, 0, scale)
		theme_box(ctx, {x, y, 2, h}, GRID_SELECTION, 0, scale)
		theme_box(ctx, {x + w - 1, y, 2, h}, GRID_SELECTION, 0, scale)
	}
	if view.count == 0 {
		empty := view.changes_only ? "No changed rows on this sheet." : "This sheet has no cell values (empty, or a chart sheet)."
		theme_label(ctx, face, empty, {cells.x, cells.y + 24, cells.width, 30}, 13, THEME_MUTED, scale, {.CENTER})
	}

	// One invisible target over the cells picks the cell under the pointer.
	style := workbench_control_style(face, scale)
	style.radius = 0
	style.color_top, style.color_bottom = {}, {}
	style.hover_color, style.active_color = {}, {}
	// Focused (for arrow keys) without a ring: the selection outline shows it.
	style.focus_color = {}
	ui.style_push(ctx, style)
	if ui.button(ctx, "", theme_rect(cells, scale), id = "grid-cells") == .SUBMIT && view.count > 0 {
		mouse_x, mouse_y := ctx.mouse_pos.x / scale, ctx.mouse_pos.y / scale
		i := int((mouse_y - cells.y + view.offset) / GRID_ROW_HEIGHT)
		if i >= 0 && i < view.count && mouse_x >= cells.x {
			col := 1
			for col < view.columns && view.edges[col] <= mouse_x - cells.x + view.scroll_x do col += 1
			grid.row, grid.col = grid_row_at(view^, i), col
		}
	}
	ui.style_pop(ctx)
	workbench_scroll_end(ctx, cells, scale, true)
}

// One row of cells: its change color, the values in view, and its bottom line.
@(private = "file")
grid_row :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, view: Grid_View, i: int, scale: f32) {
	row := view.sheet.rows[grid_row_at(view, i)]
	y := grid_row_y(view, i)
	full_row := ui.Rect2d{view.cells.x, y, view.cells.width, GRID_ROW_HEIGHT}
	switch row.kind {
	case .ADDED: theme_box(ctx, full_row, THEME_ADDITION, 0, scale)
	case .DELETED: theme_box(ctx, full_row, THEME_DELETION, 0, scale)
	case .MODIFIED: theme_box(ctx, full_row, GRID_MODIFIED_ROW, 0, scale)
	case .SAME:
	}
	for cell in row.cells {
		if cell.col < view.first_col do continue
		if cell.col > view.last_col do break
		x, w := grid_column_x(view, cell.col), grid_column_w(view, cell.col)
		if row.kind == .MODIFIED && cell.changed do theme_box(ctx, {x, y, w, GRID_ROW_HEIGHT}, GRID_CHANGED, 0, scale)
		text, color := grid_cell_text(row, cell)
		align := grid_is_number(text) ? ui.UiAlignments{.RIGHT} : ui.UiAlignments{.NONE}
		theme_label(ctx, face, text, {x + 6, y, w - 12, GRID_ROW_HEIGHT}, 12, color, scale, align)
	}
	theme_box(ctx, {view.cells.x, y + GRID_ROW_HEIGHT - 1, view.cells.width, 1}, GRID_LINE, 0, scale)
	// A thicker line where the sheet skips rows (empty rows in between).
	if i > 0 {
		previous := view.sheet.rows[grid_row_at(view, i - 1)]
		number := row.row > 0 ? row.row : row.old_row
		before := previous.row > 0 ? previous.row : previous.old_row
		if number != before + 1 && number != before {
			theme_box(ctx, {view.cells.x, y - 1, view.cells.width, 2}, GRID_GAP_LINE, 0, scale)
		}
	}
}

// Column letters along the top, scrolling sideways with the cells.
@(private = "file")
grid_column_letters :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, view: Grid_View, scale: f32) {
	grid := state.grid
	y, h := view.frame.y, f32(GRID_COLUMN_LETTERS_HEIGHT)
	clip := ui.default_layout
	clip.rect = theme_rect({view.cells.x, y, view.cells.width, h}, scale)
	ui.layout_push(ctx, clip)
	theme_box(ctx, {view.cells.x, y, view.cells.width, h}, GRID_HEADER_FILL, 0, scale)
	for c in view.first_col..=view.last_col {
		x, w := grid_column_x(view, c), grid_column_w(view, c)
		if c == grid.col && grid.row >= 0 do theme_box(ctx, {x, y, w, h}, GRID_HEADER_ACTIVE, 0, scale)
		theme_label(ctx, face, workbench_column_name(c), {x, y, w, h}, 11, THEME_MUTED, scale, {.CENTER})
		theme_box(ctx, {x + w - 1, y + 4, 1, h - 8}, GRID_LINE, 0, scale)
	}
	ui.layout_pop(ctx)
}

// Row numbers down the left, with a colored bar marking each kind of change,
// scrolling with the cells. Removed rows show their old number as −N.
@(private = "file")
grid_row_numbers :: proc(ctx: ^ui.UiContext, mono: ^font_core.Face, view: Grid_View, scale: f32) {
	x, w := view.frame.x, f32(GRID_ROW_NUMBERS_WIDTH)
	clip := ui.default_layout
	clip.rect = theme_rect({x, view.cells.y, w, view.cells.height}, scale)
	ui.layout_push(ctx, clip)
	theme_box(ctx, {x, view.cells.y, w, view.cells.height}, GRID_HEADER_FILL, 0, scale)
	for i in view.first..<view.last {
		row := view.sheet.rows[grid_row_at(view, i)]
		y := grid_row_y(view, i)
		if i == view.selected do theme_box(ctx, {x, y, w, GRID_ROW_HEIGHT}, GRID_HEADER_ACTIVE, 0, scale)
		bar, number := THEME_MUTED, fmt.tprintf("%d", row.row)
		switch row.kind {
		case .ADDED: bar = THEME_ADDITION_STRONG
		case .DELETED: bar, number = THEME_DELETION_STRONG, fmt.tprintf("−%d", row.old_row)
		case .MODIFIED: bar = GRID_CHANGED
		case .SAME:
		}
		if row.kind != .SAME do theme_box(ctx, {x, y + 1, 4, GRID_ROW_HEIGHT - 2}, bar, 0, scale)
		color := row.kind == .DELETED ? THEME_DELETION_TEXT : THEME_MUTED
		theme_label(ctx, mono, number, {x + 6, y, w - 14, GRID_ROW_HEIGHT}, 11, color, scale, {.RIGHT})
		theme_box(ctx, {x, y + GRID_ROW_HEIGHT - 1, w, 1}, GRID_LINE, 0, scale)
	}
	ui.layout_pop(ctx)
}

@(private = "file")
workbench_formula_bar :: proc(ctx: ^ui.UiContext, face, title, mono: ^font_core.Face, state: ^Workbench,
	sheet: ^workspace.Grid_Sheet, x, y, w, scale: f32) {
	grid := &state.grid
	nav_w: f32 = 236
	bar_w := w - nav_w - 10
	theme_box(ctx, {x, y, 78, GRID_FORMULA_BAR_HEIGHT}, GRID_CELL, 8, scale)
	theme_box(ctx, {x + 84, y, bar_w - 84, GRID_FORMULA_BAR_HEIGHT}, GRID_CELL, 8, scale)
	theme_label(ctx, mono, "fx", {x + 92, y + 4, 24, 20}, 12, THEME_MUTED, scale)
	line1, line2 := "Select a cell to see its formula and what it was before.", ""
	color1, color2 := THEME_MUTED, THEME_MUTED
	reference := "—"
	if grid.row >= 0 && grid.row < len(sheet.rows) {
		row := sheet.rows[grid.row]
		number := row.row > 0 ? row.row : row.old_row
		reference = fmt.tprintf("%s%d", workbench_column_name(grid.col), number)
		cell, found := grid_find_cell(row, grid.col)
		line1 = found ? grid_formula_text(cell.value, cell.formula) : ""
		color1 = THEME_TEXT
		switch row.kind {
		case .SAME:
			line2 = "Unchanged"
			if row.old_row > 0 && row.old_row != row.row do line2 = fmt.tprintf("Unchanged · was row %d", row.old_row)
		case .ADDED:
			line2, color2 = "Row added in this version", THEME_ADDITION_TEXT
		case .DELETED:
			line2, color2 = fmt.tprintf("Row %d removed in this version", row.old_row), THEME_DELETION_TEXT
			reference = fmt.tprintf("%s%d", workbench_column_name(grid.col), row.old_row)
		case .MODIFIED:
			if found && cell.changed {
				old := grid_formula_text(cell.old_value, cell.old_formula)
				line2, color2 = fmt.tprintf("Was:  %s", old != "" ? old : "(empty)"), THEME_DELETION_TEXT
				if line1 == "" do line1, color1 = "(cleared)", THEME_MUTED
			} else {
				line2 = "Unchanged cell in a changed row"
			}
			if row.old_row != row.row do line2 = fmt.tprintf("%s  ·  was row %d", line2, row.old_row)
		}
		if line1 == "" do line1, color1 = "(empty)", THEME_MUTED
	} else {
		total := sheet.added_rows + sheet.removed_rows + sheet.modified_rows
		line2 = total > 0 ? "Use ↑ ↓ beside this bar to step through the changes, or click any cell." : "No cell values changed on this sheet."
	}
	theme_label(ctx, title, reference, {x, y, 78, GRID_FORMULA_BAR_HEIGHT}, 13, THEME_TEXT, scale, {.CENTER})
	theme_label(ctx, mono, line1, {x + 120, y + 4, bar_w - 132, 20}, 12, color1, scale)
	theme_label(ctx, mono, line2, {x + 120, y + 24, bar_w - 132, 20}, 11, color2, scale)

	// Step through changes; optionally hide unchanged rows.
	nav_x := x + w - nav_w
	position := grid_list_index_in(sheet.changes, grid.row)
	changed := len(sheet.changes)
	counter := "No changes"
	if position >= 0 {
		counter = fmt.tprintf("Change %d of %d", position + 1, changed)
	} else if changed > 0 {
		counter = fmt.tprintf("%d changed row%s", changed, changed == 1 ? "" : "s")
	}
	if workbench_button(ctx, face, "↑", {nav_x, y, 32, 24}, scale, id = "grid-prev") do grid_step(ctx, state, sheet, false, scale)
	if workbench_button(ctx, face, "↓", {nav_x + 36, y, 32, 24}, scale, id = "grid-next") do grid_step(ctx, state, sheet, true, scale)
	theme_label(ctx, face, counter, {nav_x + 76, y, nav_w - 76, 24}, 11, THEME_TEXT, scale)
	if workbench_check(ctx, face, "grid-changes-only", &grid.changes_only, {nav_x, y + 27, 20, 20}, scale) {
		workbench_reset_windows(ctx, "commit-diff")
	}
	theme_label(ctx, face, "Changed rows only", {nav_x + 26, y + 26, nav_w - 26, 22}, 12, THEME_TEXT, scale)
}

@(private = "file")
grid_list_index_in :: proc(list: []int, row: int) -> int {
	for index, i in list do if index == row do return i
	return -1
}

// Moves to the next/previous change and scrolls it into view.
// Called inside the grid's window; the scroll applies from the next frame.
@(private = "file")
grid_step :: proc(ctx: ^ui.UiContext, state: ^Workbench, sheet: ^workspace.Grid_Sheet, forward: bool, scale: f32) {
	grid_select_change(state, sheet, forward)
	grid := &state.grid
	i := grid_list_index(sheet, grid.changes_only, grid.row)
	if i < 0 do return
	window := &ctx.windows[ctx.window_index]
	window.scroll_offset.y = max(0, (f32(i) - 4) * GRID_ROW_HEIGHT * scale)
	// Arrow keys continue from here.
	ctx.focus_id = ui.make_id("grid-cells", window.id)
}

@(private = "file")
workbench_sheet_tabs :: proc(ctx: ^ui.UiContext, face: ^font_core.Face, state: ^Workbench, book: ^workspace.Workbook_Grid,
	x, y, w, scale: f32) {
	grid := &state.grid
	theme_box(ctx, {x, y - 1, w, 1}, GRID_GAP_LINE, 0, scale)
	sheet := &book.sheets[grid.sheet]
	stats_w: f32 = 210
	stats := fmt.tprintf("+%d  −%d  ~%d rows", sheet.added_rows, sheet.removed_rows, sheet.modified_rows)
	theme_label(ctx, face, stats, {x + w - stats_w, y + 2, stats_w, GRID_TABS_HEIGHT - 4}, 12, THEME_MUTED, scale, {.RIGHT})
	limit := x + w - stats_w - 8
	tab_x := x
	grid.first_tab = clamp(grid.first_tab, 0, len(book.sheets) - 1)
	if grid.first_tab > 0 {
		if workbench_button(ctx, face, "‹", {tab_x, y + 2, 26, 24}, scale, id = "grid-tabs-left") do grid.first_tab -= 1
		tab_x += 30
	}
	for i in grid.first_tab..<len(book.sheets) {
		tab_sheet := &book.sheets[i]
		marker := ""
		switch {
		case tab_sheet.added: marker = "new"
		case tab_sheet.removed: marker = "removed"
		case len(tab_sheet.changes) > 0: marker = fmt.tprintf("%d", len(tab_sheet.changes))
		}
		tab_w := theme_text_width(ctx, face, tab_sheet.name, 12, scale) + 28
		marker_w: f32 = marker != "" ? theme_text_width(ctx, face, marker, 10, scale) + 14 : 0
		if tab_x + tab_w + marker_w > limit - 30 {
			if workbench_button(ctx, face, "›", {limit - 26, y + 2, 26, 24}, scale, id = "grid-tabs-right") do grid.first_tab += 1
			break
		}
		active := i == grid.sheet
		style := workbench_control_style(face, scale)
		style.radius = 0
		style.padding = 14 * scale
		style.font_size = 12 * scale
		style.color_top = active ? GRID_CELL : GRID_HEADER_FILL
		style.color_bottom = style.color_top
		style.hover_color = active ? GRID_CELL : THEME_HOVER
		style.text_color = active ? THEME_TEXT : THEME_MUTED
		ui.style_push(ctx, style)
		tab_rect := theme_rect({tab_x, y, tab_w + marker_w, GRID_TABS_HEIGHT - 2}, scale)
		if ui.button(ctx, tab_sheet.name, tab_rect, {.NONE}, id = fmt.tprintf("grid-tab-%d", i)) == .SUBMIT && !active {
			grid.sheet, grid.row = i, -1
			workbench_reset_windows(ctx, "commit-diff")
		}
		ui.style_pop(ctx)
		if active do theme_box(ctx, {tab_x, y + GRID_TABS_HEIGHT - 4, tab_w + marker_w, 3}, GRID_SELECTION, 0, scale)
		if marker != "" {
			fill, color := GRID_CHANGED, GRID_CHANGED_TEXT
			if tab_sheet.added do fill, color = THEME_ADDITION_STRONG, THEME_ADDITION_TEXT
			if tab_sheet.removed do fill, color = THEME_DELETION_STRONG, THEME_DELETION_TEXT
			theme_tag(ctx, face, marker, tab_x + tab_w - 10, y + 6, fill, color, scale, 16)
		}
		theme_box(ctx, {tab_x + tab_w + marker_w, y + 4, 1, GRID_TABS_HEIGHT - 10}, GRID_LINE, 0, scale)
		tab_x += tab_w + marker_w + 1
	}
}
