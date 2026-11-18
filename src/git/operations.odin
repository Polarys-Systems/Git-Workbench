package git

// Higher-level Git operations built on libgit2: fetch, stage, commit,
// push (with a force-with-lease check) and pull (merge or rebase).

import "core:c"

// The returned string borrows libgit2's thread-local storage. Copy it before
// making another libgit2 call if it needs to outlive the current error.
last_error_message :: proc() -> string {
	err := error_last()
	if err == nil || err.message == nil do return "unknown libgit2 error"
	return string(err.message)
}

@(private)
operation_error :: proc(code, klass: c.int, message: cstring) -> c.int {
	_ = error_set_str(klass, message)
	return code
}

// Fetch the named remote's configured refspecs. This does not update HEAD or
// the working tree. Initialize any supplied options with fetch_options_init.
fetch :: proc(repo: ^Repository, remote_name: cstring = "origin", options: ^Fetch_Options = nil) -> c.int {
	remote: ^Remote
	if result := remote_lookup(&remote, repo, remote_name); result != OK do return result
	defer remote_free(remote)
	return remote_fetch(remote, nil, options, nil)
}

// Equivalent to git add -A (including deletions), respecting ignore rules.
// Staging is explicit: commit() never stages working-tree files itself.
stage_all :: proc(repo: ^Repository) -> c.int {
	index: ^Index
	if result := repository_index(&index, repo); result != OK do return result
	defer index_free(index)
	if index_has_conflicts(index) != 0 {
		return operation_error(EUNMERGED, ERROR_MERGE, "resolve index conflicts before staging all files")
	}
	if result := index_update_all(index, nil, nil, nil); result != OK do return result
	if result := index_add_all(index, nil, 0, nil, nil); result != OK do return result
	return index_write(index)
}

// Commit the existing index and update HEAD. Handles initial commits and merge
// parents via libgit2's 2.0 API. Identity defaults to repository/global config.
// Returns EUNCHANGED when there are no staged changes (unless allowed in options).
commit :: proc(repo: ^Repository, message: cstring, options: ^Commit_Create_Options = nil) -> (id: Oid, result: c.int) {
	result = commit_create_from_stage(&id, repo, message, options)
	return
}

@(private)
reject_failed_push :: proc "c" (refname, status: cstring, payload: rawptr) -> c.int {
	if status == nil do return OK
	_ = error_set_str(ERROR_NET, status)
	return EUSER
}

// refspecs must be explicit, e.g. refs/heads/main:refs/heads/main. By default a
// server-side rejection returns EUSER. If supplying push_update_reference,
// the caller's callback must return a negative code on rejection (status != nil).
push :: proc(repo: ^Repository, refspecs: []cstring, remote_name: cstring = "origin", options: ^Push_Options = nil) -> c.int {
	if len(refspecs) == 0 {
		return operation_error(EINVALIDSPEC, ERROR_INVALID, "push requires at least one explicit refspec")
	}
	remote: ^Remote
	if result := remote_lookup(&remote, repo, remote_name); result != OK do return result
	defer remote_free(remote)
	local_options: Push_Options
	if options != nil {
		local_options = options^
	} else {
		if result := push_options_init(&local_options, PUSH_OPTIONS_VERSION); result != OK do return result
	}
	if local_options.callbacks.push_update_reference == nil {
		local_options.callbacks.push_update_reference = reject_failed_push
	}
	specs := Strarray{strings = raw_data(refspecs), count = c.size_t(len(refspecs))}
	return remote_push(remote, &specs, &local_options)
}

// --force-with-lease: the remote ref must still be at `expected` (a zero ID
// means the ref must not exist yet). The check runs during push negotiation,
// and the advertised value it approves is the old value sent to the server, so
// a concurrent update on the server still rejects the push.
Push_Lease :: struct {
	refname: cstring, // Destination ref on the remote, e.g. refs/heads/main.
	expected: Oid,
	rejected: bool,
}

oid_is_zero :: proc "contextless" (id: ^Oid) -> bool {
	for b in id.id do if b != 0 do return false
	return true
}

// Call from a Push_Options.callbacks.push_negotiation callback. Returns EUSER
// (and sets lease.rejected) when the remote moved since it was last fetched.
check_push_lease :: proc "c" (lease: ^Push_Lease, updates: [^]^Push_Update, count: c.size_t) -> c.int {
	for i in 0..<int(count) {
		update := updates[i]
		if update == nil || update.dst_refname == nil || lease.refname == nil do continue
		if string(update.dst_refname) != string(lease.refname) do continue
		// Hashes are compared by content: a zero advertised ID means "absent".
		same := oid_is_zero(&update.src) == oid_is_zero(&lease.expected)
		if same && !oid_is_zero(&update.src) {
			same = update.src.id == lease.expected.id
		}
		if !same {
			lease.rejected = true
			_ = error_set_str(ERROR_NET, "stale info: the remote branch changed since it was last fetched; fetch and review it before force pushing")
			return EUSER
		}
	}
	return OK
}

// A ready-made negotiation callback for callers whose payload is ^Push_Lease.
lease_negotiation :: proc "c" (updates: [^]^Push_Update, count: c.size_t, payload: rawptr) -> c.int {
	if payload == nil do return OK
	return check_push_lease((^Push_Lease)(payload), updates, count)
}

Pull_Result :: enum {
	FAILED,
	UP_TO_DATE,
	FAST_FORWARDED,
	REBASED,
}

// Without `rebase`, equivalent to git pull --ff-only using the current branch's
// configured upstream and its configured remote. No implicit origin/main assumptions.
// Divergence returns ENONFASTFORWARD without changing HEAD/index/worktree.
//
// With `rebase`, divergent local commits are replayed onto the upstream like
// git pull --rebase (merge commits are linearized, already-applied patches are
// skipped). The rebase runs in memory first: if any commit conflicts, it returns
// EMERGECONFLICT and HEAD, the index and the worktree are left unchanged. The
// result is then checked out safely, as for a fast-forward. `committer` defaults
// to the repository's configured identity; original authors are preserved.
//
// An existing local branch with an upstream is required (no unborn/detached HEAD).
// Serialize operations on the repository; worktree updates are not transactional.
pull :: proc(repo: ^Repository, options: ^Fetch_Options = nil, rebase := false, committer: ^Signature = nil) -> (status: Pull_Result, result: c.int) {
	if repository_is_bare(repo) != 0 {
		return .FAILED, operation_error(EBAREREPO, ERROR_INVALID, "pull requires a working tree")
	}
	if repository_state(repo) != 0 {
		return .FAILED, operation_error(EUNMERGED, ERROR_MERGE, "finish the current repository operation before pulling")
	}
	head: ^Reference
	if result = repository_head(&head, repo); result != OK do return
	defer reference_free(head)
	if reference_is_branch(head) == 0 {
		return .FAILED, operation_error(EINVALID, ERROR_REFERENCE, "pull requires an attached local branch")
	}
	branch_name := reference_name(head)
	remote_name: Buffer
	defer buf_dispose(&remote_name)
	if result = branch_upstream_remote(&remote_name, repo, branch_name); result != OK do return
	if string(remote_name.ptr) != "." {
		if result = fetch(repo, remote_name.ptr, options); result != OK do return
	}

	upstream: ^Reference
	if result = branch_upstream(&upstream, head); result != OK do return
	defer reference_free(upstream)
	target: ^Annotated_Commit
	if result = annotated_commit_from_ref(&target, repo, upstream); result != OK do return
	defer annotated_commit_free(target)
	heads := [1]^Annotated_Commit{target}
	analysis, preference: c.uint
	if result = merge_analysis(&analysis, &preference, repo, raw_data(heads[:]), 1); result != OK do return
	if analysis & MERGE_ANALYSIS_UP_TO_DATE != 0 do return .UP_TO_DATE, OK
	if analysis & MERGE_ANALYSIS_FASTFORWARD != 0 {
		result = move_branch(repo, head, annotated_commit_id(target), "pull: fast-forward")
		return result == OK ? .FAST_FORWARDED : .FAILED, result
	}
	if !rebase {
		return .FAILED, operation_error(ENONFASTFORWARD, ERROR_MERGE, "the branch has diverged from its upstream; enable pull with rebase, or merge with Git")
	}
	rebased: Oid
	if result = rebase_in_memory(&rebased, repo, target, committer); result != OK do return .FAILED, result
	if result = move_branch(repo, head, &rebased, "pull --rebase: replay local commits"); result != OK do return .FAILED, result
	return .REBASED, OK
}

// Replay HEAD's commits that are not in `upstream` onto it without touching the
// repository's HEAD, index or worktree. `out` receives the new tip.
@(private)
rebase_in_memory :: proc(out: ^Oid, repo: ^Repository, upstream: ^Annotated_Commit, committer: ^Signature) -> c.int {
	signature := committer
	if signature == nil {
		if result := signature_default(&signature, repo); result != OK do return result
	}
	defer if committer == nil do signature_free(signature)
	options: Rebase_Options
	if result := rebase_options_init(&options, REBASE_OPTIONS_VERSION); result != OK do return result
	options.inmemory = 1
	session: ^Rebase
	if result := rebase_init(&session, repo, nil, upstream, nil, &options); result != OK do return result
	defer rebase_free(session)
	out^ = annotated_commit_id(upstream)^
	for {
		operation: ^Rebase_Operation
		result := rebase_next(&operation, session)
		if result == ITEROVER do break
		if result != OK do return result
		index: ^Index
		if result = rebase_inmemory_index(&index, session); result != OK do return result
		conflicted := index_has_conflicts(index) != 0
		index_free(index)
		if conflicted {
			return operation_error(EMERGECONFLICT, ERROR_REBASE, "a local commit conflicts with the upstream changes; nothing was changed. Rebase in Git and resolve the conflicts there")
		}
		id: Oid
		result = rebase_commit(&id, session, nil, signature, nil, nil)
		if result == EAPPLIED do continue // Already upstream: drop it, like git rebase.
		if result != OK do return result
		out^ = id
	}
	return rebase_finish(session, signature)
}

// Safely check out `target_id` and point HEAD's branch at it. `head` is the
// HEAD reference observed before the operation started; a concurrent change
// to HEAD or the branch aborts with EMODIFIED.
@(private)
move_branch :: proc(repo: ^Repository, head: ^Reference, target_id: ^Oid, message: cstring) -> (result: c.int) {
	branch_name := reference_name(head)
	target_commit: ^Commit
	if result = commit_lookup(&target_commit, repo, target_id); result != OK do return
	defer commit_free(target_commit)
	checkout: Checkout_Options
	if result = checkout_options_init(&checkout, CHECKOUT_OPTIONS_VERSION); result != OK do return
	checkout.checkout_strategy = CHECKOUT_SAFE | CHECKOUT_DONT_OVERWRITE_IGNORED

	// Lock HEAD and its branch before checkout; reject a concurrently changed tip.
	tx: ^Transaction
	if result = transaction_new(&tx, repo); result != OK do return
	defer transaction_free(tx)
	if result = transaction_lock_ref(tx, "HEAD"); result != OK do return
	if result = transaction_lock_ref(tx, branch_name); result != OK do return
	current: ^Reference
	if result = repository_head(&current, repo); result != OK do return
	defer reference_free(current)
	if string(reference_name(current)) != string(branch_name) || oid_equal(reference_target(current), reference_target(head)) == 0 {
		return operation_error(EMODIFIED, ERROR_REFERENCE, "HEAD changed during pull; retry the operation")
	}
	// Queue the ref/reflog update before touching the worktree, but commit it
	// only after the safe checkout succeeds.
	if result = transaction_set_target(tx, branch_name, target_id, nil, message); result != OK do return
	if result = checkout_tree(repo, (^Object)(target_commit), &checkout); result != OK do return
	return transaction_commit(tx)
}
