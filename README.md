# Git-Workbench

A local Git history viewer built with Odin, SDL3, Vulkan, and libgit2.

## First run

When `gitaris.json` is missing, empty, or incomplete, Git-Workbench opens its welcome
screen. Choose an SSH key file or key directory, select an existing local Git
project, and enter your commit name and email. Paths can be typed, pasted with
Ctrl+V, or selected with the native file/folder pickers. Tab and Shift+Tab move
between controls.

**Open my workspace** validates the details and saves `gitaris.json` in the
process's **current working directory**. Subsequent launches open the saved
project automatically. Invalid JSON or unavailable paths return to setup with
an explanation. Only paths and commit identity are saved, not key contents or
passphrases. The identity is kept by the application; global Git settings are
not changed.

Controls ease between hover, pressed, selected, and focused colors. Views fade
in briefly, with a small entrance motion for welcome and settings panels.
Native cursors show a pointing hand over actions and selectable rows, an I-beam
over editable text, and a progress cursor while a location picker is pending.

```json
{
    "ssh_key_path": "C:/Users/you/.ssh",
    "project_path": "C:/Projects/my-project",
    "username": "Your Name",
    "email": "you@example.com"
}
```

The workspace opens the combined history of local and remote-tracking branches.
A commit graph sits to the left of the messages: colored lanes follow parents,
split at merges, and join at shared ancestors. Branch names and HEAD appear on
their tip commits, including unmerged branches. Selecting a branch browses its
ancestry without checking out files; **All branches** restores the combined view.
History loads in batches of 100; **Load more** continues the existing graph.
Wide graphs scroll horizontally using a trackpad or the arrow buttons. Search
filters loaded messages, authors, hashes, and branch labels; connections are
hidden while filtering so unrelated results are never joined. **Refresh**
reloads repository state while retaining the history scope and selected branch.
Empty repositories and detached HEAD are supported. There are no network
operations during setup or history browsing; only **Sync** contacts a remote.

Graph lines, round nodes and the rounded corners of cards and buttons use
rectangle quads in the existing UI batch. The fragment shader evaluates an
antialiased distance field, so smooth shapes need neither tessellation nor
additional draw calls. After changing shaders, run
`./build_and_run.sh --compile-shaders` (requires `glslc` on PATH).

Select a commit to open its changed files, then select a file to inspect its
diff. Added lines have green backgrounds and deleted lines have red backgrounds,
with old/new line numbers and unchanged context. The first file opens
automatically. Scroll over the file list or diff independently; long lines can
be scrolled horizontally with a trackpad or the diff's arrow buttons. **← History**
returns to the commit list without losing its scroll position or search.
Changes are compared with the first parent (including merge commits); initial
commits are compared with an empty tree. Renames, binary files, empty files,
and commits without file changes are identified explicitly. Browsing changes
does not modify HEAD, the index, or working files.

Excel workbooks (`.xlsx`, `.xlsm`, `.xltx`, `.xltm`) are compared as text: each
sheet starts with a `=== Sheet name ===` line, followed by one line per non-empty
row with cells separated by ` | `. The line numbers in the gutter are spreadsheet
row numbers, and hunk headers name the sheets they touch. Formulas appear as
`=FORMULA [cached value]` (shared formulas are expanded per cell), booleans as
TRUE/FALSE, and cell line breaks as `\n`. A cell after a long run of empty
columns is prefixed with its column, e.g. `AZ: value`.

Inserting a row shows one added line rather than every later row changing:
formulas are compared in relative R1C1 form, so `=SUM(B3:D3)` that became
`=SUM(B4:D4)` only because its row moved is not a change. When a row did change,
the cells that differ are highlighted within it. A changed row is paired with
its new version in order, or by its first cell when rows were also added or
removed nearby.

If only formatting, comments or other non-cell content changed, the diff says
so. Workbooks stored with Git LFS are read from `.git/lfs/objects`; a version
that has not been downloaded is reported with the `git lfs fetch` hint. Values
are shown as stored, so dates appear as serial numbers and number formats are
not applied. Inserting a column still changes every row of that sheet. Legacy
`.xls`, binary `.xlsb`, and password-protected workbooks cannot be read; the
diff explains why instead.

**Working tree** (above the history) opens the same diff viewer for uncommitted
work: the last commit (HEAD) compared with the index and working files, like
`git diff HEAD`, so staged and unstaged edits appear together. Untracked files
are listed as **U** with their full content; ignored files are not shown.
Before the first commit, files are compared with an empty tree. **Reload**
rescans and keeps the selected file. Viewing never stages or writes anything.

### Stage and commit

Each file in the working tree view shows whether it is **Staged**, **Partly
staged** (staged, then edited again), or **Not staged**. Check the files you
want (the box above the list checks or clears all of them), then:

- **Stage** adds them to the index like `git add -A -- <files>`: new and
  modified files are added, deleted files are removed, and a rename stages both
  its old and new path.
- **Unstage** returns their index entries to the last commit like
  `git restore --staged -- <files>`; working files are not changed.

With nothing checked, Stage and Unstage act on the file being viewed. Other
files' staged and unstaged work is never touched. Conflicted files must be
resolved in the Merge editor first.

Type a message in the box beside **Commit** (the first line is the summary)
and press **Commit** to commit exactly what is staged, as the name and email
from Preferences (author and committer), on the current branch. An empty
message or an empty index is refused. Committing after resolving a merge,
revert, or cherry-pick concludes it as `git commit` would; during a rebase,
finish with Git. Git hooks are not run and commits are not signed. History
and the working tree reload afterwards, and the menu bar confirms the commit.

### Sync: push, force push with lease, and pull

**Sync** in the top menu shows the checked-out branch, its upstream, and how
many commits are ahead/behind as of the last fetch. Network operations run in
the background; the menu bar shows progress and the last result.

- **Push** sends the branch to its upstream. A branch without an upstream is
  published as `origin/<branch>` and tracks it from then on (like `git push -u`).
  If the remote has commits you do not have, the push is refused.
- **Force push (lease)** asks for confirmation, then replaces the remote branch
  only if it still matches your remote-tracking branch (like
  `git push --force-with-lease`). If someone pushed since your last fetch or
  pull, nothing is overwritten. The check uses the value the server advertises
  during the push, so it holds even when the remote changes mid-operation.
- **Pull** fetches the upstream and updates the branch. Choose the **pull
  strategy**: **Fast-forward only** stops when the branch has diverged;
  **Rebase local commits** replays your commits on top of the upstream (like
  `git pull --rebase`; merge commits are linearized and already-applied
  commits dropped). The rebase is computed in memory first, so a conflict
  leaves HEAD, the index and your files untouched. Either way, uncommitted
  edits that would be overwritten stop the pull.

The strategy is stored as `pull.rebase` in the repository's `.git/config` (and
updates `branch.<name>.rebase` if that overrides it), so the Git CLI pulls the
same way. The panel shows the effective value, including a global `pull.rebase`.
Rebased commits keep their authors; you become the committer.

SSH authentication tries the unencrypted key files from Preferences (the file
itself, or `id_ed25519`, `id_ecdsa`, `id_rsa` in the key folder), then
ssh-agent, then encrypted key files unlocked with **SSH key passphrase** in the
Sync panel. The passphrase stays in memory for the session only (never written
to `gitaris.json`); **Forget** clears it, as do a rejected passphrase and a new
key location. If an encrypted key was skipped because no passphrase was
entered, the error says which key needs one. When the key folder holds several
encrypted keys, choose the specific key file in Preferences: a passphrase that
does not unlock the first one stops the push/pull. HTTPS remotes are not supported because
libgit2 does not use Git Credential Manager. Host keys are verified against
`known_hosts`.

Use the top menu's **Project** button to open another local repository. Open
**Preferences** to change your commit name, email, or SSH key location. **Open**
and **Save** validate and update `gitaris.json`; **Cancel** leaves the current
project and saved settings unchanged.

### WSL repositories

Repositories inside the Windows Subsystem for Linux open like any other.
Enter the path as Windows shows it (`\\wsl.localhost\Ubuntu\home\you\project`,
or the older `\\wsl$\...`), browse to **Linux** in the folder picker, or paste
the Linux path straight from a WSL terminal: `/home/you/project` is found in
your default distribution (then the others), and `/mnt/c/...` means the Windows
drive `C:\...`. The SSH key location accepts the same forms. The sidebar tags
such repositories **WSL · <distribution>**.

Windows reports WSL files as owned by another account, so Git refuses them
("not owned by current user"). Git-Workbench skips that ownership check for
WSL paths only, while a WSL repository is open; every other repository is
still checked. This is safe here because the check guards against
repository-configured programs and hooks, which this app never runs. Your
global Git settings are not changed, so the Git CLI still needs
`git config --global --add safe.directory "//wsl.localhost/Ubuntu/home/you/project"`.
A non-WSL repository owned by another Windows user shows that same command.

Windows reads WSL files over a slower file share: history is quick, but the
working tree view of a large repository can take a few seconds. Files with the
executable bit may show as mode changes, because Windows cannot see Linux
permissions.

### Submodules

The sidebar lists the open repository's submodules with a status dot: lime
when the submodule is checked out at the commit its parent records, orange when
it needs attention, gray when it is not checked out yet. **Submodules** in the
top menu (its badge counts the ones needing attention) shows each one's path,
URL, the commit the parent records, and the commit actually checked out:

- **Up to date**: checked out at the recorded commit (untracked files inside
  are listed but need no action).
- **Not checked out**: never cloned here, or its folder is empty or gone.
- **Other commit**: the submodule has a different commit checked out. Update
  goes back to the recorded one; staging the submodule in the parent's working
  tree records the new one instead.
- **New commit staged**, **Added**, **Removed**: the parent's index differs
  from its last commit; commit the parent to record it.
- **Uncommitted changes**: edits inside the submodule; open it to commit them.

**Check status** rereads every submodule. Looking inside submodules for
uncommitted or untracked changes means reading every one of their files, which
libgit2 does slowly on Windows (seconds for a submodule with thousands of
files), so it runs in the background: the sidebar shows *checking…* meanwhile,
and opening the project or its working tree never waits for it. For the same
reason the working tree lists a submodule only when its checked-out commit
moved; changes inside it are reported here and committed from inside it.
**Update** (one) and **Update all**
work like `git submodule update --init --recursive`: missing submodules are
cloned, missing commits fetched, and the recorded commit checked out (detached
HEAD), then nested submodules the same way. Local changes inside a submodule are
never overwritten; the update stops and says so. Updates run in the background
with the same SSH keys as Sync. A malformed `.gitmodules` is reported in this
view and does not keep the project from opening.

**Open** (or clicking a checked-out submodule in the sidebar, or **Open
submodule** on a submodule entry in the working tree diff) makes the submodule
the workspace: history, working tree, staging, commits, merge editor and sync
all apply to it. It is always clear which repository is open: the menu bar
shows a breadcrumb such as `TransactionsViewer › vendor/libgit2` with a
**SUBMODULE** tag, the sidebar names the submodule and its parent, the window
title shows the full path, and the commit form and Sync panel name the target
repository. Click a parent in the breadcrumb, or **Back to …** in the sidebar,
to return; the submodule you left is highlighted with its new status. Saving
Preferences inside a submodule keeps it open, and `gitaris.json` keeps the
outermost project. Opening another project leaves the submodule.

### Merge editor

Open **Merge editor** in the top menu to resolve conflicts in the current working
tree after a Git merge, rebase, or cherry-pick. Select a conflicted file, inspect
the next block's **Current (ours)** and **Incoming (theirs)** sides, then choose
**Use current**, **Use incoming**, or **Use both** (current followed by incoming).
Each choice replaces only that block, preserving the rest of the file. Standard,
diff3, and zdiff3 markers are supported. During a rebase, ours/theirs have Git's
usual meanings: ours is the rebased-onto state and theirs is the replayed commit.

The **Result** is editable using the arrow keys, Home/End, Ctrl+Home/Ctrl+End,
Enter, Backspace/Delete, and Ctrl+V. **Reset result** restores the loaded file;
drafts survive file switches and trips back to history. **Reload conflicts**
reloads the index and discards drafts. **Save and stage** writes the result and
stages only that file after all conflict markers are removed. External file or
index changes require a reload. Finish the merge/rebase/cherry-pick with Git.

This is a UTF-8 text conflict editor. Binary/non-UTF-8 files, missing files,
symlinks, and submodules show an explanation and require external resolution.
It does not start merges; commit the resolution from **Working tree**.

The welcome heading uses the bundled Gambarino font with synthesized bold,
since the supplied family contains only the Regular face.

## Build and run

Run the commands below from the project root; fonts are embedded at compile
time, but some tests read files from `assets`. Install Odin,
SDL3, Vulkan, and the libgit2 dependencies described in [src/git/README.md](src/git/README.md).

libgit2 is a Git submodule at `vendor/libgit2`, pinned to the commit the
bindings were written against. After cloning, fetch it once, then build it as
described in [src/git/README.md](src/git/README.md):

```sh
git submodule update --init
```

MSYS2 UCRT64:

```sh
./build_and_run.sh
```

PowerShell, with Odin on PATH:

```powershell
$env:PATH = "$PWD\vendor\libgit2\build-ucrt64;C:\msys64\ucrt64\bin;$env:PATH"
odin build ./src -debug -linker:lld -out:Git-Workbench.exe
.\Git-Workbench.exe
```

### Release package (Windows)

```bat
build_release.bat
```

This builds an optimized exe without a console window and writes a portable
folder to `dist\Git-Workbench` and a zip to `dist\Git-Workbench.zip`.
The folder contains the exe, its runtime DLLs (SDL3, libgit2 and libgit2's MSYS2
dependencies) and license files; fonts and shaders are embedded in the exe. It
honours the same `ODIN_ROOT` and `MSYS2_UCRT64` overrides as
`build_and_run.bat`. `gitaris.json` is read and written in the working
directory.

CPU checks (using the same runtime PATH):

```sh
odin test ./src/workspace -linker:lld -vet
odin test ./src/xlsx -vet
odin test ./src/app -linker:lld
odin test ./src/ui
```

Optional Vulkan rendering/readback checks (including antialiased graph edges):

```sh
odin test ./src/app -linker:lld -define:TEXT_GPU_TESTS=true
```

## Source layout

- `src/main.odin`: entry point calling `app.run()`.
- `src/app/run.odin`: native window, resources, input, and render loop.
- `src/app/gitaris.odin`: application state, settings, and file-picker actions.
- `src/app/gitaris_ui.odin`: view selection and transitions. Individual
  `gitaris_*_ui.odin` files contain welcome, settings, history, changes, graph,
  merge and sync views; `gitaris_controls.odin` holds their shared controls.
- `src/workspace/sync.odin`: upstream status, the `pull.rebase` setting, and the
  background push/pull worker (its own repository handle on a thread).
- `src/workspace/submodule.odin`: submodule status, descriptions, and the
  background `--init --recursive` update; `src/app/gitaris_submodules_ui.odin`
  is its view, and `gitaris.odin` keeps the parent/submodule breadcrumb.
- `src/workspace/stage.odin`: per-file stage state, Stage/Unstage of selected
  files, and committing the index with the configured identity.
- `src/app/*_tests.odin`: application and rendering checks alongside the code.
- `src/workspace`: repository operations and persisted configuration.
- `src/xlsx`: ZIP and streaming XML readers that turn workbooks into diffable
  text (`odin test ./src/xlsx -vet`).
- `src/git`: libgit2 bindings; `src/ui`, `src/font`, and `src/gpu`: reusable UI
  and rendering libraries.
