package git

import "core:c"

when ODIN_OS == .Windows {
	foreign import libgit2 "../../vendor/libgit2/build-ucrt64/libgit2.dll.a"
} else {
	foreign import libgit2 "system:git2"
}

// Bindings for git2/submodule.h (vendored 2.0.0-rc.1).
Submodule :: struct {}

// git_submodule_status_t. The first four say where the submodule is known
// (HEAD tree, index, .gitmodules/config, working directory); the rest
// describe how those places disagree.
SUBMODULE_STATUS_IN_HEAD           :: c.uint(1 << 0)
SUBMODULE_STATUS_IN_INDEX          :: c.uint(1 << 1)
SUBMODULE_STATUS_IN_CONFIG         :: c.uint(1 << 2)
SUBMODULE_STATUS_IN_WD             :: c.uint(1 << 3)
SUBMODULE_STATUS_INDEX_ADDED       :: c.uint(1 << 4)
SUBMODULE_STATUS_INDEX_DELETED     :: c.uint(1 << 5)
SUBMODULE_STATUS_INDEX_MODIFIED    :: c.uint(1 << 6)
SUBMODULE_STATUS_WD_UNINITIALIZED  :: c.uint(1 << 7)
SUBMODULE_STATUS_WD_ADDED          :: c.uint(1 << 8)
SUBMODULE_STATUS_WD_DELETED        :: c.uint(1 << 9)
SUBMODULE_STATUS_WD_MODIFIED       :: c.uint(1 << 10)
SUBMODULE_STATUS_WD_INDEX_MODIFIED :: c.uint(1 << 11)
SUBMODULE_STATUS_WD_WD_MODIFIED    :: c.uint(1 << 12)
SUBMODULE_STATUS_WD_UNTRACKED      :: c.uint(1 << 13)

// git_submodule_ignore_t: how deeply status looks inside the submodule.
SUBMODULE_IGNORE_UNSPECIFIED :: c.int(-1) // The submodule's own configuration.
SUBMODULE_IGNORE_NONE        :: c.int(1)  // Untracked files make it dirty too.
SUBMODULE_IGNORE_UNTRACKED   :: c.int(2)
SUBMODULE_IGNORE_DIRTY       :: c.int(3)
SUBMODULE_IGNORE_ALL         :: c.int(4)

SUBMODULE_UPDATE_OPTIONS_VERSION :: c.uint(1)

// Gitlink entries (a commit recorded in the parent's tree/index).
FILEMODE_COMMIT :: u16(0o160000)

Submodule_Callback :: proc "c" (submodule: ^Submodule, name: cstring, payload: rawptr) -> c.int

Submodule_Update_Options :: struct {
	version: c.uint,
	checkout_opts: Checkout_Options,
	fetch_opts: Fetch_Options,
	// Fetch from the submodule's remote when the recorded commit is missing.
	allow_fetch: c.int,
}

@(default_calling_convention = "c", link_prefix = "git_")
foreign libgit2 {
	// The submodule passed to the callback is borrowed; look it up again to keep it.
	submodule_foreach :: proc(repo: ^Repository, callback: Submodule_Callback, payload: rawptr) -> c.int ---
	submodule_lookup :: proc(out: ^^Submodule, repo: ^Repository, name: cstring) -> c.int ---
	submodule_free :: proc(submodule: ^Submodule) ---
	// Strings and IDs borrow the submodule; copy them before submodule_free.
	submodule_name :: proc(submodule: ^Submodule) -> cstring ---
	submodule_path :: proc(submodule: ^Submodule) -> cstring ---
	submodule_url :: proc(submodule: ^Submodule) -> cstring ---
	submodule_branch :: proc(submodule: ^Submodule) -> cstring ---
	// nil when the submodule is absent from that place.
	submodule_head_id :: proc(submodule: ^Submodule) -> ^Oid ---
	submodule_index_id :: proc(submodule: ^Submodule) -> ^Oid ---
	submodule_wd_id :: proc(submodule: ^Submodule) -> ^Oid ---
	submodule_status :: proc(status: ^c.uint, repo: ^Repository, name: cstring, ignore: c.int) -> c.int ---
	submodule_update_options_init :: proc(options: ^Submodule_Update_Options, version: c.uint) -> c.int ---
	// Like git submodule update [--init]: clones when needed, fetches a missing
	// commit, then checks out the commit recorded in the parent (detached HEAD).
	submodule_update :: proc(submodule: ^Submodule, init: c.int, options: ^Submodule_Update_Options) -> c.int ---
	submodule_init :: proc(submodule: ^Submodule, overwrite: c.int) -> c.int ---
	// Like git submodule sync: copies the .gitmodules URL into the configs.
	submodule_sync :: proc(submodule: ^Submodule) -> c.int ---
	submodule_open :: proc(repo: ^^Repository, submodule: ^Submodule) -> c.int ---
	submodule_reload :: proc(submodule: ^Submodule, force: c.int) -> c.int ---
}
