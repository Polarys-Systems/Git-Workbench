package workspace

import "core:fmt"
import "core:os"
import "core:slice"
import "core:testing"

import git "../git"

@(private = "file")
test_grid_row :: proc(t: ^testing.T, sheet: Grid_Sheet, i: int, kind: Grid_Row_Kind, row, old_row: int, first: string, loc := #caller_location) -> bool {
	if !testing.expectf(t, i < len(sheet.rows), "row %d missing (%d rows)", i, len(sheet.rows), loc = loc) do return false
	got := sheet.rows[i]
	value := len(got.cells) > 0 ? got.cells[0].value : ""
	return testing.expectf(t, got.kind == kind && got.row == row && got.old_row == old_row && value == first,
		"row %d: %v %d (was %d) %q, want %v %d (was %d) %q", i, got.kind, got.row, got.old_row, value, kind, row, old_row, first, loc = loc)
}

@(test)
workbook_grid_lays_out_every_row_and_flags_changed_cells :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo, ok := test_workbook_repo(t, root)
	if !ok do return
	defer git.repository_free(repo)
	path := fmt.tprintf("%s/Budget.xlsx", root)
	test_commit_file(t, repo, path, test_workbook({"Item,Cost", "Rent,1000", "Food,300", "Fun,50", "Total,=SUM(B2:B4)~1350"}), "Budget")
	// A row inserted above, one value changed, the total follows; Fun removed.
	test_commit_file(t, repo, path, test_workbook({"Item,Cost", "Travel,200", "Rent,1000", "Food,350", "Total,=SUM(B2:B4)~1550"}), "Update")
	test_commit_file(t, repo, path, test_workbook({"Apple,1", "Bread,2", "Cheese,3"}), "Replace")
	test_commit_file(t, repo, path, test_workbook({"Bread,20"}), "Shrink")

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Reader", "reader@example.invalid"}) == "") do return

	if !testing.expect(t, select_commit(&model, 2) == "") do return
	if !test_changed_file(t, &model, "Budget.xlsx") do return
	grid := model.changes.file.grid
	if !testing.expect(t, len(grid.sheets) == 1) do return
	sheet := grid.sheets[0]
	testing.expect(t, sheet.name == "Budget" && !sheet.added && !sheet.removed && grid.first_changed == 0)
	// Every row is present in sheet order; rows keep their numbers.
	test_grid_row(t, sheet, 0, .SAME, 1, 1, "Item")
	test_grid_row(t, sheet, 1, .ADDED, 2, 0, "Travel")
	test_grid_row(t, sheet, 2, .SAME, 3, 2, "Rent")
	test_grid_row(t, sheet, 3, .MODIFIED, 4, 3, "Food")
	test_grid_row(t, sheet, 4, .DELETED, 0, 4, "Fun")
	// SUM(B2:B4) became SUM(B2:B4) on a moved row: compared in R1C1 it changed
	// range and value, so it is a modified row with the formula kept apart.
	if test_grid_row(t, sheet, 5, .MODIFIED, 5, 5, "Total") {
		total := sheet.rows[5].cells[1]
		testing.expectf(t, total.changed && total.formula == "SUM(B2:B4)" && total.value == "1550" && total.old_value == "1350", "total: %v", total)
	}
	if len(sheet.rows) > 3 {
		food := sheet.rows[3].cells
		testing.expect(t, len(food) == 2 && !food[0].changed && food[1].changed && food[1].old_value == "300" && food[1].value == "350")
	}
	testing.expectf(t, slice.equal(sheet.changes, []int{1, 3, 4, 5}), "changes %v", sheet.changes)
	testing.expect(t, sheet.added_rows == 1 && sheet.removed_rows == 1 && sheet.modified_rows == 2)
	testing.expect(t, sheet.columns == 2 && len(sheet.widths) == 2 && sheet.widths[0] == 6 && sheet.widths[1] == 4)

	// Unequal runs pair by their first cell: Bread changed, the rest removed.
	if !testing.expect(t, select_commit(&model, 0) == "") do return
	if !test_changed_file(t, &model, "Budget.xlsx") do return
	sheet = model.changes.file.grid.sheets[0]
	test_grid_row(t, sheet, 0, .DELETED, 0, 1, "Apple")
	test_grid_row(t, sheet, 1, .MODIFIED, 1, 2, "Bread")
	test_grid_row(t, sheet, 2, .DELETED, 0, 3, "Cheese")

	// The first version: everything added, the sheet is not flagged as new.
	if !testing.expect(t, select_commit(&model, 3) == "") do return
	if !test_changed_file(t, &model, "Budget.xlsx") do return
	sheet = model.changes.file.grid.sheets[0]
	testing.expect(t, !sheet.added && sheet.added_rows == 5 && len(sheet.changes) == 5)
}
