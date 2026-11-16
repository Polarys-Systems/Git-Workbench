package git

import "core:c"

// These bindings match the vendored libgit2 2.0.0-rc.1 headers, not libgit2 1.x.
Repository       :: struct {}
Remote           :: struct {}
Index            :: struct {}
Index_Conflict_Iterator :: struct {}
Tree             :: struct {}
Tree_Entry       :: struct {}
Commit           :: struct {}
Revwalk          :: struct {}
Object           :: struct {}
Reference        :: struct {}
Reference_Iterator :: struct {}
Branch_Iterator  :: struct {}
Annotated_Commit :: struct {}
Credential       :: struct {}
Transport        :: struct {}
Refspec          :: struct {}
Transaction      :: struct {}
Config           :: struct {}
Diff_Similarity_Metric :: struct {}
Commit_Builder   :: struct {}
Rebase           :: struct {}
Blob             :: struct {}
Tag              :: struct {}

// git_object_t values.
OBJECT_ANY    :: c.int(-2)
OBJECT_COMMIT :: c.int(1)
OBJECT_TAG    :: c.int(4)

// repository_state results (git_repository_state_t). Later values are sequences,
// bisect, rebases and mailbox application.
REPOSITORY_STATE_NONE       :: c.int(0)
REPOSITORY_STATE_MERGE      :: c.int(1)
REPOSITORY_STATE_REVERT     :: c.int(2)
REPOSITORY_STATE_CHERRYPICK :: c.int(4)

FILEMODE_TREE :: c.int(0o040000)

OK              :: c.int(0)
ERROR           :: c.int(-1)
ENOTFOUND       :: c.int(-3)
EEXISTS         :: c.int(-4)
EUSER           :: c.int(-7)
EBAREREPO       :: c.int(-8)
EUNBORNBRANCH   :: c.int(-9)
EUNMERGED       :: c.int(-10)
ENONFASTFORWARD :: c.int(-11)
EINVALIDSPEC    :: c.int(-12)
ECONFLICT       :: c.int(-13)
ELOCKED         :: c.int(-14)
EMODIFIED       :: c.int(-15)
EAUTH           :: c.int(-16)
EAPPLIED        :: c.int(-18)
EINVALID        :: c.int(-21)
EUNCOMMITTED    :: c.int(-22)
EMERGECONFLICT  :: c.int(-24)
PASSTHROUGH     :: c.int(-30)
ITEROVER        :: c.int(-31)
EUNCHANGED      :: c.int(-38)
EOWNER          :: c.int(-36) // The repository is not owned by the current user.
ENOTSUPPORTED   :: c.int(-39)

// git_libgit2_opt_t values for libgit2_opts (positions in the vendored enum).
OPT_GET_OWNER_VALIDATION :: c.int(35) // (^c.int)
OPT_SET_OWNER_VALIDATION :: c.int(36) // (c.int enabled)

ERROR_INVALID   :: c.int(3)
ERROR_REFERENCE :: c.int(4)
ERROR_NET       :: c.int(12)
ERROR_SSH       :: c.int(23)
ERROR_MERGE     :: c.int(22)
ERROR_REBASE    :: c.int(29)

OID_SHA1   :: c.int(1)
OID_SHA256 :: c.int(2)

FEATURE_HTTPS :: c.int(1 << 1)
FEATURE_SSH :: c.int(1 << 2)

SORT_NONE        :: c.uint(0)
SORT_TOPOLOGICAL :: c.uint(1 << 0)
SORT_TIME        :: c.uint(1 << 1)
SORT_REVERSE     :: c.uint(1 << 2)

REFERENCE_INVALID  :: c.int(0)
REFERENCE_DIRECT   :: c.int(1)
REFERENCE_SYMBOLIC :: c.int(2)
REFERENCE_ALL      :: REFERENCE_DIRECT | REFERENCE_SYMBOLIC

BRANCH_LOCAL  :: c.int(1)
BRANCH_REMOTE :: c.int(2)
BRANCH_ALL    :: BRANCH_LOCAL | BRANCH_REMOTE

// Since libgit2 2.0, OIDs have a one-byte type tag and 32-byte hash storage.
Oid :: struct {
	type: u8,
	id: [32]u8,
}

Index_Time :: struct {
	seconds: i32,
	nanoseconds: u32,
}

// Keep the public entry layout in sync with the vendored git2/index.h.
Index_Entry :: struct {
	ctime, mtime: Index_Time,
	dev, ino, mode, uid, gid, file_size: u32,
	id: Oid,
	flags, flags_extended: u16,
	path: cstring,
}

Error :: struct {
	message: cstring,
	klass: c.int,
}

Buffer :: struct {
	ptr: cstring,
	reserved, size: c.size_t,
}

Strarray :: struct {
	strings: [^]cstring,
	count: c.size_t,
}

Time :: struct {
	time: i64,
	offset: c.int,
	sign: c.char,
}

Signature :: struct {
	name, email: cstring,
	when_: Time,
}

Certificate :: struct {
	cert_type: c.int,
}

Indexer_Progress :: struct {
	total_objects, indexed_objects, received_objects: c.uint,
	local_objects, total_deltas, indexed_deltas: c.uint,
	received_bytes: c.size_t,
}

Push_Update :: struct {
	src_refname, dst_refname: cstring,
	src, dst: Oid,
}

DIRECTION_FETCH :: c.int(0)
DIRECTION_PUSH :: c.int(1)

Remote_Head :: struct {
	local: c.int,
	oid, loid: Oid,
	name, symref_target: cstring,
}

Credential_Acquire_Callback :: proc "c" (out: ^^Credential, url, username_from_url: cstring, allowed_types: c.uint, payload: rawptr) -> c.int
Certificate_Check_Callback :: proc "c" (cert: ^Certificate, valid: c.int, host: cstring, payload: rawptr) -> c.int
Indexer_Progress_Callback :: proc "c" (stats: ^Indexer_Progress, payload: rawptr) -> c.int
Push_Update_Reference_Callback :: proc "c" (refname, status: cstring, payload: rawptr) -> c.int
Index_Matched_Path_Callback :: proc "c" (path, matched_pathspec: cstring, payload: rawptr) -> c.int

REMOTE_CALLBACKS_VERSION :: c.uint(1)
FETCH_OPTIONS_VERSION :: c.uint(1)
PUSH_OPTIONS_VERSION :: c.uint(1)
PROXY_OPTIONS_VERSION :: c.uint(1)
CHECKOUT_OPTIONS_VERSION :: c.uint(1)
MERGE_OPTIONS_VERSION :: c.uint(1)
COMMIT_CREATE_OPTIONS_VERSION :: c.uint(1)

Remote_Callbacks :: struct {
	version: c.uint,
	// Sideband messages are length-delimited, not necessarily NUL-terminated.
	sideband_progress: proc "c" (text: [^]u8, length: c.int, payload: rawptr) -> c.int,
	completion: proc "c" (kind: c.int, payload: rawptr) -> c.int,
	credentials: Credential_Acquire_Callback,
	certificate_check: Certificate_Check_Callback,
	transfer_progress: Indexer_Progress_Callback,
	update_tips: proc "c" (refname: cstring, old_id, new_id: ^Oid, payload: rawptr) -> c.int,
	pack_progress: proc "c" (stage: c.int, current, total: c.uint, payload: rawptr) -> c.int,
	push_transfer_progress: proc "c" (current, total: c.uint, bytes: c.size_t, payload: rawptr) -> c.int,
	push_update_reference: Push_Update_Reference_Callback,
	push_negotiation: proc "c" (updates: [^]^Push_Update, count: c.size_t, payload: rawptr) -> c.int,
	transport: proc "c" (out: ^^Transport, owner: ^Remote, payload: rawptr) -> c.int,
	remote_ready: proc "c" (remote: ^Remote, direction: c.int, payload: rawptr) -> c.int,
	payload: rawptr,
	resolve_url: proc "c" (resolved: ^Buffer, url: cstring, direction: c.int, payload: rawptr) -> c.int,
	update_refs: proc "c" (refname: cstring, old_id, new_id: ^Oid, spec: ^Refspec, payload: rawptr) -> c.int,
}

PROXY_NONE      :: c.int(0)
PROXY_AUTO      :: c.int(1)
PROXY_SPECIFIED :: c.int(2)

Proxy_Options :: struct {
	version: c.uint,
	type: c.int,
	url: cstring,
	credentials: Credential_Acquire_Callback,
	certificate_check: Certificate_Check_Callback,
	payload: rawptr,
}

FETCH_PRUNE_UNSPECIFIED :: c.int(0)
FETCH_PRUNE :: c.int(1)
FETCH_NO_PRUNE :: c.int(2)
REMOTE_UPDATE_FETCHHEAD :: c.uint(1 << 0)
REMOTE_REDIRECT_NONE :: c.int(1 << 0)
REMOTE_REDIRECT_INITIAL :: c.int(1 << 1)
REMOTE_REDIRECT_ALL :: c.int(1 << 2)
REMOTE_DOWNLOAD_TAGS_UNSPECIFIED :: c.int(0)
REMOTE_DOWNLOAD_TAGS_AUTO :: c.int(1)
REMOTE_DOWNLOAD_TAGS_NONE :: c.int(2)
REMOTE_DOWNLOAD_TAGS_ALL :: c.int(3)

Fetch_Options :: struct {
	version: c.int,
	callbacks: Remote_Callbacks,
	prune: c.int,
	update_fetchhead: c.uint,
	download_tags: c.int,
	proxy_opts: Proxy_Options,
	depth: c.int,
	follow_redirects: c.int,
	custom_headers: Strarray,
}

Push_Options :: struct {
	version, pb_parallelism: c.uint,
	callbacks: Remote_Callbacks,
	proxy_opts: Proxy_Options,
	follow_redirects: c.int,
	custom_headers, remote_push_options: Strarray,
}

CREDENTIAL_USERPASS_PLAINTEXT :: c.uint(1 << 0)
CREDENTIAL_SSH_KEY :: c.uint(1 << 1)
CREDENTIAL_DEFAULT :: c.uint(1 << 3)
CREDENTIAL_USERNAME :: c.uint(1 << 5)

Commit_Header :: struct {
	field, value: cstring,
}

Commit_Create_Flags :: bit_field u32 {
	allow_empty_commit: bool | 1,
}

Commit_Create_Options :: struct {
	version: c.uint,
	flags: Commit_Create_Flags,
	author, committer: ^Signature,
	message_encoding: cstring,
	extra_headers: [^]Commit_Header,
	extra_headers_len: c.size_t,
	sign: proc "c" (builder: ^Commit_Builder, repo: ^Repository, content: cstring, payload: rawptr) -> c.int,
	payload: rawptr,
}

MERGE_ANALYSIS_NORMAL :: c.uint(1 << 0)
MERGE_ANALYSIS_UP_TO_DATE :: c.uint(1 << 1)
MERGE_ANALYSIS_FASTFORWARD :: c.uint(1 << 2)
MERGE_ANALYSIS_UNBORN :: c.uint(1 << 3)
MERGE_FIND_RENAMES :: u32(1 << 0)
MERGE_FAIL_ON_CONFLICT :: u32(1 << 1)

Merge_Options :: struct {
	version: c.uint,
	flags: u32,
	rename_threshold, target_limit: c.uint,
	metric: ^Diff_Similarity_Metric,
	recursion_limit: c.uint,
	default_driver: cstring,
	file_favor: c.int,
	file_flags: u32,
}

REBASE_OPTIONS_VERSION :: c.uint(1)

// Layout of git_rebase_options; both trailing callbacks are pointer-sized.
Rebase_Options :: struct {
	version: c.uint,
	quiet: c.int,
	// In-memory rebases never touch HEAD, the index or the working tree.
	inmemory: c.int,
	rewrite_notes_ref: cstring,
	merge_options: Merge_Options,
	checkout_options: Checkout_Options,
	commit_create_cb: rawptr,
	signing_cb: rawptr,
	payload: rawptr,
}

Rebase_Operation :: struct {
	type: c.int,
	id: Oid,
	exec: cstring,
}

CHECKOUT_SAFE :: c.uint(0)
CHECKOUT_FORCE :: c.uint(1 << 1)
CHECKOUT_RECREATE_MISSING :: c.uint(1 << 2)
CHECKOUT_DONT_OVERWRITE_IGNORED :: c.uint(1 << 19)

Checkout_Perfdata :: struct {
	mkdir_calls, stat_calls, chmod_calls: c.size_t,
}

Checkout_Options :: struct {
	version, checkout_strategy: c.uint,
	disable_filters: c.int,
	dir_mode, file_mode: c.uint,
	file_open_flags: c.int,
	notify_flags: c.uint,
	notify_cb: proc "c" (why: c.uint, path: cstring, baseline, target, workdir: ^Diff_File, payload: rawptr) -> c.int,
	notify_payload: rawptr,
	progress_cb: proc "c" (path: cstring, completed_steps, total_steps: c.size_t, payload: rawptr),
	progress_payload: rawptr,
	paths: Strarray,
	baseline: ^Tree,
	baseline_index: ^Index,
	target_directory: cstring,
	ancestor_label, our_label, their_label: cstring,
	perfdata_cb: proc "c" (perfdata: ^Checkout_Perfdata, payload: rawptr),
	perfdata_payload: rawptr,
}
