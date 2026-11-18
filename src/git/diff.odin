package git

// libgit2 diff and patch types.

import "core:c"

Diff :: struct {}
Patch :: struct {}

DELTA_ADDED      :: c.int(1)
DELTA_DELETED    :: c.int(2)
DELTA_MODIFIED   :: c.int(3)
DELTA_RENAMED    :: c.int(4)
DELTA_COPIED     :: c.int(5)
DELTA_IGNORED    :: c.int(6)
DELTA_UNTRACKED  :: c.int(7)
DELTA_TYPECHANGE :: c.int(8)
DELTA_UNREADABLE :: c.int(9)
DELTA_CONFLICTED :: c.int(10)
DIFF_FLAG_BINARY :: u32(1 << 0)
DIFF_INCLUDE_UNTRACKED :: u32(1 << 3)
DIFF_RECURSE_UNTRACKED_DIRS :: u32(1 << 4)
DIFF_INCLUDE_TYPECHANGE :: u32(1 << 6)
DIFF_FORCE_TEXT :: u32(1 << 20)
DIFF_SHOW_UNTRACKED_CONTENT :: u32(1 << 25)
DIFF_FIND_RENAMES :: u32(1 << 0)
DIFF_FIND_FOR_UNTRACKED :: u32(1 << 6)
DIFF_OPTIONS_VERSION :: c.uint(1)
DIFF_FIND_OPTIONS_VERSION :: c.uint(1)

// Layouts follow the vendored 2.0 headers, including tagged OIDs.
Diff_File :: struct {
	id: Oid,
	path: cstring,
	size: u64,
	flags: u32,
	mode, id_abbrev: u16,
}

Diff_Delta :: struct {
	status: c.int,
	flags: u32,
	similarity, nfiles: u16,
	old_file, new_file: Diff_File,
}

Diff_Options :: struct {
	version: c.uint,
	flags: u32,
	ignore_submodules: c.int,
	pathspec: Strarray,
	notify_cb: proc "c" (diff: ^Diff, delta: ^Diff_Delta, matched: cstring, payload: rawptr) -> c.int,
	progress_cb: proc "c" (diff: ^Diff, old_path, new_path: cstring, payload: rawptr) -> c.int,
	payload: rawptr,
	context_lines, interhunk_lines: u32,
	oid_type: c.int,
	id_abbrev: u16,
	max_size: i64,
	old_prefix, new_prefix: cstring,
}

Diff_Find_Options :: struct {
	version: c.uint,
	flags: u32,
	rename_threshold, rename_from_rewrite_threshold, copy_threshold, break_rewrite_threshold: u16,
	rename_limit: c.size_t,
	metric: ^Diff_Similarity_Metric,
}

Diff_Hunk :: struct {
	old_start, old_lines, new_start, new_lines: c.int,
	header_len: c.size_t,
	header: [128]u8,
}

Diff_Line :: struct {
	origin: c.char,
	old_lineno, new_lineno, num_lines: c.int,
	content_len: c.size_t,
	content_offset: i64,
	content: [^]u8,
}
