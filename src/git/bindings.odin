package git

// Foreign procedure declarations for libgit2 (see README.md in this folder).

import "core:c"

when ODIN_OS == .Windows {
	// The GNU import archive requires Odin's -linker:lld (not RAD Link).
	foreign import libgit2 "../../vendor/libgit2/build-ucrt64/libgit2.dll.a"
} else {
	foreign import libgit2 "system:git2"
}

// Names correspond directly to the C API with the git_ prefix removed.
// All non-null owning output handles must be released using the matching free.
@(default_calling_convention = "c", link_prefix = "git_")
foreign libgit2 {
	libgit2_init :: proc() -> c.int ---
	libgit2_shutdown :: proc() -> c.int ---
	libgit2_version :: proc(major, minor, revision: ^c.int) ---
	libgit2_features :: proc() -> c.int ---
	// Process-wide settings; see the OPT_* constants for the arguments.
	libgit2_opts :: proc(option: c.int, #c_vararg args: ..any) -> c.int ---
	libgit2_feature_backend :: proc(feature: c.int) -> cstring ---
	error_last :: proc() -> ^Error ---
	error_clear :: proc() ---
	error_set_str :: proc(klass: c.int, message: cstring) -> c.int ---
	buf_dispose :: proc(buffer: ^Buffer) ---
	strarray_dispose :: proc(array: ^Strarray) ---
	oid_equal :: proc(a, b: ^Oid) -> c.int ---
	oid_from_string :: proc(out: ^Oid, text: cstring, kind: c.int) -> c.int ---
	oid_tostr :: proc(out: [^]u8, size: c.size_t, id: ^Oid) -> cstring ---

	repository_open :: proc(out: ^^Repository, path: cstring) -> c.int ---
	repository_init :: proc(out: ^^Repository, path: cstring, is_bare: c.uint) -> c.int ---
	repository_free :: proc(repo: ^Repository) ---
	repository_index :: proc(out: ^^Index, repo: ^Repository) -> c.int ---
	repository_config :: proc(out: ^^Config, repo: ^Repository) -> c.int ---
	repository_head :: proc(out: ^^Reference, repo: ^Repository) -> c.int ---
	repository_head_detached :: proc(repo: ^Repository) -> c.int ---
	repository_path :: proc(repo: ^Repository) -> cstring ---
	repository_workdir :: proc(repo: ^Repository) -> cstring ---
	// The shared .git directory (differs from repository_path in linked worktrees).
	repository_commondir :: proc(repo: ^Repository) -> cstring ---
	repository_is_bare :: proc(repo: ^Repository) -> c.int ---
	repository_state :: proc(repo: ^Repository) -> c.int ---
	repository_state_cleanup :: proc(repo: ^Repository) -> c.int ---
	repository_set_head :: proc(repo: ^Repository, refname: cstring) -> c.int ---
	config_set_string :: proc(config: ^Config, name, value: cstring) -> c.int ---
	config_set_bool :: proc(config: ^Config, name: cstring, value: c.int) -> c.int ---
	// Reads the effective value across all levels; ENOTFOUND when unset.
	config_get_bool :: proc(out: ^c.int, config: ^Config, name: cstring) -> c.int ---
	config_free :: proc(config: ^Config) ---

	remote_lookup :: proc(out: ^^Remote, repo: ^Repository, name: cstring) -> c.int ---
	remote_create :: proc(out: ^^Remote, repo: ^Repository, name, url: cstring) -> c.int ---
	remote_create_anonymous :: proc(out: ^^Remote, repo: ^Repository, url: cstring) -> c.int ---
	remote_free :: proc(remote: ^Remote) ---
	remote_url :: proc(remote: ^Remote) -> cstring ---
	remote_connect :: proc(remote: ^Remote, direction: c.int, callbacks: ^Remote_Callbacks, proxy_options: ^Proxy_Options, custom_headers: ^Strarray) -> c.int ---
	remote_disconnect :: proc(remote: ^Remote) -> c.int ---
	remote_ls :: proc(out: ^[^]^Remote_Head, count: ^c.size_t, remote: ^Remote) -> c.int ---
	remote_init_callbacks :: proc(callbacks: ^Remote_Callbacks, version: c.uint) -> c.int ---
	fetch_options_init :: proc(options: ^Fetch_Options, version: c.uint) -> c.int ---
	push_options_init :: proc(options: ^Push_Options, version: c.uint) -> c.int ---
	proxy_options_init :: proc(options: ^Proxy_Options, version: c.uint) -> c.int ---
	remote_fetch :: proc(remote: ^Remote, refspecs: ^Strarray, options: ^Fetch_Options, reflog_message: cstring) -> c.int ---
	remote_push :: proc(remote: ^Remote, refspecs: ^Strarray, options: ^Push_Options) -> c.int ---

	credential_userpass_plaintext_new :: proc(out: ^^Credential, username, password: cstring) -> c.int ---
	credential_username_new :: proc(out: ^^Credential, username: cstring) -> c.int ---
	credential_default_new :: proc(out: ^^Credential) -> c.int ---
	credential_ssh_key_new :: proc(out: ^^Credential, username, publickey, privatekey, passphrase: cstring) -> c.int ---
	credential_ssh_key_from_agent :: proc(out: ^^Credential, username: cstring) -> c.int ---
	credential_get_username :: proc(credential: ^Credential) -> cstring ---
	credential_free :: proc(credential: ^Credential) ---

	index_free :: proc(index: ^Index) ---
	index_read :: proc(index: ^Index, force: c.int) -> c.int ---
	index_write :: proc(index: ^Index) -> c.int ---
	index_entrycount :: proc(index: ^Index) -> c.size_t ---
	index_get_bypath :: proc(index: ^Index, path: cstring, stage: c.int) -> ^Index_Entry ---
	index_add_bypath :: proc(index: ^Index, path: cstring) -> c.int ---
	index_remove_bypath :: proc(index: ^Index, path: cstring) -> c.int ---
	index_add_all :: proc(index: ^Index, pathspec: ^Strarray, flags: c.uint, callback: Index_Matched_Path_Callback, payload: rawptr) -> c.int ---
	index_update_all :: proc(index: ^Index, pathspec: ^Strarray, callback: Index_Matched_Path_Callback, payload: rawptr) -> c.int ---
	index_has_conflicts :: proc(index: ^Index) -> c.int ---
	index_conflict_iterator_new :: proc(out: ^^Index_Conflict_Iterator, index: ^Index) -> c.int ---
	// Entries borrow the index; copy anything needed after index_free.
	index_conflict_next :: proc(ancestor, ours, theirs: ^^Index_Entry, iter: ^Index_Conflict_Iterator) -> c.int ---
	index_conflict_iterator_free :: proc(iter: ^Index_Conflict_Iterator) ---
	index_conflict_get :: proc(ancestor, ours, theirs: ^^Index_Entry, index: ^Index, path: cstring) -> c.int ---
	index_conflict_add :: proc(index: ^Index, ancestor, ours, theirs: ^Index_Entry) -> c.int ---
	index_write_tree :: proc(out: ^Oid, index: ^Index) -> c.int ---
	// The entry is copied into the index (stage 0); unset stat data forces a rehash on the next status.
	index_add :: proc(index: ^Index, source_entry: ^Index_Entry) -> c.int ---
	tree_lookup :: proc(out: ^^Tree, repo: ^Repository, id: ^Oid) -> c.int ---
	tree_free :: proc(tree: ^Tree) ---
	// Owning entry (release with tree_entry_free); ENOTFOUND when the path is absent.
	tree_entry_bypath :: proc(out: ^^Tree_Entry, root: ^Tree, path: cstring) -> c.int ---
	tree_entry_free :: proc(entry: ^Tree_Entry) ---
	tree_entry_id :: proc(entry: ^Tree_Entry) -> ^Oid ---
	tree_entry_filemode :: proc(entry: ^Tree_Entry) -> c.int ---

	diff_options_init :: proc(options: ^Diff_Options, version: c.uint) -> c.int ---
	diff_find_options_init :: proc(options: ^Diff_Find_Options, version: c.uint) -> c.int ---
	diff_tree_to_tree :: proc(out: ^^Diff, repo: ^Repository, old_tree, new_tree: ^Tree, options: ^Diff_Options) -> c.int ---
	// Like `git diff HEAD`: staged and unstaged changes against a tree (nil = empty tree).
	diff_tree_to_workdir_with_index :: proc(out: ^^Diff, repo: ^Repository, old_tree: ^Tree, options: ^Diff_Options) -> c.int ---
	// Staged changes (`git diff --cached`): a tree (nil = empty tree) against the index.
	diff_tree_to_index :: proc(out: ^^Diff, repo: ^Repository, old_tree: ^Tree, index: ^Index, options: ^Diff_Options) -> c.int ---
	// Unstaged changes (`git diff`): the index against the working files.
	diff_index_to_workdir :: proc(out: ^^Diff, repo: ^Repository, index: ^Index, options: ^Diff_Options) -> c.int ---
	diff_find_similar :: proc(diff: ^Diff, options: ^Diff_Find_Options) -> c.int ---
	diff_num_deltas :: proc(diff: ^Diff) -> c.size_t ---
	// Delta/hunk/line pointers borrow their owning diff/patch. Copy before freeing.
	diff_get_delta :: proc(diff: ^Diff, index: c.size_t) -> ^Diff_Delta ---
	diff_free :: proc(diff: ^Diff) ---
	patch_from_diff :: proc(out: ^^Patch, diff: ^Diff, index: c.size_t) -> c.int ---
	patch_free :: proc(patch: ^Patch) ---
	patch_line_stats :: proc(total_context, additions, deletions: ^c.size_t, patch: ^Patch) -> c.int ---
	patch_num_hunks :: proc(patch: ^Patch) -> c.size_t ---
	patch_get_hunk :: proc(out: ^^Diff_Hunk, line_count: ^c.size_t, patch: ^Patch, index: c.size_t) -> c.int ---
	patch_get_line_in_hunk :: proc(out: ^^Diff_Line, patch: ^Patch, hunk, line: c.size_t) -> c.int ---
	// Compares two in-memory buffers as if they were versions of a file at the given paths.
	patch_from_buffers :: proc(out: ^^Patch, old_buffer: rawptr, old_len: c.size_t, old_as_path: cstring,
		new_buffer: rawptr, new_len: c.size_t, new_as_path: cstring, options: ^Diff_Options) -> c.int ---

	blob_lookup :: proc(out: ^^Blob, repo: ^Repository, id: ^Oid) -> c.int ---
	blob_free :: proc(blob: ^Blob) ---
	// The content borrows the blob; copy it before blob_free.
	blob_rawcontent :: proc(blob: ^Blob) -> rawptr ---
	blob_rawsize :: proc(blob: ^Blob) -> u64 ---

	signature_now :: proc(out: ^^Signature, name, email: cstring) -> c.int ---
	signature_default :: proc(out: ^^Signature, repo: ^Repository) -> c.int ---
	signature_free :: proc(signature: ^Signature) ---
	commit_create_options_init :: proc(options: ^Commit_Create_Options, version: c.uint) -> c.int ---
	commit_create_from_stage :: proc(out: ^Oid, repo: ^Repository, message: cstring, options: ^Commit_Create_Options) -> c.int ---
	commit_create :: proc(out: ^Oid, repo: ^Repository, update_ref: cstring, author, committer: ^Signature, encoding, message: cstring, tree: ^Tree, parent_count: c.size_t, parents: [^]^Commit) -> c.int ---
	commit_lookup :: proc(out: ^^Commit, repo: ^Repository, id: ^Oid) -> c.int ---
	commit_free :: proc(commit: ^Commit) ---
	commit_id :: proc(commit: ^Commit) -> ^Oid ---
	commit_message :: proc(commit: ^Commit) -> cstring ---
	commit_summary :: proc(commit: ^Commit) -> cstring ---
	// Metadata pointers borrow the commit's storage; do not free or mutate them.
	commit_author :: proc(commit: ^Commit) -> ^Signature ---
	commit_committer :: proc(commit: ^Commit) -> ^Signature ---
	commit_time :: proc(commit: ^Commit) -> i64 ---
	commit_time_offset :: proc(commit: ^Commit) -> c.int ---
	commit_tree_id :: proc(commit: ^Commit) -> ^Oid ---
	commit_parentcount :: proc(commit: ^Commit) -> c.uint ---
	commit_parent :: proc(out: ^^Commit, commit: ^Commit, n: c.uint) -> c.int ---
	// Parent indices are zero-based; the returned ID borrows the commit's storage.
	commit_parent_id :: proc(commit: ^Commit, n: c.uint) -> ^Oid ---

	// Set sorting before pushing roots: sorting/reset clears the current walk.
	// next returns ITEROVER on completion, not an error.
	revwalk_new :: proc(out: ^^Revwalk, repo: ^Repository) -> c.int ---
	revwalk_free :: proc(walk: ^Revwalk) ---
	revwalk_reset :: proc(walk: ^Revwalk) -> c.int ---
	revwalk_sorting :: proc(walk: ^Revwalk, sort_mode: c.uint) -> c.int ---
	revwalk_push :: proc(walk: ^Revwalk, id: ^Oid) -> c.int ---
	revwalk_push_head :: proc(walk: ^Revwalk) -> c.int ---
	revwalk_push_ref :: proc(walk: ^Revwalk, refname: cstring) -> c.int ---
	revwalk_push_glob :: proc(walk: ^Revwalk, glob: cstring) -> c.int ---
	revwalk_push_range :: proc(walk: ^Revwalk, range: cstring) -> c.int ---
	revwalk_hide :: proc(walk: ^Revwalk, id: ^Oid) -> c.int ---
	revwalk_hide_head :: proc(walk: ^Revwalk) -> c.int ---
	revwalk_hide_ref :: proc(walk: ^Revwalk, refname: cstring) -> c.int ---
	revwalk_hide_glob :: proc(walk: ^Revwalk, glob: cstring) -> c.int ---
	revwalk_simplify_first_parent :: proc(walk: ^Revwalk) -> c.int ---
	revwalk_next :: proc(out: ^Oid, walk: ^Revwalk) -> c.int ---

	reference_lookup :: proc(out: ^^Reference, repo: ^Repository, name: cstring) -> c.int ---
	reference_create :: proc(out: ^^Reference, repo: ^Repository, name: cstring, id: ^Oid, force: c.int, message: cstring) -> c.int ---
	reference_free :: proc(ref: ^Reference) ---
	reference_target :: proc(ref: ^Reference) -> ^Oid ---
	reference_symbolic_target :: proc(ref: ^Reference) -> cstring ---
	reference_type :: proc(ref: ^Reference) -> c.int ---
	reference_resolve :: proc(out: ^^Reference, ref: ^Reference) -> c.int ---
	reference_name :: proc(ref: ^Reference) -> cstring ---
	reference_shorthand :: proc(ref: ^Reference) -> cstring ---
	reference_is_branch :: proc(ref: ^Reference) -> c.int ---
	reference_is_remote :: proc(ref: ^Reference) -> c.int ---
	reference_is_tag :: proc(ref: ^Reference) -> c.int ---
	reference_name_to_id :: proc(out: ^Oid, repo: ^Repository, name: cstring) -> c.int ---
	reference_delete :: proc(ref: ^Reference) -> c.int ---
	// Follows tags (annotated or not) to an object of `type` (OBJECT_COMMIT...).
	reference_peel :: proc(out: ^^Object, ref: ^Reference, type: c.int) -> c.int ---
	reference_name_is_valid :: proc(valid: ^c.int, refname: cstring) -> c.int ---

	object_lookup :: proc(out: ^^Object, repo: ^Repository, id: ^Oid, type: c.int) -> c.int ---
	object_id :: proc(object: ^Object) -> ^Oid ---
	object_free :: proc(object: ^Object) ---

	// Creates refs/heads/<name> at `target`; EEXISTS unless force is set.
	branch_create :: proc(out: ^^Reference, repo: ^Repository, branch_name: cstring, target: ^Commit, force: c.int) -> c.int ---
	// Refuses the checked-out branch.
	branch_delete :: proc(branch: ^Reference) -> c.int ---
	branch_name_is_valid :: proc(valid: ^c.int, name: cstring) -> c.int ---

	// An annotated tag object plus refs/tags/<name>; EEXISTS unless force is set.
	tag_create :: proc(oid: ^Oid, repo: ^Repository, tag_name: cstring, target: ^Object, tagger: ^Signature, message: cstring, force: c.int) -> c.int ---
	tag_create_lightweight :: proc(oid: ^Oid, repo: ^Repository, tag_name: cstring, target: ^Object, force: c.int) -> c.int ---
	tag_delete :: proc(repo: ^Repository, tag_name: cstring) -> c.int ---
	tag_list :: proc(tag_names: ^Strarray, repo: ^Repository) -> c.int ---
	tag_lookup :: proc(out: ^^Tag, repo: ^Repository, id: ^Oid) -> c.int ---
	tag_free :: proc(tag: ^Tag) ---
	// Both borrow the tag's storage.
	tag_message :: proc(tag: ^Tag) -> cstring ---
	tag_tagger :: proc(tag: ^Tag) -> ^Signature ---

	// Both iterator families return ITEROVER when exhausted. Each returned
	// Reference is owned by the caller and must be released with reference_free.
	reference_iterator_new :: proc(out: ^^Reference_Iterator, repo: ^Repository) -> c.int ---
	reference_iterator_glob_new :: proc(out: ^^Reference_Iterator, repo: ^Repository, glob: cstring) -> c.int ---
	reference_next :: proc(out: ^^Reference, iter: ^Reference_Iterator) -> c.int ---
	// The name borrows iterator storage; copy it before advancing/freeing it.
	reference_next_name :: proc(out: ^cstring, iter: ^Reference_Iterator) -> c.int ---
	reference_iterator_free :: proc(iter: ^Reference_Iterator) ---
	branch_iterator_new :: proc(out: ^^Branch_Iterator, repo: ^Repository, list_flags: c.int) -> c.int ---
	branch_next :: proc(out: ^^Reference, out_type: ^c.int, iter: ^Branch_Iterator) -> c.int ---
	branch_iterator_free :: proc(iter: ^Branch_Iterator) ---
	// The abbreviated name borrows the reference's storage.
	branch_name :: proc(out: ^cstring, ref: ^Reference) -> c.int ---
	branch_upstream :: proc(out: ^^Reference, branch: ^Reference) -> c.int ---
	branch_upstream_remote :: proc(out: ^Buffer, repo: ^Repository, refname: cstring) -> c.int ---
	branch_set_upstream :: proc(branch: ^Reference, upstream_name: cstring) -> c.int ---
	// The upstream's ref name on its remote, e.g. refs/heads/main for origin/main.
	branch_upstream_merge :: proc(out: ^Buffer, repo: ^Repository, refname: cstring) -> c.int ---
	graph_ahead_behind :: proc(ahead, behind: ^c.size_t, repo: ^Repository, local, upstream: ^Oid) -> c.int ---
	annotated_commit_from_ref :: proc(out: ^^Annotated_Commit, repo: ^Repository, ref: ^Reference) -> c.int ---
	annotated_commit_lookup :: proc(out: ^^Annotated_Commit, repo: ^Repository, id: ^Oid) -> c.int ---
	annotated_commit_id :: proc(commit: ^Annotated_Commit) -> ^Oid ---
	annotated_commit_free :: proc(commit: ^Annotated_Commit) ---
	merge_analysis :: proc(analysis, preference: ^c.uint, repo: ^Repository, heads: [^]^Annotated_Commit, count: c.size_t) -> c.int ---
	merge_options_init :: proc(options: ^Merge_Options, version: c.uint) -> c.int ---
	merge :: proc(repo: ^Repository, heads: [^]^Annotated_Commit, count: c.size_t, merge_options: ^Merge_Options, checkout_options: ^Checkout_Options) -> c.int ---
	checkout_options_init :: proc(options: ^Checkout_Options, version: c.uint) -> c.int ---
	checkout_tree :: proc(repo: ^Repository, treeish: ^Object, options: ^Checkout_Options) -> c.int ---
	checkout_head :: proc(repo: ^Repository, options: ^Checkout_Options) -> c.int ---
	rebase_options_init :: proc(options: ^Rebase_Options, version: c.uint) -> c.int ---
	rebase_init :: proc(out: ^^Rebase, repo: ^Repository, branch, upstream, onto: ^Annotated_Commit, options: ^Rebase_Options) -> c.int ---
	// Returns ITEROVER once every operation has been applied.
	rebase_next :: proc(operation: ^^Rebase_Operation, rebase: ^Rebase) -> c.int ---
	rebase_inmemory_index :: proc(index: ^^Index, rebase: ^Rebase) -> c.int ---
	rebase_commit :: proc(id: ^Oid, rebase: ^Rebase, author, committer: ^Signature, message_encoding, message: cstring) -> c.int ---
	rebase_finish :: proc(rebase: ^Rebase, signature: ^Signature) -> c.int ---
	rebase_free :: proc(rebase: ^Rebase) ---
	transaction_new :: proc(out: ^^Transaction, repo: ^Repository) -> c.int ---
	transaction_lock_ref :: proc(transaction: ^Transaction, refname: cstring) -> c.int ---
	transaction_set_target :: proc(transaction: ^Transaction, refname: cstring, target: ^Oid, signature: ^Signature, message: cstring) -> c.int ---
	transaction_commit :: proc(transaction: ^Transaction) -> c.int ---
	transaction_free :: proc(transaction: ^Transaction) ---
}
