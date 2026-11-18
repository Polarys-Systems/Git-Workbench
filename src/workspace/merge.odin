package workspace

// Merge conflict resolution: conflicted files, their hunks, and saving a choice.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"

import git "../git"

Merge_Editor :: struct {
	files: [dynamic]Merge_File,
	selected: int,
	loaded: bool,
}

Merge_File :: struct {
	path, original, issue: string,
	result: strings.Builder,
	ids: [3]git.Oid,
	modes: [3]u32,
	loaded, staged: bool,
}

// BOTH keeps current before incoming; BOTH_INCOMING_FIRST reverses the order.
Merge_Choice :: enum { CURRENT, INCOMING, BOTH, BOTH_INCOMING_FIRST }
Merge_Hunk :: struct {
	start, end: int,
	current_start, current_end, incoming_start, incoming_end: int,
}

clear_merge :: proc(editor: ^Merge_Editor) {
	for &file in editor.files {
		delete(file.path)
		delete(file.original)
		strings.builder_destroy(&file.result)
	}
	delete(editor.files)
	editor^ = {}
}

merge_marker :: proc(raw_line: string) -> (u8, int) {
	line := strings.trim_suffix(raw_line, "\r")
	if len(line) < 7 || !strings.contains("<|=>", line[:1]) do return 0, 0
	n := 1
	for n < len(line) && line[n] == line[0] do n += 1
	if n < 7 || (n < len(line) && (line[0] == '=' || line[n] != ' ')) do return 0, 0
	return line[0], n
}

// Work on byte ranges so accepting a side preserves surrounding edits, CRLF,
// whitespace and a missing final newline. diff3's base is deliberately skipped.
next_merge_hunk :: proc(text: string) -> (hunk: Merge_Hunk, found: bool, err: string) {
	phase, width := 0, 0
	for start := 0; start < len(text); {
		end := start
		for end < len(text) && text[end] != '\n' do end += 1
		after := min(len(text), end + 1)
		marker, size := merge_marker(text[start:end])
		if marker != 0 {
			valid := false
			switch marker {
			case '<':
				if phase == 0 {
					hunk.start, hunk.current_start = start, after
					phase, width, valid = 1, size, true
				}
			case '|':
				if phase == 1 && size == width {
					hunk.current_end = start
					phase, valid = 2, true
				}
			case '=':
				if (phase == 1 || phase == 2) && size == width {
					if phase == 1 do hunk.current_end = start
					hunk.incoming_start = after
					phase, valid = 3, true
				}
			case '>':
				if phase == 3 && size == width {
					hunk.incoming_end, hunk.end = start, after
					return hunk, true, ""
				}
			}
			if !valid do return {}, false, "Incomplete or unexpected conflict markers. Edit the result or reload the conflicts."
		}
		start = after
	}
	if phase != 0 do return {}, false, "Incomplete conflict markers. Finish editing the result before saving."
	return {}, false, ""
}

choose_merge_hunk :: proc(file: ^Merge_File, choice: Merge_Choice) -> string {
	text := strings.to_string(file.result)
	hunk, found, err := next_merge_hunk(text)
	if err != "" do return err
	if !found do return "There are no conflict blocks left. Review the result, then save and stage."
	// A separate builder avoids invalidating the source slices while replacing.
	next := strings.builder_make()
	strings.write_string(&next, text[:hunk.start])
	current := text[hunk.current_start:hunk.current_end]
	incoming := text[hunk.incoming_start:hunk.incoming_end]
	// Each side ends at a marker line, so it is empty or ends with a newline
	// and the two sides can be joined in either order.
	switch choice {
	case .CURRENT:  strings.write_string(&next, current)
	case .INCOMING: strings.write_string(&next, incoming)
	case .BOTH:
		strings.write_string(&next, current)
		strings.write_string(&next, incoming)
	case .BOTH_INCOMING_FIRST:
		strings.write_string(&next, incoming)
		strings.write_string(&next, current)
	}
	strings.write_string(&next, text[hunk.end:])
	strings.builder_destroy(&file.result)
	file.result = next
	return ""
}

// The index is authoritative: marker-like text in an ordinary file must not
// appear as a conflict, and an already edited conflict still needs staging.
load_merge :: proc(model: ^Model) -> string {
	index: ^git.Index
	if git.repository_index(&index, model.repo) != git.OK do return git_error("Could not open conflicts")
	defer git.index_free(index)
	if git.index_read(index, 1) != git.OK do return git_error("Could not refresh conflicts")
	iter: ^git.Index_Conflict_Iterator
	if git.index_conflict_iterator_new(&iter, index) != git.OK do return git_error("Could not list conflicts")
	defer git.index_conflict_iterator_free(iter)
	next: Merge_Editor
	succeeded := false
	defer if !succeeded do clear_merge(&next)
	for {
		entries: [3]^git.Index_Entry
		code := git.index_conflict_next(&entries[0], &entries[1], &entries[2], iter)
		if code == git.ITEROVER do break
		if code != git.OK do return git_error("Could not read a conflict")
		file: Merge_File
		for entry, i in entries {
			if entry == nil do continue
			if file.path == "" do file.path = strings.clone(string(entry.path))
			file.ids[i], file.modes[i] = entry.id, entry.mode
			if string(entry.path) != file.path || (entry.mode != 0o100644 && entry.mode != 0o100755) {
				file.issue = "Resolve renamed paths, symlinks and submodules outside this text editor, then reload."
			}
		}
		append(&next.files, file)
	}
	clear_merge(&model.merge)
	next.loaded = true
	model.merge = next
	succeeded = true
	if len(next.files) > 0 do return select_merge_file(model, 0)
	return ""
}

// Load on first selection and keep each draft, so switching files is cheap and
// cannot discard edits. Only an explicit reload replaces these snapshots.
select_merge_file :: proc(model: ^Model, selected: int) -> string {
	if selected < 0 || selected >= len(model.merge.files) do return "This conflict is no longer available. Reload the conflicts."
	model.merge.selected = selected
	file := &model.merge.files[selected]
	if file.loaded || file.issue != "" do return ""
	path := fmt.tprintf("%s%s", string(git.repository_workdir(model.repo)), file.path)
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil || info.type != .Regular {
		file.issue = "This file is missing or is not a regular file. Resolve it outside this text editor, then reload."
		return ""
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return fmt.tprintf("Could not read %s: %v", file.path, err)
	if strings.contains(string(data), "\x00") || !utf8.valid_string(string(data)) {
		file.issue = "Binary or non-UTF-8 file. Resolve it outside this text editor, then reload."
		return ""
	}
	file.original = strings.clone(string(data))
	file.result = strings.builder_make()
	strings.write_string(&file.result, file.original)
	file.loaded = true
	return ""
}

save_merge_file :: proc(model: ^Model) -> string {
	editor := &model.merge
	if editor.selected < 0 || editor.selected >= len(editor.files) do return "Select a conflict first."
	file := &editor.files[editor.selected]
	if !file.loaded || file.issue != "" || file.staged do return "This file is not editable."
	text := strings.to_string(file.result)
	_, found, marker_error := next_merge_hunk(text)
	if marker_error != "" do return marker_error
	if found do return "Resolve every conflict block before saving and staging."
	if strings.contains(text, "\x00") || !utf8.valid_string(text) do return "The result must be UTF-8 text."

	index: ^git.Index
	if git.repository_index(&index, model.repo) != git.OK do return git_error("Could not open the index")
	defer git.index_free(index)
	// Git or another editor may have changed this file since it was opened.
	// Check both snapshots before writing, rather than silently replacing new work.
	if git.index_read(index, 1) != git.OK do return git_error("Could not refresh the index")
	entries: [3]^git.Index_Entry
	if git.index_conflict_get(&entries[0], &entries[1], &entries[2], index, cstring_temp(file.path)) != git.OK {
		return "The index conflict changed. Reload the conflicts before saving."
	}
	for entry, i in entries {
		mode := entry != nil ? entry.mode : 0
		if mode != file.modes[i] || (entry != nil && (git.oid_equal(&entry.id, &file.ids[i]) == 0 || string(entry.path) != file.path)) {
			return "The index conflict changed. Reload the conflicts before saving."
		}
	}
	path := fmt.tprintf("%s%s", string(git.repository_workdir(model.repo)), file.path)
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil || info.type != .Regular do return "The working file changed. Reload the conflicts before saving."
	disk, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil || string(disk) != file.original do return "The working file changed. Reload the conflicts before saving."

	// Replace only after a complete write so an I/O failure cannot truncate the
	// conflicted file. Keep its permissions, including executable bits on Unix.
	temporary, create_err := os.create_temp_file(filepath.dir(path), ".workbench-merge-*.tmp")
	if create_err != nil do return fmt.tprintf("Could not create the merge result: %v", create_err)
	temp_path := strings.clone(os.name(temporary), context.temp_allocator)
	defer _ = os.remove(temp_path)
	written, write_err := os.write(temporary, transmute([]u8)text)
	flush_err := os.flush(temporary)
	close_err := os.close(temporary)
	if write_err != nil || written != len(text) || flush_err != nil || close_err != nil do return "Could not finish writing the merge result."
	if os.chmod(temp_path, info.mode) != nil do return "Could not preserve the file permissions."
	if os.rename(temp_path, path) != nil do return "Could not replace the working file with the merge result."
	delete(file.original)
	file.original = strings.clone(text)
	// add_bypath resolves this path's index stages and applies Git's clean filters.
	// Never stage_all here: other files may contain unrelated or unresolved work.
	if git.index_add_bypath(index, cstring_temp(file.path)) != git.OK || git.index_write(index) != git.OK {
		return git_error("Result saved, but staging failed; retry Save and stage")
	}
	file.staged = true
	return ""
}
