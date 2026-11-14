package workspace

import "core:c"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import git "../git"
import xlsx "../xlsx"

Change_Kind :: enum { CONTEXT, ADDITION, DELETION, HUNK, NOTE }

Change_Line :: struct {
	kind: Change_Kind,
	text: string,
	old_line, new_line: int,
	// Changed cells of a workbook row: File_Changes.spans[span_start:][:span_count].
	span_start, span_count: int,
}

// A range of display columns in Change_Line.text (after tab expansion).
Cell_Span :: struct {
	start, end: int,
}

Changed_File :: struct {
	path, old_path: string,
	status: c.int,
	old_mode, new_mode: u16,
	// Working changes only: whether the index differs from HEAD (staged) and
	// whether the working file differs from the index (unstaged). Both can be set.
	staged, unstaged: bool,
	// Working changes only: checked in the file list for Stage/Unstage.
	selected: bool,
}

File_Changes :: struct {
	index: int,
	lines: [dynamic]Change_Line,
	binary: bool,
	// Spreadsheets are compared as text with one line per row; line numbers
	// are spreadsheet rows (0 on sheet headers).
	workbook: bool,
	// Why a workbook could not be compared (shown instead of the diff).
	note: string,
	spans: [dynamic]Cell_Span,
	additions, deletions, max_columns: int,
}

Commit_Changes :: struct {
	// The viewed commit, or HEAD's hash for working changes (empty when unborn).
	// Use changes_open to tell whether history or details are shown.
	hash: string,
	commit_index: int, // -1 for working changes.
	// Working changes compare HEAD with the index and working files.
	working: bool,
	diff: ^git.Diff,
	files: [dynamic]Changed_File,
	file: File_Changes,
}

changes_open :: proc(changes: Commit_Changes) -> bool {
	return changes.hash != "" || changes.working
}

clear_file_changes :: proc(file: ^File_Changes) {
	for line in file.lines do delete(line.text)
	delete(file.lines)
	delete(file.note)
	delete(file.spans)
	file^ = {}
}

clear_changes :: proc(changes: ^Commit_Changes) {
	clear_file_changes(&changes.file)
	for file in changes.files {
		delete(file.path)
		delete(file.old_path)
	}
	delete(changes.files)
	delete(changes.hash)
	git.diff_free(changes.diff)
	changes^ = {}
}

// Keep indentation readable in the monospace viewer, without stripping spaces
// that are part of a change. Only the line ending is removed.
change_text :: proc(raw: string) -> (string, int) {
	text := strings.trim_suffix(strings.trim_suffix(raw, "\n"), "\r")
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	columns := 0
	for ch in text {
		if ch == '\t' {
			n := 4 - columns % 4
			for _ in 0..<n do strings.write_byte(&b, ' ')
			columns += n
		} else {
			strings.write_rune(&b, ch)
			columns += 1
		}
	}
	return strings.clone(strings.to_string(b)), columns
}

load_file_changes :: proc(out: ^File_Changes, diff: ^git.Diff, index: int, repo: ^git.Repository = nil, working := false) -> string {
	next := File_Changes{index = index}
	succeeded := false
	defer if !succeeded do clear_file_changes(&next)
	delta := git.diff_get_delta(diff, c.size_t(index))
	if delta == nil do return "This file is no longer available. Select a commit again."
	path := string(delta.status == git.DELTA_DELETED ? delta.old_file.path : delta.new_file.path)
	if repo != nil && xlsx.is_workbook_path(path) {
		next.workbook = true
		if err := load_workbook_changes(&next, repo, delta, working); err != "" {
			// Show why the spreadsheet could not be compared instead of failing the selection.
			clear_file_changes(&next)
			next = File_Changes{index = index, workbook = true, binary = true, note = strings.clone(err)}
		}
	} else {
		patch: ^git.Patch
		if git.patch_from_diff(&patch, diff, c.size_t(index)) != git.OK do return git_error("Could not read this file's changes")
		defer git.patch_free(patch)
		next.binary = delta.flags & git.DIFF_FLAG_BINARY != 0
		if patch != nil {
			if err := read_patch(&next, patch); err != "" do return err
		}
	}
	clear_file_changes(out)
	out^ = next
	succeeded = true
	return ""
}

// Appends the patch's hunks and lines. With workbook line maps, line numbers
// become spreadsheet rows (0 for sheet headers) and hunk headers name the
// sheets they touch instead of text line ranges.
@(private)
read_patch :: proc(next: ^File_Changes, patch: ^git.Patch, old_book: ^xlsx.Workbook_Text = nil, new_book: ^xlsx.Workbook_Text = nil) -> string {
	additions, deletions: c.size_t
	if git.patch_line_stats(nil, &additions, &deletions, patch) != git.OK do return git_error("Could not count changed lines")
	next.additions, next.deletions = int(additions), int(deletions)
	workbook := old_book != nil && new_book != nil
	for h in 0..<git.patch_num_hunks(patch) {
		hunk: ^git.Diff_Hunk
		count: c.size_t
		if git.patch_get_hunk(&hunk, &count, patch, h) != git.OK do return git_error("Could not read a diff hunk")
		header_index := len(next.lines)
		header, columns := change_text(string(hunk.header[:int(hunk.header_len)]))
		append(&next.lines, Change_Line{kind = .HUNK, text = header})
		next.max_columns = max(next.max_columns, columns)
		touched: [dynamic]string // Sheet names borrow the workbooks.
		defer delete(touched)
		// Workbooks: the compared (R1C1) text of each hunk line; it borrows the patch.
		compared := make([dynamic]string, context.temp_allocator)
		for i in 0..<count {
			line: ^git.Diff_Line
			if git.patch_get_line_in_hunk(&line, patch, h, i) != git.OK do return git_error("Could not read a changed line")
			kind: Change_Kind
			switch u8(line.origin) {
			case '+': kind = .ADDITION
			case '-': kind = .DELETION
			case ' ': kind = .CONTEXT
			case: kind = .NOTE
			}
			text := kind == .NOTE ? "\\ No newline at end of file" : string(line.content[:int(line.content_len)])
			old_line, new_line := max(0, int(line.old_lineno)), max(0, int(line.new_lineno))
			if workbook && kind != .NOTE {
				// Show the A1 form of the row that was compared in R1C1 form.
				append(&compared, strings.trim_suffix(text, "\n"))
				if kind == .DELETION && old_line > 0 && old_line <= len(old_book.display) {
					text = old_book.display[old_line - 1]
				} else if kind != .DELETION && new_line > 0 && new_line <= len(new_book.display) {
					text = new_book.display[new_line - 1]
				}
			}
			owned, width := change_text(text)
			if workbook && kind != .NOTE {
				sheet := ""
				if old_line > 0 && old_line <= len(old_book.lines) {
					ref := old_book.lines[old_line - 1]
					old_line, sheet = ref.row, old_book.sheets[ref.sheet]
				}
				if new_line > 0 && new_line <= len(new_book.lines) {
					ref := new_book.lines[new_line - 1]
					new_line, sheet = ref.row, new_book.sheets[ref.sheet]
				}
				if sheet != "" && !slice.contains(touched[:], sheet) do append(&touched, sheet)
			}
			append(&next.lines, Change_Line{kind = kind, text = owned, old_line = old_line, new_line = new_line})
			next.max_columns = max(next.max_columns, width)
		}
		if workbook && len(compared) == len(next.lines) - header_index - 1 do mark_changed_cells(next, header_index + 1, compared[:])
		if workbook && len(touched) > 0 {
			label := strings.join(touched[:], ", ")
			defer delete(label)
			delete(next.lines[header_index].text)
			next.lines[header_index].text = fmt.aprintf("%s %s", len(touched) == 1 ? "Sheet:" : "Sheets:", label)
		}
	}
	return ""
}

// Pairs each run of deleted rows with the added rows that follow it and records
// which cells differ, so the view can highlight them within the row. Equal-sized
// runs pair in order; otherwise a deleted row pairs with the first unused added
// row that has the same first cell (its key, usually), and the rest stay unpaired.
// `compared[i]` is the compared text of file.lines[first + i]; cells are judged on
// it, so a formula that only moved along with its row is not highlighted.
@(private)
mark_changed_cells :: proc(file: ^File_Changes, first: int, compared: []string) {
	lines := file.lines[first:]
	i := 0
	for i < len(lines) {
		if lines[i].kind != .DELETION {
			i += 1
			continue
		}
		d_start := i
		for i < len(lines) && lines[i].kind == .DELETION do i += 1
		a_start := i
		for i < len(lines) && lines[i].kind == .ADDITION do i += 1
		deleted, added := lines[d_start:a_start], lines[a_start:i]
		if len(added) == 0 do continue
		if len(deleted) == len(added) {
			for k in 0..<len(deleted) do mark_pair(file, &deleted[k], &added[k], compared[d_start + k], compared[a_start + k])
			continue
		}
		used := make([]bool, len(added), context.temp_allocator)
		for &d, dk in deleted {
			key := first_cell(compared[d_start + dk])
			for &a, k in added {
				if used[k] || first_cell(compared[a_start + k]) != key do continue
				used[k] = true
				mark_pair(file, &d, &a, compared[d_start + dk], compared[a_start + k])
				break
			}
		}
	}
}

@(private)
first_cell :: proc(text: string) -> string {
	if i := strings.index(text, xlsx.CELL_SEPARATOR); i >= 0 do return text[:i]
	return text
}

// Byte ranges of the cells in a row line.
@(private)
split_cells :: proc(text: string) -> [dynamic][2]int {
	out := make([dynamic][2]int, context.temp_allocator)
	start := 0
	for {
		i := strings.index(text[start:], xlsx.CELL_SEPARATOR)
		if i < 0 {
			append(&out, [2]int{start, len(text)})
			return out
		}
		append(&out, [2]int{start, start + i})
		start += i + len(xlsx.CELL_SEPARATOR)
	}
}

@(private)
mark_pair :: proc(file: ^File_Changes, old, new: ^Change_Line, old_compared, new_compared: string) {
	a, b := split_cells(old.text), split_cells(new.text)
	// Judge cells on the compared text when it splits into the same cells
	// (a " | " inside a formula string could make them differ).
	old_key, new_key := old_compared, new_compared
	ca, cb := split_cells(old_key), split_cells(new_key)
	if len(ca) != len(a) || len(cb) != len(b) {
		old_key, new_key, ca, cb = old.text, new.text, a, b
	}
	cell :: proc(text: string, cells: [dynamic][2]int, k: int) -> string {
		return k < len(cells) ? text[cells[k][0]:cells[k][1]] : ""
	}
	add :: proc(file: ^File_Changes, line: ^Change_Line, cells: [dynamic][2]int, k: int) {
		if k >= len(cells) || cells[k][0] == cells[k][1] do return
		if line.span_count == 0 do line.span_start = len(file.spans)
		// Columns are runes: the diff view uses a monospace cell per character.
		start := utf8.rune_count(line.text[:cells[k][0]])
		append(&file.spans, Cell_Span{start, start + utf8.rune_count(line.text[cells[k][0]:cells[k][1]])})
		line.span_count += 1
	}
	for k in 0..<max(len(a), len(b)) do if cell(old_key, ca, k) != cell(new_key, cb, k) do add(file, old, a, k)
	for k in 0..<max(len(a), len(b)) do if cell(old_key, ca, k) != cell(new_key, cb, k) do add(file, new, b, k)
}

// Compares the two versions of a workbook as text, one line per row, with
// formulas compared in R1C1 form (see xlsx.Workbook_Text). Errors
// are temp-allocated, like git_error.
@(private)
load_workbook_changes :: proc(next: ^File_Changes, repo: ^git.Repository, delta: ^git.Diff_Delta, working: bool) -> string {
	old_blob, new_blob: ^git.Blob
	defer if old_blob != nil do git.blob_free(old_blob)
	defer if new_blob != nil do git.blob_free(new_blob)
	old_data, new_data, disk_data: []u8
	defer delete(disk_data)
	if delta.status != git.DELTA_ADDED && delta.status != git.DELTA_UNTRACKED {
		if git.blob_lookup(&old_blob, repo, &delta.old_file.id) != git.OK do return git_error("Could not read the previous version of this workbook")
		old_data = ([^]u8)(git.blob_rawcontent(old_blob))[:int(git.blob_rawsize(old_blob))]
	}
	if delta.status != git.DELTA_DELETED {
		if working {
			// The new side of `git diff HEAD` is the file in the working tree.
			full := strings.concatenate({string(git.repository_workdir(repo)), string(delta.new_file.path)}, context.temp_allocator)
			data, err := os.read_entire_file(full, context.allocator)
			if err != nil do return "Could not read this workbook from the working tree."
			disk_data, new_data = data, data
		} else {
			if git.blob_lookup(&new_blob, repo, &delta.new_file.id) != git.OK do return git_error("Could not read this version of the workbook")
			new_data = ([^]u8)(git.blob_rawcontent(new_blob))[:int(git.blob_rawsize(new_blob))]
		}
	}
	old_lfs, old_err := lfs_resolve(repo, old_data, "The previous version")
	defer delete(old_lfs)
	if old_err != "" do return old_err
	if old_lfs != nil do old_data = old_lfs
	new_lfs, new_err := lfs_resolve(repo, new_data, "This version")
	defer delete(new_lfs)
	if new_err != "" do return new_err
	if new_lfs != nil do new_data = new_lfs
	old_book, new_book: xlsx.Workbook_Text
	defer xlsx.workbook_text_destroy(&old_book)
	defer xlsx.workbook_text_destroy(&new_book)
	if len(old_data) > 0 {
		err: string
		if old_book, err = xlsx.workbook_to_text(old_data); err != "" do return fmt.tprintf("Could not read the previous version as a spreadsheet: %s.", err)
	}
	if len(new_data) > 0 {
		err: string
		if new_book, err = xlsx.workbook_to_text(new_data); err != "" do return fmt.tprintf("Could not read this version as a spreadsheet: %s.", err)
	}
	options: git.Diff_Options
	if git.diff_options_init(&options, git.DIFF_OPTIONS_VERSION) != git.OK do return git_error("Could not initialize the comparison")
	options.flags = git.DIFF_FORCE_TEXT
	path := cstring_temp(string(delta.status == git.DELTA_DELETED ? delta.old_file.path : delta.new_file.path))
	patch: ^git.Patch
	if git.patch_from_buffers(&patch, raw_data(old_book.compare), c.size_t(len(old_book.compare)), path,
		raw_data(new_book.compare), c.size_t(len(new_book.compare)), path, &options) != git.OK {
		return git_error("Could not compare the workbook versions")
	}
	defer git.patch_free(patch)
	if patch == nil do return ""
	return read_patch(next, patch, &old_book, &new_book)
}

select_file :: proc(model: ^Model, index: int) -> string {
	if model.changes.diff == nil || index < 0 || index >= len(model.changes.files) do return "This file is no longer available. Select a commit again."
	if model.changes.file.index == index do return ""
	return load_file_changes(&model.changes.file, model.changes.diff, index, model.repo, model.changes.working)
}

// Read committed trees only: browsing never touches the index or working files.
// Merge commits are compared with their first parent, roots with an empty tree.
select_commit :: proc(model: ^Model, index: int) -> string {
	if model.repo == nil || index < 0 || index >= len(model.commits) do return "This commit is no longer available. Refresh the project."
	commit := model.commits[index]
	next := Commit_Changes{hash = strings.clone(commit.hash), commit_index = index}
	succeeded := false
	defer if !succeeded do clear_changes(&next)
	id: git.Oid
	kind := len(commit.hash) == 64 ? git.OID_SHA256 : git.OID_SHA1
	if git.oid_from_string(&id, cstring_temp(commit.hash), kind) != git.OK do return git_error("Could not read this revision")
	node: ^git.Commit
	if git.commit_lookup(&node, model.repo, &id) != git.OK do return git_error("Could not read this commit")
	defer git.commit_free(node)
	new_tree, old_tree: ^git.Tree
	if git.tree_lookup(&new_tree, model.repo, git.commit_tree_id(node)) != git.OK do return git_error("Could not read the commit's files")
	defer git.tree_free(new_tree)
	if git.commit_parentcount(node) > 0 {
		parent: ^git.Commit
		if git.commit_parent(&parent, node, 0) != git.OK do return git_error("Could not read the commit's parent")
		defer git.commit_free(parent)
		if git.tree_lookup(&old_tree, model.repo, git.commit_tree_id(parent)) != git.OK do return git_error("Could not read the parent's files")
	}
	defer git.tree_free(old_tree)
	if git.diff_tree_to_tree(&next.diff, model.repo, old_tree, new_tree, nil) != git.OK do return git_error("Could not compare this commit")
	if err := collect_changed_files(&next, git.DIFF_FIND_RENAMES); err != "" do return err
	if len(next.files) > 0 {
		if err := load_file_changes(&next.file, next.diff, 0, model.repo); err != "" do return err
	}
	clear_changes(&model.changes)
	model.changes = next
	succeeded = true
	return ""
}

@(private)
collect_changed_files :: proc(changes: ^Commit_Changes, find_flags: u32) -> string {
	options: git.Diff_Find_Options
	if git.diff_find_options_init(&options, git.DIFF_FIND_OPTIONS_VERSION) != git.OK do return git_error("Could not initialize rename detection")
	options.flags = find_flags
	if git.diff_find_similar(changes.diff, &options) != git.OK do return git_error("Could not detect renamed files")
	for i in 0..<git.diff_num_deltas(changes.diff) {
		delta := git.diff_get_delta(changes.diff, i)
		path := delta.status == git.DELTA_DELETED ? delta.old_file.path : delta.new_file.path
		append(&changes.files, Changed_File{
			path = strings.clone(string(path)), old_path = strings.clone(string(delta.old_file.path)),
			status = delta.status, old_mode = delta.old_file.mode, new_mode = delta.new_file.mode,
		})
	}
	return ""
}

// Everything the next commit would contain if all changes were staged: HEAD
// compared with the index and working files (like `git diff HEAD`), including
// untracked files. Read-only: nothing is staged, written or checked out.
// Reloading keeps the selected file when it is still changed.
select_working_changes :: proc(model: ^Model) -> string {
	if model.repo == nil do return "Open a project first."
	if git.repository_is_bare(model.repo) != 0 do return "This repository has no working tree to compare."
	next := Commit_Changes{working = true, commit_index = -1}
	succeeded := false
	defer if !succeeded do clear_changes(&next)
	old_tree: ^git.Tree
	head_id: git.Oid
	result := git.reference_name_to_id(&head_id, model.repo, "HEAD")
	if result == git.OK {
		node: ^git.Commit
		if git.commit_lookup(&node, model.repo, &head_id) != git.OK do return git_error("Could not read the last commit")
		defer git.commit_free(node)
		if git.tree_lookup(&old_tree, model.repo, git.commit_tree_id(node)) != git.OK do return git_error("Could not read the last commit's files")
		hash: [65]u8
		_ = git.oid_tostr(raw_data(hash[:]), c.size_t(len(hash)), &head_id)
		next.hash = strings.clone(string(cstring(raw_data(hash[:]))))
	} else if result != git.ENOTFOUND && result != git.EUNBORNBRANCH {
		return git_error("Could not read HEAD")
	}
	defer git.tree_free(old_tree)
	options: git.Diff_Options
	if git.diff_options_init(&options, git.DIFF_OPTIONS_VERSION) != git.OK do return git_error("Could not initialize the comparison")
	options.flags = git.DIFF_INCLUDE_UNTRACKED | git.DIFF_RECURSE_UNTRACKED_DIRS |
		git.DIFF_SHOW_UNTRACKED_CONTENT | git.DIFF_INCLUDE_TYPECHANGE
	if git.diff_tree_to_workdir_with_index(&next.diff, model.repo, old_tree, &options) != git.OK {
		return git_error("Could not compare the working tree")
	}
	if err := collect_changed_files(&next, git.DIFF_FIND_RENAMES | git.DIFF_FIND_FOR_UNTRACKED); err != "" do return err
	if err := load_stage_state(model.repo, old_tree, &next); err != "" do return err
	// Keep checked files checked across reloads, including after staging them.
	if model.changes.working {
		for &file in next.files {
			for previous in model.changes.files do if previous.selected && previous.path == file.path do file.selected = true
		}
	}
	if len(next.files) > 0 {
		// Keep the previously viewed file selected across reloads.
		first := 0
		if model.changes.working && model.changes.file.index < len(model.changes.files) {
			previous := model.changes.files[model.changes.file.index].path
			for file, i in next.files do if file.path == previous do first = i
		}
		if err := load_file_changes(&next.file, next.diff, first, model.repo, true); err != "" do return err
	}
	clear_changes(&model.changes)
	model.changes = next
	succeeded = true
	return ""
}
