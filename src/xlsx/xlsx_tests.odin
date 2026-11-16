package xlsx

import "core:strings"
import "core:testing"

TEST_PARTS :: [?]Zip_Part{
	{"_rels/.rels", #load("testdata/workbook/_rels/.rels", string)},
	{"xl/workbook.xml", #load("testdata/workbook/xl/workbook.xml", string)},
	{"xl/_rels/workbook.xml.rels", #load("testdata/workbook/xl/_rels/workbook.xml.rels", string)},
	{"xl/sharedStrings.xml", #load("testdata/workbook/xl/sharedStrings.xml", string)},
	{"xl/worksheets/sheet1.xml", #load("testdata/workbook/xl/worksheets/sheet1.xml", string)},
	{"xl/worksheets/sheet2.xml", #load("testdata/workbook/xl/worksheets/sheet2.xml", string)},
	{"xl/chartsheets/sheet1.xml", #load("testdata/workbook/xl/chartsheets/sheet1.xml", string)},
}

// Written by Windows PowerShell's Compress-Archive from testdata/workbook:
// deflated entries with backslash-separated names.
DEFLATED_FIXTURE :: #load("testdata/deflated.xlsx")

EXPECTED_TEXT :: "=== Data & Totals ===\n" +
	"Name | Amount | Total\n" +
	"Line1\\nLine2 | 12.5 | =B2*$B$2+SUM(B2:B3) [156.25]\n" +
	"Bob & Co | 3 | =B3*$B$2+SUM(B3:B4) [40.5] | TRUE\n" +
	" | =A1&\"x\" [Namex] | AZ: #N/A\n" +
	"=== Notes === (hidden)\n" +
	"1 | 2\n" +
	"=== Chart === (no cells: chart or other sheet type)\n"

// The copied-down formula reads the same on rows 2 and 3.
EXPECTED_COMPARE :: "=== Data & Totals ===\n" +
	"Name | Amount | Total\n" +
	"Line1\\nLine2 | 12.5 | =RC[-1]*R2C2+SUM(RC[-1]:R[1]C[-1]) [156.25]\n" +
	"Bob & Co | 3 | =RC[-1]*R2C2+SUM(RC[-1]:R[1]C[-1]) [40.5] | TRUE\n" +
	" | =R[-6]C[-1]&\"x\" [Namex] | AZ: #N/A\n" +
	"=== Notes === (hidden)\n" +
	"1 | 2\n" +
	"=== Chart === (no cells: chart or other sheet type)\n"

EXPECTED_LINES :: [?]Line_Ref{{0, 0}, {0, 1}, {0, 2}, {0, 3}, {0, 7}, {1, 0}, {1, 1}, {2, 0}}

expect_workbook :: proc(t: ^testing.T, data: []u8) {
	w, err := workbook_to_text(data)
	defer workbook_text_destroy(&w)
	if !testing.expectf(t, err == "", "workbook_to_text failed: %s", err) do return
	testing.expectf(t, w.text == EXPECTED_TEXT, "unexpected text:\n%s", w.text)
	expected := EXPECTED_LINES
	testing.expect(t, len(w.lines) == len(expected))
	for line, i in w.lines do if i < len(expected) do testing.expectf(t, line == expected[i], "line %d: %v", i, line)
	testing.expect(t, len(w.sheets) == 3 && w.sheets[0] == "Data & Totals" && w.sheets[2] == "Chart")
	testing.expect(t, strings.count(w.text, "\n") == len(w.lines))
	testing.expectf(t, w.compare == EXPECTED_COMPARE, "unexpected compare text:\n%s", w.compare)
	testing.expect(t, len(w.display) == len(w.lines) && w.display[4] == " | =A1&\"x\" [Namex] | AZ: #N/A")
	// Structured cells keep each formula's own cached value (not the last one read).
	if !testing.expect(t, len(w.cells) == len(w.lines)) do return
	testing.expect(t, len(w.cells[0]) == 0 && len(w.cells[5]) == 0)
	cell :: proc(w: Workbook_Text, line, i: int) -> Sheet_Cell {
		return i < len(w.cells[line]) ? w.cells[line][i] : {}
	}
	first := cell(w, 2, 0)
	testing.expectf(t, first.col == 1 && strings.has_prefix(first.value, "Line1") && strings.has_suffix(first.value, "Line2") && first.formula == "", "%q", first)
	testing.expectf(t, cell(w, 2, 2).value == "156.25" && cell(w, 2, 2).formula == "B2*$B$2+SUM(B2:B3)", "%v", cell(w, 2, 2))
	testing.expectf(t, cell(w, 3, 2).value == "40.5" && cell(w, 3, 2).formula == "B3*$B$2+SUM(B3:B4)", "%v", cell(w, 3, 2))
	testing.expect(t, cell(w, 3, 3).value == "TRUE" && cell(w, 3, 3).col == 4)
	testing.expect(t, cell(w, 4, 0).col == 2 && cell(w, 4, 0).value == "Namex" && cell(w, 4, 0).formula == "A1&\"x\"")
	testing.expect(t, cell(w, 4, 1).col == 52 && cell(w, 4, 1).value == "#N/A")
}

@(test)
stored_workbook_to_text :: proc(t: ^testing.T) {
	parts := TEST_PARTS
	data := zip_write_stored(parts[:])
	defer delete(data)
	expect_workbook(t, data)
}

@(test)
deflated_workbook_with_backslash_names :: proc(t: ^testing.T) {
	expect_workbook(t, DEFLATED_FIXTURE)
}

@(test)
zip_lookup_and_damage :: proc(t: ^testing.T) {
	parts := [?]Zip_Part{{"Dir/File.XML", "hello"}}
	data := zip_write_stored(parts[:])
	defer delete(data)
	z: Zip
	defer zip_destroy(&z)
	if !testing.expect(t, zip_open(&z, data) == "") do return
	e, found := zip_find(&z, "dir\\file.xml")
	if !testing.expect(t, found) do return
	content, err := zip_read(&z, e)
	defer delete(content)
	testing.expect(t, err == "" && string(content) == "hello")
	_, missing := zip_find(&z, "dir/other.xml")
	testing.expect(t, !missing)

	// Flip a stored byte: the CRC check rejects it.
	data[30 + len("Dir/File.XML")] = 'j'
	_, err = zip_read(&z, e)
	testing.expect(t, err != "")

	enc := zip_write_stored(parts[:], flags = 1)
	defer delete(enc)
	z2: Zip
	defer zip_destroy(&z2)
	_ = zip_open(&z2, enc)
	e2, _ := zip_find(&z2, "Dir/File.XML")
	_, err = zip_read(&z2, e2)
	testing.expect(t, strings.contains(err, "password"))

	z3: Zip
	defer zip_destroy(&z3)
	testing.expect(t, zip_open(&z3, transmute([]u8)string("not a zip at all, just some text bytes")) != "")
	truncated: Zip
	defer zip_destroy(&truncated)
	testing.expect(t, zip_open(&truncated, data[:len(data) - 30]) != "")
}

@(test)
not_a_workbook :: proc(t: ^testing.T) {
	parts := [?]Zip_Part{{"word/document.xml", "<w:document/>"}}
	data := zip_write_stored(parts[:])
	defer delete(data)
	w, err := workbook_to_text(data)
	defer workbook_text_destroy(&w)
	testing.expect(t, err != "" && w.arena == nil)
}

@(test)
shared_formula_shifting :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, f: string, drow, dcol: int, expected: string, loc := #caller_location) {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		shift_formula(&b, f, drow, dcol)
		testing.expectf(t, strings.to_string(b) == expected, "%s -> %s, want %s", f, strings.to_string(b), expected, loc = loc)
	}
	check(t, "SUM(A1:B2)*$C$1+Sheet2!D4", 1, 1, "SUM(B2:C3)*$C$1+Sheet2!E5")
	check(t, "LOG10(A1)&\"A1\"&'My A1'!A1", 2, 0, "LOG10(A3)&\"A1\"&'My A1'!A3")
	check(t, "Table1[[#This Row],[Col A1]]+A$1+$A2", 3, 1, "Table1[[#This Row],[Col A1]]+B$1+$A5")
	check(t, "A1+XFD1", -1, 1, "#REF!+#REF!")
	check(t, "\"say \"\"A1\"\"\"&a1", 0, 1, "\"say \"\"A1\"\"\"&B1")
}

@(test)
xml_reader_basics :: proc(t: ^testing.T) {
	x := Xml{src = `<?xml version="1.0"?><!-- c --><a:root x='1 > 2' b:y="&lt;&#65;&#x42;&amp;"><e/>t<![CDATA[<raw>&amp;]]></a:root>`}
	testing.expect(t, xml_next(&x) && x.kind == .START && x.name == "root")
	v, ok := xml_attr(&x, "x")
	testing.expect(t, ok && v == "1 > 2")
	v, ok = xml_attr(&x, "y")
	decoded := xml_decoded(v)
	defer delete(decoded)
	testing.expect(t, ok && decoded == "<AB&")
	testing.expect(t, xml_next(&x) && x.kind == .START && x.name == "e")
	testing.expect(t, xml_next(&x) && x.kind == .END && x.name == "e")
	testing.expect(t, xml_next(&x) && x.kind == .TEXT && x.text == "t" && !x.cdata)
	testing.expect(t, xml_next(&x) && x.kind == .TEXT && x.text == "<raw>&amp;" && x.cdata)
	testing.expect(t, xml_next(&x) && x.kind == .END && x.name == "root")
	testing.expect(t, !xml_next(&x) && !x.failed)
	bad := Xml{src = "<a><b"}
	_ = xml_next(&bad)
	testing.expect(t, !xml_next(&bad) && bad.failed)
}

@(test)
column_names :: proc(t: ^testing.T) {
	buf: [4]u8
	testing.expect(t, column_letters(1, buf[:]) == "A")
	testing.expect(t, column_letters(52, buf[:]) == "AZ")
	testing.expect(t, column_letters(16384, buf[:]) == "XFD")
	testing.expect(t, column_index("xfd") == 16384 && column_index("XFE") == 0 && column_index("A1") == 0)
	testing.expect(t, is_workbook_path("Reports/Q3.XLSX") && is_workbook_path("m.xlsm") && !is_workbook_path("data.xls"))
}

@(test)
r1c1_formulas :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, f: string, row, col: int, expected: string, loc := #caller_location) {
		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		formula_to_r1c1(&b, f, row, col)
		testing.expectf(t, strings.to_string(b) == expected, "%s at R%dC%d -> %s, want %s", f, row, col, strings.to_string(b), expected, loc = loc)
	}
	check(t, "SUM(B3:D3)", 3, 5, "SUM(RC[-3]:RC[-1])")
	check(t, "SUM(B4:D4)", 4, 5, "SUM(RC[-3]:RC[-1])") // Same formula one row down.
	check(t, "$A$1+A$1+$A1+E3", 3, 5, "R1C1+R1C[-4]+R[-2]C1+RC")
	check(t, "Sheet2!B10&\"B10\"&LOG10(F2)", 2, 1, "Sheet2!R[8]C[1]&\"B10\"&LOG10(RC[5])")
}
