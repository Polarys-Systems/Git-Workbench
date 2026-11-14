package workspace

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import git "../git"
import xlsx "../xlsx"

// A one-sheet workbook ("Budget") whose rows are comma-separated inline strings.
// `styled` changes only cell formatting; "=F~V" is a formula F with cached value V.
test_workbook :: proc(rows: []string, styled := false) -> []u8 {
	sheet := strings.builder_make(context.temp_allocator)
	strings.write_string(&sheet, `<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>`)
	for row, i in rows {
		fmt.sbprintf(&sheet, `<row r="%d">`, i + 1)
		cells := row
		for cell in strings.split_iterator(&cells, ",") {
			if strings.has_prefix(cell, "=") { // "=FORMULA~cached value"
				formula, _, value := strings.partition(cell[1:], "~")
				fmt.sbprintf(&sheet, `<c><f>%s</f><v>%s</v></c>`, formula, value)
				continue
			}
			fmt.sbprintf(&sheet, `<c t="inlineStr"%s><is><t>%s</t></is></c>`, styled ? ` s="1"` : "", cell)
		}
		strings.write_string(&sheet, "</row>")
	}
	strings.write_string(&sheet, "</sheetData></worksheet>")
	parts := [?]xlsx.Zip_Part{
		{"xl/workbook.xml", `<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Budget" sheetId="1" r:id="rId1"/></sheets></workbook>`},
		{"xl/_rels/workbook.xml.rels", `<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>`},
		{"xl/worksheets/sheet1.xml", strings.to_string(sheet)},
	}
	return xlsx.zip_write_stored(parts[:], allocator = context.temp_allocator)
}

@(test)
workbook_changes_use_rows_and_sheets :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !test_ok(t, git.repository_init(&repo, cstring_temp(root), 0)) do return
	defer git.repository_free(repo)
	_ = test_ok(t, git.repository_set_head(repo, "refs/heads/main"))
	settings: ^git.Config
	if !test_ok(t, git.repository_config(&settings, repo)) do return
	_ = test_ok(t, git.config_set_string(settings, "user.name", "Workbook fixture"))
	_ = test_ok(t, git.config_set_string(settings, "user.email", "workbook@example.invalid"))
	git.config_free(settings)
	path := fmt.tprintf("%s/Budget.xlsx", root)
	testing.expect(t, os.write_entire_file(path, test_workbook({"Item,Cost", "Rent,1000", "Food,300", "Fun,50"})) == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	_ = test_commit(t, repo, "Add budget")
	// Insert a row above the others and change one value.
	testing.expect(t, os.write_entire_file(path, test_workbook({"Item,Cost", "Travel,200", "Rent,1000", "Food,350", "Fun,50"})) == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	_ = test_commit(t, repo, "Update budget")

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Reader", "reader@example.invalid"}) == "") do return
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	if test_changed_file(t, &model, "Budget.xlsx") {
		file := model.changes.file
		testing.expect(t, file.workbook && !file.binary && file.note == "")
		testing.expect(t, file.additions == 2 && file.deletions == 1)
		testing.expect(t, len(file.lines) > 0 && file.lines[0].kind == .HUNK && file.lines[0].text == "Sheet: Budget")
		// Line numbers are spreadsheet rows, so shifted rows stay matched.
		test_change_line(t, file, .CONTEXT, "=== Budget ===", 0, 0)
		test_change_line(t, file, .CONTEXT, "Item | Cost", 1, 1)
		test_change_line(t, file, .ADDITION, "Travel | 200", 0, 2)
		test_change_line(t, file, .CONTEXT, "Rent | 1000", 2, 3)
		test_change_line(t, file, .DELETION, "Food | 300", 3, 0)
		test_change_line(t, file, .ADDITION, "Food | 350", 0, 4)
		test_change_line(t, file, .CONTEXT, "Fun | 50", 4, 5)
		// Only the changed cell is highlighted: "Food | " is 7 columns wide.
		test_spans(t, file, "Food | 300", {{7, 10}})
		test_spans(t, file, "Food | 350", {{7, 10}})
		test_spans(t, file, "Travel | 200", {}) // Inserted row: no counterpart.
	}
	if !testing.expect(t, select_commit(&model, 1) == "") do return
	if test_changed_file(t, &model, "Budget.xlsx") {
		testing.expect(t, model.changes.file.workbook && model.changes.file.additions == 5 && model.changes.file.deletions == 0)
		test_change_line(t, model.changes.file, .ADDITION, "Fun | 50", 0, 4)
	}

	// Working tree: the new side is read from disk; unreadable files explain why.
	testing.expect(t, os.write_entire_file(path, "not a workbook") == nil)
	if !testing.expect(t, select_working_changes(&model) == "") do return
	if test_changed_file(t, &model, "Budget.xlsx") {
		file := model.changes.file
		testing.expect(t, file.workbook && file.binary && len(file.lines) == 0)
		testing.expectf(t, strings.contains(file.note, "not a ZIP archive"), "note: %s", file.note)
	}
	testing.expect(t, os.write_entire_file(path, test_workbook({"Item,Cost", "Travel,200", "Rent,1000", "Food,350", "Fun,75"})) == nil)
	if !testing.expect(t, select_working_changes(&model) == "") do return
	if test_changed_file(t, &model, "Budget.xlsx") {
		test_change_line(t, model.changes.file, .DELETION, "Fun | 50", 5, 0)
		test_change_line(t, model.changes.file, .ADDITION, "Fun | 75", 0, 5)
	}
}

test_spans :: proc(t: ^testing.T, file: File_Changes, text: string, want: []Cell_Span, loc := #caller_location) {
	for line in file.lines {
		if line.text != text || line.kind == .CONTEXT do continue
		got := file.spans[line.span_start:][:line.span_count]
		testing.expectf(t, slice.equal(got, want), "%s: spans %v, want %v", text, got, want, loc = loc)
		return
	}
	testing.expectf(t, false, "Changed line not found: %s", text, loc = loc)
}

test_workbook_repo :: proc(t: ^testing.T, root: string) -> (repo: ^git.Repository, ok: bool) {
	if !test_ok(t, git.repository_init(&repo, cstring_temp(root), 0)) do return nil, false
	_ = test_ok(t, git.repository_set_head(repo, "refs/heads/main"))
	settings: ^git.Config
	if !test_ok(t, git.repository_config(&settings, repo)) {
		git.repository_free(repo)
		return nil, false
	}
	_ = test_ok(t, git.config_set_string(settings, "user.name", "Workbook fixture"))
	_ = test_ok(t, git.config_set_string(settings, "user.email", "workbook@example.invalid"))
	git.config_free(settings)
	return repo, true
}

test_commit_file :: proc(t: ^testing.T, repo: ^git.Repository, path: string, data: []u8, message: string) {
	testing.expect(t, os.write_entire_file(path, data) == nil)
	if test_ok(t, git.stage_all(repo)) do _ = test_commit(t, repo, message)
}

@(test)
workbook_pairing_formatting_only_and_lfs :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo, ok := test_workbook_repo(t, root)
	if !ok do return
	defer git.repository_free(repo)
	path := fmt.tprintf("%s/Book.xlsx", root)
	test_commit_file(t, repo, path, test_workbook({"Apple,1", "Bread,2", "Cheese,3"}), "Three rows")
	// Three rows replaced by one: it pairs with the row that has the same key.
	test_commit_file(t, repo, path, test_workbook({"Bread,20"}), "One row")
	// Formatting only: the bytes change, the cells do not.
	test_commit_file(t, repo, path, test_workbook({"Bread,20"}, styled = true), "Style")

	// Git LFS: commits hold pointers; content comes from .git/lfs/objects.
	lfs_path := fmt.tprintf("%s/Lfs.xlsx", root)
	versions := [2][]u8{test_workbook({"Name,Qty", "Pen,4"}), test_workbook({"Name,Qty", "Pen,5"})}
	oids := [2]string{strings.repeat("ab", 32, context.temp_allocator), strings.repeat("cd", 32, context.temp_allocator)}
	pointer :: proc(oid: string, size: int) -> []u8 {
		return transmute([]u8)fmt.tprintf("version https://git-lfs.github.com/spec/v1\noid sha256:%s\nsize %d\n", oid, size)
	}
	store :: proc(t: ^testing.T, root, oid: string, data: []u8) {
		dir := fmt.tprintf("%s/.git/lfs/objects/%s/%s", root, oid[:2], oid[2:4])
		testing.expect(t, os.make_directory_all(dir) == nil)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", dir, oid), data) == nil)
	}
	store(t, root, oids[0], versions[0])
	test_commit_file(t, repo, lfs_path, pointer(oids[0], len(versions[0])), "LFS v1")
	test_commit_file(t, repo, lfs_path, pointer(oids[1], len(versions[1])), "LFS v2")

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Reader", "reader@example.invalid"}) == "") do return
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	if test_changed_file(t, &model, "Lfs.xlsx") {
		file := model.changes.file
		testing.expect(t, file.workbook && file.binary)
		testing.expectf(t, strings.contains(file.note, "This version is stored in Git LFS and has not been downloaded"), "note: %s", file.note)
	}
	// An incomplete download is reported, then a complete one is compared.
	store(t, root, oids[1], versions[1][:10])
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	if test_changed_file(t, &model, "Lfs.xlsx") do testing.expect(t, strings.contains(model.changes.file.note, "incomplete"))
	store(t, root, oids[1], versions[1])
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	if test_changed_file(t, &model, "Lfs.xlsx") {
		file := model.changes.file
		testing.expectf(t, file.workbook && !file.binary && file.note == "", "note: %s", file.note)
		test_change_line(t, file, .DELETION, "Pen | 4", 2, 0)
		test_change_line(t, file, .ADDITION, "Pen | 5", 0, 2)
		test_spans(t, file, "Pen | 5", {{6, 7}})
	}

	if !testing.expect(t, select_commit(&model, 2) == "") do return
	if test_changed_file(t, &model, "Book.xlsx") {
		file := model.changes.file
		testing.expect(t, file.workbook && !file.binary && file.note == "" && len(file.lines) == 0)
	}
	if !testing.expect(t, select_commit(&model, 3) == "") do return
	if test_changed_file(t, &model, "Book.xlsx") {
		file := model.changes.file
		test_spans(t, file, "Apple | 1", {})
		test_spans(t, file, "Bread | 2", {{8, 9}})
		test_spans(t, file, "Bread | 20", {{8, 10}})
		test_spans(t, file, "Cheese | 3", {})
	}
}

@(test)
lfs_pointer_parsing :: proc(t: ^testing.T) {
	oid := strings.repeat("0f", 32)
	defer delete(oid)
	text := fmt.aprintf("version https://git-lfs.github.com/spec/v1\r\noid sha256:%s\r\nsize 42\r\n", oid)
	defer delete(text)
	got, size, ok := lfs_pointer(transmute([]u8)text)
	testing.expect(t, ok && got == oid && size == 42)
	_, _, ok = lfs_pointer(transmute([]u8)string("version https://git-lfs.github.com/spec/v1\noid sha256:XYZ\nsize 1\n"))
	testing.expect(t, !ok)
	_, _, ok = lfs_pointer(transmute([]u8)string("PK\x03\x04 not a pointer"))
	testing.expect(t, !ok)
}

@(test)
workbook_formulas_follow_their_rows :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo, ok := test_workbook_repo(t, root)
	if !ok do return
	defer git.repository_free(repo)
	path := fmt.tprintf("%s/Totals.xlsx", root)
	test_commit_file(t, repo, path, test_workbook({"Item,Q1,Q2,Total", "Rent,10,20,=SUM(B2:C2)~30", "Food,3,4,=SUM(B3:C3)~7"}), "Totals")
	// A row inserted above: the formulas below now name their new rows, and Food's Q2 changes.
	test_commit_file(t, repo, path, test_workbook({"Item,Q1,Q2,Total", "Travel,1,1,=SUM(B2:C2)~2", "Rent,10,20,=SUM(B3:C3)~30", "Food,3,5,=SUM(B4:C4)~8"}), "Insert")
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Reader", "reader@example.invalid"}) == "") do return
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	if test_changed_file(t, &model, "Totals.xlsx") {
		file := model.changes.file
		testing.expectf(t, file.additions == 2 && file.deletions == 1, "+%d -%d", file.additions, file.deletions)
		// Unchanged apart from moving: context, shown in its new A1 form.
		test_change_line(t, file, .CONTEXT, "Rent | 10 | 20 | =SUM(B3:C3) [30]", 2, 3)
		test_change_line(t, file, .ADDITION, "Travel | 1 | 1 | =SUM(B2:C2) [2]", 0, 2)
		test_change_line(t, file, .DELETION, "Food | 3 | 4 | =SUM(B3:C3) [7]", 3, 0)
		test_change_line(t, file, .ADDITION, "Food | 3 | 5 | =SUM(B4:C4) [8]", 0, 4)
		// Q2 changed, and so did the total's cached value (7 -> 8). B3 -> B4 alone would not count.
		test_spans(t, file, "Food | 3 | 5 | =SUM(B4:C4) [8]", {{11, 12}, {15, 30}})
	}
}
