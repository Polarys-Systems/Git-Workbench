package workspace

import "core:c"
import "core:mem/virtual"
import "core:strings"
import "core:unicode/utf8"

import git "../git"
import xlsx "../xlsx"

// Workbook changes laid out like the spreadsheet itself: every row of every
// sheet, each marked unchanged, added, removed or modified, with the cells
// that differ flagged. Built from the same R1C1 comparison as the text diff,
// so a formula that only moved with its row is not a change.

Grid_Row_Kind :: enum u8 { SAME, ADDED, DELETED, MODIFIED }

Grid_Cell :: struct {
	col: int,
	// The cell in this version (the removed version for deleted rows).
	value, formula: string,
	// Modified rows: the previous version, and whether it differs.
	old_value, old_formula: string,
	changed: bool,
}

Grid_Row :: struct {
	kind: Grid_Row_Kind,
	row: int,     // Spreadsheet row in this version; 0 for deleted rows.
	old_row: int, // Spreadsheet row in the previous version; 0 for added rows.
	cells: []Grid_Cell, // Sorted by column.
}

Grid_Sheet :: struct {
	name: string,
	added, removed: bool, // The whole sheet is new, or gone, in this version.
	rows: []Grid_Row,
	changes: []int, // Indices into rows of every row that is not SAME.
	added_rows, removed_rows, modified_rows: int,
	columns: int, // Highest column holding a value.
	widths: []int, // Column c's widest value in characters, at widths[c - 1].
}

Workbook_Grid :: struct {
	sheets: []Grid_Sheet,
	first_changed: int, // The sheet to show first.
	arena: ^virtual.Arena, // Owns everything above.
}

workbook_grid_destroy :: proc(grid: ^Workbook_Grid) {
	if grid.arena != nil {
		virtual.arena_destroy(grid.arena)
		free(grid.arena)
	}
	grid^ = {}
}

@(private = "file")
Grid_Entry :: struct {
	kind: Change_Kind,
	old_line, new_line: int, // 0-based lines of the two books; -1 when absent.
}

@(private = "file")
Sheet_Builder :: struct {
	name: string,
	seen_old, seen_new: bool,
	rows: [dynamic]Grid_Row,
	// Source cells of each row, for pairing deletions with additions.
	sources: [dynamic][]xlsx.Sheet_Cell,
}

// Keeps a cell on one line in the grid; the full text is in the cell itself.
@(private = "file")
grid_text :: proc(text: string) -> string {
	if !strings.contains_any(text, "\r\n\t") do return strings.clone(text)
	b := strings.builder_make()
	for i := 0; i < len(text); i += 1 {
		switch text[i] {
		case '\r':
			if i + 1 < len(text) && text[i + 1] == '\n' do continue
			strings.write_string(&b, " ⏎ ")
		case '\n': strings.write_string(&b, " ⏎ ")
		case '\t': strings.write_byte(&b, ' ')
		case: strings.write_byte(&b, text[i])
		}
	}
	return strings.to_string(b)
}

@(private = "file")
grid_cells :: proc(source: []xlsx.Sheet_Cell) -> []Grid_Cell {
	out := make([]Grid_Cell, len(source))
	for cell, i in source do out[i] = Grid_Cell{col = cell.col, value = grid_text(cell.value), formula = grid_text(cell.formula)}
	return out
}

// Pairs a removed row with its replacement: cells by column, flagged when
// the compared text (formulas in R1C1) differs.
@(private = "file")
grid_merge :: proc(old, new: []xlsx.Sheet_Cell) -> []Grid_Cell {
	out := make([dynamic]Grid_Cell, 0, max(len(old), len(new)))
	i, j := 0, 0
	for i < len(old) || j < len(new) {
		cell: Grid_Cell
		switch {
		case j >= len(new) || (i < len(old) && old[i].col < new[j].col):
			cell = Grid_Cell{col = old[i].col, old_value = grid_text(old[i].value), old_formula = grid_text(old[i].formula), changed = true}
			i += 1
		case i >= len(old) || new[j].col < old[i].col:
			cell = Grid_Cell{col = new[j].col, value = grid_text(new[j].value), formula = grid_text(new[j].formula), changed = true}
			j += 1
		case:
			cell = Grid_Cell{
				col = new[j].col, value = grid_text(new[j].value), formula = grid_text(new[j].formula),
				old_value = grid_text(old[i].value), old_formula = grid_text(old[i].formula),
				changed = old[i].compare != new[j].compare,
			}
			i += 1
			j += 1
		}
		append(&out, cell)
	}
	return out[:]
}

@(private = "file")
first_compare :: proc(cells: []xlsx.Sheet_Cell) -> string {
	return len(cells) > 0 ? cells[0].compare : ""
}

// Turns each run of removed rows followed by added rows into modified rows
// where they correspond: in order when the runs are the same length, else by
// equal first cells (usually a key), like the text diff's cell highlighting.
@(private = "file")
pair_rows :: proc(builder: ^Sheet_Builder) -> []Grid_Row {
	rows, sources := builder.rows[:], builder.sources[:]
	out := make([dynamic]Grid_Row, 0, len(rows))
	i := 0
	for i < len(rows) {
		if rows[i].kind != .DELETED {
			append(&out, rows[i])
			i += 1
			continue
		}
		d_start := i
		for i < len(rows) && rows[i].kind == .DELETED do i += 1
		a_start := i
		for i < len(rows) && rows[i].kind == .ADDED do i += 1
		deleted, added := rows[d_start:a_start], rows[a_start:i]
		partner := make([]int, len(added), context.temp_allocator)
		for &p in partner do p = -1
		used := make([]bool, len(deleted), context.temp_allocator)
		if len(deleted) == len(added) {
			for k in 0..<len(added) do partner[k], used[k] = k, true
		} else {
			for k in 0..<len(added) {
				key := first_compare(sources[a_start + k])
				for d in 0..<len(deleted) {
					if used[d] || first_compare(sources[d_start + d]) != key do continue
					partner[k], used[d] = d, true
					break
				}
			}
		}
		// Removed rows stay where they were relative to the rows paired around them.
		next_deleted := 0
		for k in 0..<len(added) {
			if partner[k] < 0 {
				append(&out, added[k])
				continue
			}
			d := partner[k]
			for ; next_deleted < d; next_deleted += 1 do if !used[next_deleted] do append(&out, deleted[next_deleted])
			next_deleted = max(next_deleted, d + 1)
			append(&out, Grid_Row{
				kind = .MODIFIED, row = added[k].row, old_row = deleted[d].old_row,
				cells = grid_merge(sources[d_start + d], sources[a_start + k]),
			})
		}
		for ; next_deleted < len(deleted); next_deleted += 1 do if !used[next_deleted] do append(&out, deleted[next_deleted])
	}
	return out[:]
}

// Builds the grid from both versions (either may be empty). Errors are
// temp-allocated, like git_error.
@(private)
build_workbook_grid :: proc(old_book, new_book: ^xlsx.Workbook_Text) -> (grid: Workbook_Grid, err: string) {
	arena := new(virtual.Arena)
	if virtual.arena_init_growing(arena) != nil {
		free(arena)
		return {}, "out of memory"
	}
	succeeded := false
	defer if !succeeded {
		virtual.arena_destroy(arena)
		free(arena)
	}
	entries := make([dynamic]Grid_Entry, context.temp_allocator)
	{
		// Context as long as the workbook keeps every row in a single hunk.
		options: git.Diff_Options
		if git.diff_options_init(&options, git.DIFF_OPTIONS_VERSION) != git.OK do return {}, git_error("Could not initialize the comparison")
		options.flags = git.DIFF_FORCE_TEXT
		options.context_lines = u32(max(len(old_book.lines), len(new_book.lines)) + 1)
		patch: ^git.Patch
		if git.patch_from_buffers(&patch, raw_data(old_book.compare), c.size_t(len(old_book.compare)), "a.xlsx",
			raw_data(new_book.compare), c.size_t(len(new_book.compare)), "b.xlsx", &options) != git.OK {
			return {}, git_error("Could not compare the workbook versions")
		}
		defer git.patch_free(patch)
		hunks := patch != nil ? git.patch_num_hunks(patch) : 0
		for h in 0..<hunks {
			count: c.size_t
			hunk: ^git.Diff_Hunk
			if git.patch_get_hunk(&hunk, &count, patch, h) != git.OK do return {}, git_error("Could not read a diff hunk")
			for k in 0..<count {
				line: ^git.Diff_Line
				if git.patch_get_line_in_hunk(&line, patch, h, k) != git.OK do return {}, git_error("Could not read a changed line")
				kind: Change_Kind
				switch u8(line.origin) {
				case '+': kind = .ADDITION
				case '-': kind = .DELETION
				case ' ': kind = .CONTEXT
				case: continue
				}
				append(&entries, Grid_Entry{kind, int(line.old_lineno) - 1, int(line.new_lineno) - 1})
			}
		}
		if hunks == 0 {
			// Identical versions: every line is unchanged.
			for i in 0..<len(new_book.lines) do append(&entries, Grid_Entry{.CONTEXT, i, i})
		}
	}

	context.allocator = virtual.arena_allocator(arena)
	builders := make([dynamic]Sheet_Builder, context.temp_allocator)
	sheet_of :: proc(builders: ^[dynamic]Sheet_Builder, name: string) -> ^Sheet_Builder {
		for &b in builders do if b.name == name do return &b
		append(builders, Sheet_Builder{name = strings.clone(name)})
		return &builders[len(builders) - 1]
	}
	for entry in entries {
		deleted := entry.kind == .DELETION
		book := deleted ? old_book : new_book
		index := deleted ? entry.old_line : entry.new_line
		if index < 0 || index >= len(book.lines) do continue
		ref := book.lines[index]
		builder := sheet_of(&builders, book.sheets[ref.sheet])
		if ref.row == 0 {
			// Sheet headers say which versions have the sheet.
			if entry.kind != .ADDITION do builder.seen_old = true
			if entry.kind != .DELETION do builder.seen_new = true
			continue
		}
		cells := book.cells[index]
		row := Grid_Row{row = ref.row}
		switch entry.kind {
		case .ADDITION: row.kind = .ADDED
		case .DELETION: row.kind, row.row, row.old_row = .DELETED, 0, ref.row
		case .CONTEXT, .HUNK, .NOTE:
			row.kind = .SAME
			if entry.old_line >= 0 && entry.old_line < len(old_book.lines) do row.old_row = old_book.lines[entry.old_line].row
		}
		row.cells = grid_cells(cells)
		append(&builder.rows, row)
		append(&builder.sources, cells)
	}

	sheets := make([]Grid_Sheet, len(builders))
	grid.first_changed = -1
	for &builder, s in builders {
		sheet := &sheets[s]
		sheet.name = builder.name
		sheet.added = builder.seen_new && !builder.seen_old && len(old_book.lines) > 0
		sheet.removed = builder.seen_old && !builder.seen_new
		sheet.rows = pair_rows(&builder)
		changes := make([dynamic]int)
		for row, i in sheet.rows {
			for cell in row.cells do sheet.columns = max(sheet.columns, cell.col)
			switch row.kind {
			case .SAME: continue
			case .ADDED: sheet.added_rows += 1
			case .DELETED: sheet.removed_rows += 1
			case .MODIFIED: sheet.modified_rows += 1
			}
			append(&changes, i)
		}
		sheet.changes = changes[:]
		sheet.widths = make([]int, sheet.columns)
		for row in sheet.rows {
			for cell in row.cells {
				shown := cell.value != "" ? cell.value : cell.formula
				width := utf8.rune_count(shown) + (cell.value == "" && cell.formula != "" ? 1 : 0)
				width = max(width, utf8.rune_count(cell.old_value))
				sheet.widths[cell.col - 1] = max(sheet.widths[cell.col - 1], width)
			}
		}
		if grid.first_changed < 0 && (len(sheet.changes) > 0 || sheet.added || sheet.removed) do grid.first_changed = s
	}
	grid.first_changed = max(grid.first_changed, 0)
	grid.sheets = sheets
	grid.arena = arena
	succeeded = true
	return grid, ""
}
