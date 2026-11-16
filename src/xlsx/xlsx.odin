package xlsx

import "base:runtime"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"

// Workbooks whose text form would exceed this are refused rather than diffed.
MAX_TEXT_SIZE :: 64 * 1024 * 1024
// Sparse rows: after this many empty columns, the next cell is written with
// its column letters ("AZ: value") instead of a run of empty separators.
MAX_EMPTY_RUN :: 5

CELL_SEPARATOR :: " | "

// Where a text line came from. `row` is the 1-based spreadsheet row, or 0 for
// a sheet's header line.
Line_Ref :: struct {
	sheet, row: int,
}

// A workbook rendered as text: a header line per sheet, then one line per
// non-empty row with its cells separated by CELL_SEPARATOR. Row numbers are
// kept in `lines` rather than in the text, so inserting a row does not make
// every following line differ.
Workbook_Text :: struct {
	text: string,
	// The same lines with formulas in relative R1C1 form ("=SUM(RC[-3]:RC[-1])"),
	// which does not change when rows or columns move. Diff this, show `text`.
	compare: string,
	display: []string, // Line i of `text`, without its newline.
	lines: []Line_Ref, // One per line of text.
	cells: [][]Sheet_Cell, // One per line of text; empty for sheet headers.
	sheets: []string,
	arena: ^virtual.Arena, // Owns everything above.
}

workbook_text_destroy :: proc(w: ^Workbook_Text, allocator := context.allocator) {
	if w.arena != nil {
		virtual.arena_destroy(w.arena)
		free(w.arena, allocator)
	}
	w^ = {}
}

// One non-empty cell of a row, for spreadsheet-like display.
Sheet_Cell :: struct {
	col: int,        // 1-based column.
	value: string,   // What Excel shows: the cached result for formulas.
	formula: string, // Without the leading "="; empty for plain values.
	compare: string, // The cell as the diff compares it (formulas in R1C1).
}

// True for the SpreadsheetML package formats this reader understands.
is_workbook_path :: proc(path: string) -> bool {
	lower := strings.to_lower(path, context.temp_allocator)
	return strings.has_suffix(lower, ".xlsx") || strings.has_suffix(lower, ".xlsm") ||
		strings.has_suffix(lower, ".xltx") || strings.has_suffix(lower, ".xltm")
}

@(private)
Relationship :: struct {
	id, type, target: string,
}

@(private)
Sheet_Info :: struct {
	name, rel_id, state: string,
}

@(private)
Shared_Formula :: struct {
	text: string,
	row, col: int,
}

@(private)
Cell :: struct {
	col: int,
	text, compare: string,
	value, formula: string,
}

@(private)
Reader :: struct {
	zip: Zip,
	shared_strings: [dynamic]string,
	out, compare: strings.Builder,
	lines: [dynamic]Line_Ref,
	cells: [dynamic][]Sheet_Cell,
}

// Converts .xlsx bytes to text. Returns a non-empty error when the workbook
// cannot be read; the result then owns nothing.
workbook_to_text :: proc(data: []u8, allocator := context.allocator) -> (Workbook_Text, string) {
	arena := new(virtual.Arena, allocator)
	if virtual.arena_init_growing(arena) != nil {
		free(arena, allocator)
		return {}, "out of memory"
	}
	result, err := convert_workbook(data, virtual.arena_allocator(arena))
	if err != "" {
		virtual.arena_destroy(arena)
		free(arena, allocator)
		return {}, err
	}
	result.arena = arena
	return result, ""
}

// Everything is allocated in `allocator` (the result's arena).
@(private)
convert_workbook :: proc(data: []u8, allocator: runtime.Allocator) -> (result: Workbook_Text, err: string) {
	context.allocator = allocator

	r: Reader
	r.out, r.compare = strings.builder_make(), strings.builder_make()
	if e := zip_open(&r.zip, data); e != "" do return result, e

	workbook := "xl/workbook.xml"
	if root, ok := read_part(&r, "_rels/.rels"); ok {
		for rel in parse_relationships(root, "") do if strings.has_suffix(rel.type, "/officeDocument") do workbook = rel.target
	}
	workbook_xml, found := read_part(&r, workbook)
	if !found do return result, "not an Excel workbook (no workbook part)"
	base := part_dir(workbook)
	rels_xml, _ := read_part(&r, strings.concatenate({base, "_rels/", workbook[len(base):], ".rels"}))
	rels := parse_relationships(rels_xml, base)

	shared := strings.concatenate({base, "sharedStrings.xml"})
	for rel in rels do if strings.has_suffix(rel.type, "/sharedStrings") do shared = rel.target
	if sst, ok := read_part(&r, shared); ok do parse_shared_strings(&r, sst)

	sheets := parse_sheets(workbook_xml)
	names := make([]string, len(sheets))
	for sheet, i in sheets {
		names[i] = sheet.name
		header_start := strings.builder_len(r.out)
		strings.write_string(&r.out, "=== ")
		strings.write_string(&r.out, sheet.name)
		strings.write_string(&r.out, " ===")
		if sheet.state != "" && sheet.state != "visible" {
			strings.write_string(&r.out, " (")
			strings.write_string(&r.out, sheet.state)
			strings.write_string(&r.out, ")")
		}
		target, type: string
		for rel in rels do if rel.id == sheet.rel_id do target, type = rel.target, rel.type
		sheet_xml, ok := read_part(&r, target)
		switch {
		case !ok: strings.write_string(&r.out, " (missing)")
		case !strings.has_suffix(type, "/worksheet"): strings.write_string(&r.out, " (no cells: chart or other sheet type)")
		}
		strings.write_byte(&r.out, '\n')
		strings.write_string(&r.compare, strings.to_string(r.out)[header_start:])
		append(&r.lines, Line_Ref{i, 0})
		append(&r.cells, nil)
		if ok && strings.has_suffix(type, "/worksheet") {
			if e := parse_worksheet(&r, sheet_xml, i); e != "" do return result, e
		}
	}
	result.text = strings.to_string(r.out)
	result.compare = strings.to_string(r.compare)
	if len(result.text) > 0 do result.display = strings.split(result.text[:len(result.text) - 1], "\n")
	assert(len(result.display) == len(r.lines))
	result.lines = r.lines[:]
	result.cells = r.cells[:]
	result.sheets = names
	return result, ""
}

// Reads a part as text; a missing or unreadable part reports false.
@(private)
read_part :: proc(r: ^Reader, path: string) -> (string, bool) {
	if path == "" do return "", false
	e, found := zip_find(&r.zip, path)
	if !found do return "", false
	bytes, err := zip_read(&r.zip, e)
	if err != "" do return "", false
	text := string(bytes)
	if strings.has_prefix(text, "\xEF\xBB\xBF") do text = text[3:]
	return text, true
}

@(private)
part_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	return i < 0 ? "" : path[:i + 1]
}

// Resolves a relationship target against the directory of its source part.
@(private)
resolve_target :: proc(base, target: string) -> string {
	joined := strings.has_prefix(target, "/") ? target[1:] : strings.concatenate({base, target})
	parts := make([dynamic]string)
	for part in strings.split_iterator(&joined, "/") {
		switch part {
		case "", ".":
		case "..": if len(parts) > 0 do pop(&parts)
		case: append(&parts, part)
		}
	}
	return strings.join(parts[:], "/")
}

@(private)
parse_relationships :: proc(src, base: string) -> []Relationship {
	out := make([dynamic]Relationship)
	x := Xml{src = src}
	for xml_next(&x) {
		if x.kind != .START || x.name != "Relationship" do continue
		mode, _ := xml_attr(&x, "TargetMode")
		if mode == "External" do continue
		id, _ := xml_attr(&x, "Id")
		type, _ := xml_attr(&x, "Type")
		target, _ := xml_attr(&x, "Target")
		append(&out, Relationship{xml_decoded(id), xml_decoded(type), resolve_target(base, xml_decoded(target))})
	}
	return out[:]
}

@(private)
parse_sheets :: proc(src: string) -> []Sheet_Info {
	out := make([dynamic]Sheet_Info)
	x := Xml{src = src}
	for xml_next(&x) {
		if x.kind != .START || x.name != "sheet" do continue
		name, _ := xml_attr(&x, "name")
		id, _ := xml_attr(&x, "id") // r:id
		state, _ := xml_attr(&x, "state")
		append(&out, Sheet_Info{xml_decoded(name), xml_decoded(id), state})
	}
	return out[:]
}

// Each <si> is plain (<t>) or rich text (several <r><t>); phonetic guides
// (<rPh>) are not part of the displayed value.
@(private)
parse_shared_strings :: proc(r: ^Reader, src: string) {
	x := Xml{src = src}
	b := strings.builder_make()
	in_t, phonetic := false, 0
	for xml_next(&x) {
		switch x.kind {
		case .START:
			switch x.name {
			case "si": strings.builder_reset(&b)
			case "t": in_t = true
			case "rPh": phonetic += 1
			}
		case .END:
			switch x.name {
			case "si": append(&r.shared_strings, strings.clone(strings.to_string(b)))
			case "t": in_t = false
			case "rPh": phonetic -= 1
			}
		case .TEXT:
			if in_t && phonetic == 0 do append_text(&b, &x)
		case .EOF:
		}
	}
}

@(private)
append_text :: proc(b: ^strings.Builder, x: ^Xml) {
	if x.cdata {
		strings.write_string(b, x.text)
	} else {
		xml_decode(b, x.text, excel = true)
	}
}

// Column letters to a 1-based index ("A" = 1, "AA" = 27); 0 when invalid.
column_index :: proc(letters: string) -> int {
	n := 0
	for ch in transmute([]u8)letters {
		up := ch >= 'a' && ch <= 'z' ? ch - 32 : ch
		if up < 'A' || up > 'Z' do return 0
		n = n * 26 + int(up - 'A' + 1)
		if n > 16384 do return 0
	}
	return n
}

column_letters :: proc(col: int, buf: []u8) -> string {
	n, i := col, len(buf)
	for n > 0 && i > 0 {
		n -= 1
		i -= 1
		buf[i] = 'A' + u8(n % 26)
		n /= 26
	}
	return string(buf[i:])
}

// Splits "B12" into column 2, row 12; zeroes when not a cell reference.
@(private)
split_ref :: proc(ref: string) -> (col, row: int) {
	i := 0
	for i < len(ref) && ((ref[i] >= 'A' && ref[i] <= 'Z') || (ref[i] >= 'a' && ref[i] <= 'z')) do i += 1
	col = column_index(ref[:i])
	v, ok := strconv.parse_int(ref[i:], 10)
	if !ok || col == 0 do return 0, 0
	return col, v
}

@(private)
parse_worksheet :: proc(r: ^Reader, src: string, sheet: int) -> string {
	x := Xml{src = src}
	shared: map[int]Shared_Formula
	cells := make([dynamic]Cell)
	value, formula, inline := strings.builder_make(), strings.builder_make(), strings.builder_make()
	row, prev_col := 0, 0
	type: string
	has_formula, has_value := false, false
	cell_col, shared_index := 0, -1
	shared_master := false
	capture: ^strings.Builder
	in_sheet_data, in_inline_t := false, false
	for xml_next(&x) {
		switch x.kind {
		case .START:
			switch x.name {
			case "sheetData": in_sheet_data = true
			case "row":
				if !in_sheet_data do continue
				clear(&cells)
				next_row := row + 1
				if v, ok := xml_attr(&x, "r"); ok {
					if n, valid := strconv.parse_int(v, 10); valid do next_row = n
				}
				row = next_row
				prev_col = 0
			case "c":
				if !in_sheet_data do continue
				type, _ = xml_attr(&x, "t")
				cell_col = prev_col + 1
				if ref, ok := xml_attr(&x, "r"); ok {
					if c, _ := split_ref(ref); c > 0 do cell_col = c
				}
				prev_col = cell_col
				strings.builder_reset(&value)
				strings.builder_reset(&formula)
				strings.builder_reset(&inline)
				has_formula, has_value, shared_index, shared_master = false, false, -1, false
			case "f":
				has_formula = true
				capture = &formula
				if t, _ := xml_attr(&x, "t"); t == "shared" {
					if si, ok := xml_attr(&x, "si"); ok {
						if n, valid := strconv.parse_int(si, 10); valid do shared_index = n
					}
					_, shared_master = xml_attr(&x, "ref")
				}
			case "v":
				has_value = true
				capture = &value
			case "t":
				in_inline_t = true
			}
		case .TEXT:
			if capture != nil {
				append_text(capture, &x)
			} else if in_inline_t {
				append_text(&inline, &x)
			}
		case .END:
			switch x.name {
			case "sheetData": in_sheet_data = false
			case "f", "v": capture = nil
			case "t": in_inline_t = false
			case "c":
				if !in_sheet_data do continue
				f := strings.to_string(formula)
				if shared_index >= 0 {
					if shared_master && f != "" {
						shared[shared_index] = Shared_Formula{strings.clone(f), row, cell_col}
					} else if f == "" {
						if master, ok := shared[shared_index]; ok {
							b := strings.builder_make()
							shift_formula(&b, master.text, row - master.row, cell_col - master.col)
							f = strings.to_string(b)
						}
					}
				}
				text, compare, shown, formula_text := cell_text(r, type, strings.to_string(value), has_value, strings.to_string(inline), f, has_formula, row, cell_col)
				if text != "" do append(&cells, Cell{cell_col, text, compare, shown, formula_text})
			case "row":
				if !in_sheet_data do continue
				if len(cells) > 0 {
					if e := write_row(r, cells[:], sheet, row); e != "" do return e
				}
				clear(&cells)
			}
		case .EOF:
		}
	}
	if x.failed do return "a worksheet contains malformed XML"
	return ""
}

@(private)
cell_text :: proc(r: ^Reader, type, raw: string, has_value: bool, inline, formula: string, has_formula: bool, row, col: int) -> (text, compare, value, formula_text: string) {
	shown := raw
	switch type {
	case "s":
		if n, ok := strconv.parse_int(strings.trim_space(raw), 10); ok && n >= 0 && n < len(r.shared_strings) do shown = r.shared_strings[n]
	case "b":
		if has_value do shown = strings.trim_space(raw) == "1" ? "TRUE" : "FALSE"
	case "inlineStr":
		shown = inline
	}
	if has_formula && formula != "" {
		b := strings.builder_make()
		formula_to_r1c1(&b, formula, row, col)
		relative := strings.to_string(b)
		// `shown` and `formula` may borrow builders reused by the next cell.
		kept := strings.clone(formula)
		if shown == "" do return strings.concatenate({"=", formula}), strings.concatenate({"=", relative}), "", kept
		return strings.concatenate({"=", formula, " [", shown, "]"}), strings.concatenate({"=", relative, " [", shown, "]"}), strings.clone(shown), kept
	}
	text = strings.clone(shown)
	return text, text, text, ""
}

// Writes the row as a single line: newlines inside cells become "\n" and other
// control characters become spaces, so one row is always one line of text.
@(private)
write_row :: proc(r: ^Reader, cells: []Cell, sheet, row: int) -> string {
	write_cells(&r.out, cells, false)
	write_cells(&r.compare, cells, true)
	append(&r.lines, Line_Ref{sheet, row})
	structured := make([]Sheet_Cell, len(cells))
	for c, i in cells do structured[i] = Sheet_Cell{c.col, c.value, c.formula, c.compare}
	append(&r.cells, structured)
	if strings.builder_len(r.out) > MAX_TEXT_SIZE do return "the workbook is too large to compare as text"
	return ""
}

@(private)
write_cells :: proc(b: ^strings.Builder, cells: []Cell, compare: bool) {
	col := 0
	for c, i in cells {
		cell := c
		if compare do cell.text = c.compare
		gap := cell.col - col - 1
		if i > 0 do strings.write_string(b, CELL_SEPARATOR)
		if gap > MAX_EMPTY_RUN || cell.col <= col {
			// Out-of-order cells are labeled too, so nothing is silently misplaced.
			buf: [4]u8
			strings.write_string(b, column_letters(cell.col, buf[:]))
			strings.write_string(b, ": ")
		} else {
			for _ in 0..<gap do strings.write_string(b, CELL_SEPARATOR)
		}
		for j := 0; j < len(cell.text); j += 1 {
			ch := cell.text[j]
			if ch == '\r' && j + 1 < len(cell.text) && cell.text[j + 1] == '\n' do continue
			if ch == '\r' || ch == '\n' {
				strings.write_string(b, "\\n")
			} else if ch != '\t' && (ch < 0x20 || ch == 0x7F) {
				strings.write_byte(b, ' ')
			} else {
				strings.write_byte(b, ch)
			}
		}
		col = cell.col
	}
	strings.write_byte(b, '\n')
}

@(private)
is_name_char :: proc(ch: u8) -> bool {
	return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '.' || ch >= 0x80
}

// Rewrites a shared formula for a cell `drow` rows and `dcol` columns away from
// the formula's master cell: relative references move, $-anchored parts stay.
// Strings, quoted sheet names and structured references are copied unchanged.
shift_formula :: proc(b: ^strings.Builder, f: string, drow, dcol: int) {
	rewrite_formula(b, f, drow, dcol, {})
}

// Writes the formula of the cell at (row, col) in R1C1 notation: relative parts
// become offsets from the cell (RC[-3], R[1]C), absolute parts stay numbered
// (R2C2). The same per-row formula reads identically on every row.
formula_to_r1c1 :: proc(b: ^strings.Builder, f: string, row, col: int) {
	rewrite_formula(b, f, 0, 0, {row, col})
}

@(private)
rewrite_formula :: proc(b: ^strings.Builder, f: string, drow, dcol: int, r1c1: [2]int) {
	i := 0
	for i < len(f) {
		ch := f[i]
		switch {
		case ch == '"' || ch == '\'':
			j := i + 1
			for j < len(f) {
				if f[j] == ch {
					if j + 1 < len(f) && f[j + 1] == ch { j += 2; continue }
					break
				}
				j += 1
			}
			j = min(j + 1, len(f))
			strings.write_string(b, f[i:j])
			i = j
		case ch == '[':
			depth, j := 0, i
			for j < len(f) {
				if f[j] == '[' do depth += 1
				if f[j] == ']' { depth -= 1; if depth == 0 { j += 1; break } }
				j += 1
			}
			strings.write_string(b, f[i:min(j, len(f))])
			i = min(j, len(f))
		case ch == '$' || (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_':
			if n := try_shift_ref(b, f, i, drow, dcol, r1c1); n > 0 {
				i += n
				continue
			}
			j := i + 1
			for j < len(f) && (is_name_char(f[j]) || f[j] == '$') do j += 1
			strings.write_string(b, f[i:j])
			i = j
		case:
			strings.write_byte(b, ch)
			i += 1
		}
	}
}

// Matches $?COL$?ROW at f[i:] as a whole token; writes it shifted and returns
// its length, or 0 when the token is a name, function or something else.
@(private)
try_shift_ref :: proc(b: ^strings.Builder, f: string, i, drow, dcol: int, r1c1: [2]int) -> int {
	if i > 0 && is_name_char(f[i - 1]) do return 0
	j := i
	col_abs := j < len(f) && f[j] == '$'
	if col_abs do j += 1
	cs := j
	for j < len(f) && j - cs < 3 && ((f[j] >= 'A' && f[j] <= 'Z') || (f[j] >= 'a' && f[j] <= 'z')) do j += 1
	letters := f[cs:j]
	if letters == "" do return 0
	row_abs := j < len(f) && f[j] == '$'
	if row_abs do j += 1
	rs := j
	for j < len(f) && f[j] >= '0' && f[j] <= '9' do j += 1
	digits := f[rs:j]
	if digits == "" || (j < len(f) && (is_name_char(f[j]) || f[j] == '(' || f[j] == '!')) do return 0
	col := column_index(letters)
	row, ok := strconv.parse_int(digits, 10)
	if col == 0 || !ok do return 0
	if r1c1 != {} {
		// R1C1: absolute parts keep their number, relative parts become offsets.
		part :: proc(b: ^strings.Builder, letter: u8, value, origin: int, absolute: bool) {
			strings.write_byte(b, letter)
			if absolute {
				strings.write_int(b, value)
			} else if value != origin {
				strings.write_byte(b, '[')
				strings.write_int(b, value - origin)
				strings.write_byte(b, ']')
			}
		}
		part(b, 'R', row, r1c1[0], row_abs)
		part(b, 'C', col, r1c1[1], col_abs)
		return j - i
	}
	if !col_abs do col += dcol
	if !row_abs do row += drow
	if col < 1 || col > 16384 || row < 1 || row > 1048576 {
		strings.write_string(b, "#REF!")
		return j - i
	}
	buf: [4]u8
	if col_abs do strings.write_byte(b, '$')
	strings.write_string(b, column_letters(col, buf[:]))
	if row_abs do strings.write_byte(b, '$')
	strings.write_int(b, row)
	return j - i
}
