# Odin libgit2 bindings

Import from `src/main.odin` with `import git "git"`, or from another `src` package
with `import git "../git"`. These bindings target the vendored **libgit2
2.0.0-rc.1** headers and the UCRT64 build in
`vendor/libgit2/build-ucrt64`. They are **not ABI-compatible with libgit2 1.x**.
Recheck the C layouts if updating the vendored library, especially before 2.0
is stable.

`vendor/libgit2` is a Git submodule (`git submodule update --init` after
cloning). Its build folder is not tracked; the submodule ignores untracked
files, so a local build does not show it as modified. To move to another
libgit2 commit, check it out inside `vendor/libgit2`, rebuild, recheck the
bindings, and commit the new submodule pointer.

## Windows build and runtime

The MinGW build produces `libgit2.dll.a`, not an MSVC `git2.lib`. Select LLD
when building an executable that imports this package. Odin's default RAD
linker crashes on this GNU import archive in the currently installed nightly.

From the project root in **MSYS2 UCRT64**:

```sh
export PATH="$PWD/vendor/libgit2/build-ucrt64:/ucrt64/bin:$PATH"
odin build ./src -debug -linker:lld -out:Git-Workbench.exe
./Git-Workbench.exe
```

Or PowerShell (with `odin` on PATH):

```powershell
$env:PATH = "$PWD\vendor\libgit2\build-ucrt64;C:\msys64\ucrt64\bin;$env:PATH"
odin build ./src -debug -linker:lld -out:Git-Workbench.exe
.\Git-Workbench.exe
```

`libgit2.dll` and its dependencies must be on PATH or beside the executable.
This build directly requires `libcrypto-3-x64.dll`, `libssl-3-x64.dll`,
`libpcre2-8-0.dll`, `libssh2-1.dll`, and `zlib1.dll` from `/ucrt64/bin`, in
addition to Windows system DLLs. Deployment also needs any non-system
dependencies of those DLLs.
Keep matching DLL versions together. Do not copy Windows system DLLs.

Non-Windows builds link `system:git2`; the installed library must have the
same 2.0 ABI. Only Windows/UCRT64 has been tested here.

The application uses these bindings for its configured workspace, branch list,
paginated commit history, and commit/file diffs. `build_and_run.sh` sets the runtime PATH and selects
LLD on Windows/MSYS2. See the root README for first-run setup and `gitaris.json`.

### Rebuilding libgit2 with SSH

From the project root in **MSYS2 UCRT64**:

```sh
pacman -S --needed mingw-w64-ucrt-x86_64-libssh2
cmake -S vendor/libgit2 -B vendor/libgit2/build-ucrt64 -G Ninja \
  -DBUILD_TESTS=OFF -DBUILD_SHARED_LIBS=ON \
  -DREGEX_BACKEND=pcre2 -DUSE_HTTPS=OpenSSL -DUSE_SSH=libssh2
cmake --build vendor/libgit2/build-ucrt64
./vendor/libgit2/build-ucrt64/git2.exe version --build-options
```

The version output should include `backend-ssh: libssh2` and
`backend-https: openssl`. This rebuild retains the same DLL/import-library
paths, so the existing Odin foreign import does not need to change.

## Lifecycle and errors

```odin
import "core:fmt"
import git "git"

// Inside main(), before other Git calls:
assert(git.libgit2_init() > 0)
defer _ = git.libgit2_shutdown()

repo: ^git.Repository
result := git.repository_open(&repo, ".")
if result != git.OK {
	fmt.eprintln(git.last_error_message())
	return
}
defer git.repository_free(repo)
```

Initialize before any Git calls, free every owning handle, then shut down
after all operations and worker threads have finished. All operations below
are synchronous/blocking; keep network calls off the UI thread and serialize
mutating operations on a repository.

The low-level API mirrors C with the `git_` prefix removed (for example,
`remote_fetch`, `commit_create`, `remote_push`, `merge`). Return codes are
`core:c.int`; zero is success for operations. Inspect `last_error_message()`
only after an error. It borrows thread-local storage: copy the string before
another Git call if retaining it, and read it on the thread that failed.

Inputs use `cstring`, not Odin `string`. For runtime strings, use
`strings.clone_to_cstring` and keep the allocation alive for the call, then
`delete` it. Never free libgit2-owned handles or buffers with Odin `delete`.
Use `buf_dispose` / `strarray_dispose` only for buffers returned by libgit2,
not for borrowed caller-supplied `Strarray` storage.

## Basic operations

```odin
// Fetch origin's configured refspecs; HEAD and working files are unchanged.
result = git.fetch(repo)

// Stage explicitly (adds, modifications, deletions; honors .gitignore).
result = git.stage_all(repo)
// Check result before committing.
id, commit_result := git.commit(repo, "Describe the changes")

// Push an explicit branch mapping; never force-pushes unless you request '+'.
refspecs := [1]cstring{"refs/heads/main:refs/heads/main"}
result = git.push(repo, refspecs[:])

// Pull the current branch's configured upstream, equivalent to --ff-only.
pull_status, pull_result := git.pull(repo)
```

Check **each** result before continuing; these are independent examples.

- `fetch(repo, remote_name = "origin", options = nil)` downloads objects and
  updates remote-tracking refs using the named remote's configuration.
- `commit(repo, message, options = nil)` commits **only the existing index**,
  updates HEAD, and uses configured `user.name` / `user.email` by default.
  Initial commits and merge parents are handled by libgit2. `EUNCHANGED` means
  no staged changes. This does not run Git hooks or invoke a signing tool.
- `push(repo, refspecs, remote_name = "origin", options = nil)` requires an
  explicit, nonempty refspec list. A default status callback turns server
  rejections into `EUSER`. If supplying your own `push_update_reference`,
  return a negative code when its `status` argument is non-null. A push of
  several refs may partially succeed; this helper is not an atomic push.
- `pull(repo, options = nil)` fetches the configured upstream remote, then
  safely fast-forwards the current branch. Returns `UP_TO_DATE` or
  `FAST_FORWARDED` on success; divergence returns `ENONFASTFORWARD` and does
  not modify HEAD/index/worktree. Fetch may still update remote-tracking refs.
  Conflicting local edits and ignored files are protected. Requires an
  existing attached branch with an upstream; no automatic merge, rebase,
  initial checkout, or branch guessing. Checkout and reference writes are
  not one atomic filesystem transaction: an I/O failure after checkout can
  leave updated files/index with the old HEAD. Inspect the error before retrying.

- `pull(repo, options, rebase = true, committer)` handles divergence like
  `git pull --rebase`: it replays local commits onto the upstream with an
  **in-memory** rebase (`Rebase_Options.inmemory`), then safely checks out the
  result exactly as for a fast-forward, returning `REBASED`. A conflicting commit
  returns `EMERGECONFLICT` with HEAD/index/worktree unchanged and no rebase state
  left behind. Already-applied commits (`EAPPLIED`) are dropped; merges are
  linearized. `committer` defaults to the configured identity.
- Force-with-lease: push a `+src:dst` refspec and set
  `callbacks.push_negotiation` to `lease_negotiation` with a `^Push_Lease`
  payload (or call `check_push_lease` from your own callback). The lease
  compares the server's advertised value with `expected` (zero = must not
  exist); libgit2 then sends that value as the old ID, so the server rejects a
  concurrent update too.
- `diff_tree_to_workdir_with_index(HEAD tree)` gives `git diff HEAD`; add
  `DIFF_INCLUDE_UNTRACKED | DIFF_RECURSE_UNTRACKED_DIRS | DIFF_SHOW_UNTRACKED_CONTENT`
  to include untracked files (status `DELTA_UNTRACKED`).

To stage selected paths instead of everything, use `repository_index`,
`index_add_bypath` / `index_remove_bypath`, `index_write`, and `index_free`.
After resolving a merge manually, use `repository_state_cleanup` once the
merge commit has succeeded; it is not a worktree/index rollback mechanism.

## History and branch graph data

`Revwalk` walks commit ancestry from one or more tips. Set sorting **before**
pushing roots; use `SORT_TOPOLOGICAL | SORT_TIME` for newest-first history that
keeps children before their parents even when timestamps are inconsistent.
Add `SORT_REVERSE` for the opposite direction. `revwalk_next` returns `ITEROVER`
on normal completion and resets the walk; other nonzero results are errors.
Reapply sorting and push roots again when reusing a reset/completed walker.

```odin
// With core:c, core:fmt, and git imported; repo is already open.
print_history :: proc(repo: ^git.Repository) -> c.int {
	walk: ^git.Revwalk
	result := git.revwalk_new(&walk, repo)
	if result != git.OK do return result
	defer git.revwalk_free(walk)
	result = git.revwalk_sorting(walk, git.SORT_TOPOLOGICAL | git.SORT_TIME)
	if result != git.OK do return result
	for pattern in []cstring{"refs/heads/*", "refs/remotes/*"} {
		result = git.revwalk_push_glob(walk, pattern)
		if result != git.OK do return result
	}
	for {
		id: git.Oid
		result = git.revwalk_next(&id, walk)
		if result == git.ITEROVER do return git.OK
		if result != git.OK do return result
		node: ^git.Commit
		result = git.commit_lookup(&node, repo, &id)
		if result != git.OK do return result
		defer git.commit_free(node) // Released at the end of this loop iteration.
		fmt.printf("%d parents, committed at %d\n",
			git.commit_parentcount(node), git.commit_time(node))
		// Copy IDs from commit_parent_id(node, i), for 0 <= i < parentcount,
		// into your graph data before freeing node.
	}
}
```

Use `revwalk_push_head` to include detached HEAD, or `revwalk_push` /
`revwalk_push_ref` for selected tips. An unborn or missing HEAD needs handling
before pushing it. `revwalk_hide*` excludes a commit and its ancestors;
`revwalk_push_range` accepts `old..new`. First-parent simplification is opt-in
via `revwalk_simplify_first_parent` and omits other merge ancestry.

- `commit_parent_id` returns a borrowed ID; `commit_parent` instead loads an
  owning `Commit` that must be released with `commit_free`.
- `commit_summary`, `commit_author`, and `commit_committer` return borrowed
  data valid while the commit is alive. Treat borrowed pointers as read-only.
  Check nullable results such as `commit_summary` and `commit_parent_id` before
  dereferencing. `commit_time` is signed 64-bit Unix seconds (committer time);
  `commit_time_offset` is minutes from UTC. Author time is in `Signature.when_`.
- `branch_iterator_new` accepts `BRANCH_LOCAL`, `BRANCH_REMOTE`, or `BRANCH_ALL`.
  `branch_next` returns a reference and its branch type. `branch_name` and
  `reference_shorthand` provide borrowed display names.
- `reference_iterator_new` enumerates refs, including tags;
  `reference_iterator_glob_new` filters by full reference name. Use
  `reference_next` for owning references, or `reference_next_name` for a borrowed
  name that must be copied before advancing or freeing the iterator.
- Both iterator families finish with `ITEROVER`. Free every returned reference
  with `reference_free`, then use the matching iterator free function.
- `reference_target` is only available for direct refs. `reference_resolve`
  returns an owning direct reference, including when its input is already
  direct. Annotated tag targets still need peeling to a commit for graph labels.

Keep the repository alive until its walks, iterators, and commits are freed.
Walkers must not be shared concurrently between threads; topological/reverse
walks may preprocess history on the first `revwalk_next` call.

### Commit and file diffs

`diff_tree_to_tree` compares committed trees without consulting the index or
working files. Pass a null old tree for an initial commit. For merge commits,
the workspace compares with parent zero. `diff_find_similar` with
`DIFF_FIND_RENAMES` detects renames before enumerating `diff_num_deltas` /
`diff_get_delta`.

`patch_from_diff` generates one selected file's hunks and lines on demand.
Use `patch_num_hunks`, `patch_get_hunk`, and `patch_get_line_in_hunk`; line content
is length-delimited, not NUL-terminated. Added lines have origin `+`, deleted
lines `-`, and context lines a space. EOF-newline markers are metadata, not
additional changed lines. Check `DIFF_FLAG_BINARY` on the delta after generating
the patch; binary changes do not have a text patch. Renames, empty files, and
mode-only changes may have no hunks.

Delta pointers borrow diff storage; hunk and line pointers borrow patch storage.
Copy retained paths/text, release patches with `patch_free`, and release the
diff with `diff_free` before closing its repository. Initialize any supplied
`Diff_Options` / `Diff_Find_Options` using their versioned initializer.

## Authentication and progress callbacks

This libgit2 build has **SSH enabled through libssh2**
(`USE_SSH=libssh2`), alongside HTTPS/OpenSSL. For SSH URLs, provide a
`Remote_Callbacks.credentials` callback using `credential_ssh_key_new` or
`credential_ssh_key_from_agent` (the latter requires an accessible agent).
The `Userpass_Auth` helper below is for HTTPS, not SSH. Libgit2 does not
automatically use the Git CLI's credential helpers or Git Credential Manager.
Host-key verification remains enabled; configure trusted host keys rather
than accepting unknown or mismatched host keys unconditionally.

### SSH private keys with a passphrase

`SSH_Key_Auth` and `ssh_key_credentials` handle key files, including encrypted
keys. Obtain the passphrase from your UI/CLI at runtime, not from source code,
command-line arguments, or logs. The helper does not prompt on its own:

```odin
auth := git.SSH_Key_Auth{
	username = "git",
	private_key = "C:/Users/sasch/.ssh/id_ed25519",
	passphrase = entered_passphrase, // Runtime cstring from a hidden prompt/UI.
}
options: git.Fetch_Options
assert(git.fetch_options_init(&options, git.FETCH_OPTIONS_VERSION) == git.OK)
options.callbacks.credentials = git.ssh_key_credentials
options.callbacks.payload = &auth
result = git.fetch(repo, options = &options)
```

The same callbacks work with `pull`'s fetch options and with `Push_Options`.
Use a **fresh `SSH_Key_Auth` per operation** (or reset both `attempted` and
`username_attempted`). One key attempt and one username request are permitted,
so incorrect passphrases cannot cause an endless authentication loop. A username
in the remote URL takes precedence over the fallback `username`. Wipe your
passphrase buffer once the synchronous operation returns. Libgit2 owns and
frees successfully returned credentials.

Options **must** be initialized with their corresponding initializer before
setting fields. This preserves libgit2's version fields and safe defaults.

For HTTPS username/token authentication (`token` is a runtime `cstring` from
your credential source; do not embed real secrets in source code):

```odin
auth := git.Userpass_Auth{username = "your-username", password = token}
fetch_options: git.Fetch_Options
assert(git.fetch_options_init(&fetch_options, git.FETCH_OPTIONS_VERSION) == git.OK)
fetch_options.callbacks.credentials = git.userpass_credentials
fetch_options.callbacks.payload = &auth
result = git.fetch(repo, options = &fetch_options)

// A separate operation gets a fresh authentication attempt.
auth.attempted = false
push_options: git.Push_Options
assert(git.push_options_init(&push_options, git.PUSH_OPTIONS_VERSION) == git.OK)
push_options.callbacks.credentials = git.userpass_credentials
push_options.callbacks.payload = &auth
result = git.push(repo, refspecs[:], options = &push_options)
```

The helper makes only one password attempt per operation to prevent endless
retries on bad credentials. Do not share its mutable payload across concurrent
operations. Libgit2 owns credentials successfully returned to its callback.
TLS certificate verification stays enabled; fix trust-store errors rather than
accepting invalid certificates.

`Remote_Callbacks` exposes credentials, transfer progress, sideband messages,
push statuses, and the other transport callbacks. Use `proc "c"` callbacks.
They have no implicit Odin context; set `context = runtime.default_context()`
inside a callback if calling context-dependent Odin code, or restore a context
saved in your payload. Payloads and callback-referenced data must remain valid
until the synchronous operation returns.

## Tests

From the project root in UCRT64, with Odin on PATH:

```sh
export PATH="$PWD/vendor/libgit2/build-ucrt64:/ucrt64/bin:$PATH"
odin test ./src/git -linker:lld -vet
```

Tests create and remove their own temporary repositories. They do not fetch,
commit, push, or pull in this project or contact an external server. Coverage
includes runtime SSH/HTTPS feature checks, C layouts, native option defaults,
credential construction/retry limits, initial/staged/empty commits, ignored
files/deletions, merge ancestry traversal with inconsistent dates, 64-bit commit
timestamps, branch/reference iteration and symbolic resolution, local fetch/push,
fast-forward pulls, conflicting local edits, divergence, and rejected pushes.
The ordinary tests use synthetic credentials and never read real private keys.
Live HTTPS/TLS and SSH server authentication are not part of this test suite.
