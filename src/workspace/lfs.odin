package workspace

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import git "../git"

// Git LFS commits a small text pointer in place of the file and keeps the
// content in .git/lfs/objects/<o[0:2]>/<o[2:4]>/<oid> once downloaded.
LFS_POINTER_PREFIX :: "version https://git-lfs.github.com/spec/"
LFS_POINTER_MAX_SIZE :: 1024

// Parses an LFS pointer file; the oid borrows `data`.
lfs_pointer :: proc(data: []u8) -> (oid: string, size: i64, ok: bool) {
	if len(data) > LFS_POINTER_MAX_SIZE || !strings.has_prefix(string(data), LFS_POINTER_PREFIX) do return
	text := string(data)
	found_size := false
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_right(raw, "\r")
		if strings.has_prefix(line, "oid sha256:") {
			oid = line[len("oid sha256:"):]
		} else if strings.has_prefix(line, "size ") {
			size, found_size = strconv.parse_i64(line[len("size "):], 10)
		}
	}
	if len(oid) != 64 || !found_size do return "", 0, false
	for ch in transmute([]u8)oid do if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')) do return "", 0, false
	return oid, size, true
}

// When `data` is an LFS pointer, returns the downloaded object (owned by the
// caller). Not a pointer: nil and "". Pointer without a local object: an
// explanation (temp-allocated).
lfs_resolve :: proc(repo: ^git.Repository, data: []u8, side: string) -> ([]u8, string) {
	oid, size, is_pointer := lfs_pointer(data)
	if !is_pointer do return nil, ""
	path := fmt.tprintf("%slfs/objects/%s/%s/%s", string(git.repository_commondir(repo)), oid[:2], oid[2:4], oid)
	object, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return nil, fmt.tprintf("%s is stored in Git LFS and has not been downloaded. Run `git lfs fetch` (or `git lfs pull`) to compare it.", side)
	}
	if i64(len(object)) != size {
		delete(object)
		return nil, fmt.tprintf("%s is stored in Git LFS, but the downloaded copy is incomplete. Run `git lfs fetch` again.", side)
	}
	return object, ""
}
