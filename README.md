# Git-Workbench

A fast desktop Git client for local repositories, built with Odin, SDL3, Vulkan
and libgit2.

- Browse the history of every branch with a commit graph, search and tags.
- Read diffs of commits and of your working tree. Excel workbooks get a
  spreadsheet-style diff.
- Stage, commit, branch, tag, push, pull and resolve merge conflicts.
- Work inside submodules and in repositories stored in WSL.

**Contents**

- [Getting started](#getting-started): [build](#build-and-run), [first run](#first-run)
- [Using Git-Workbench](#using-git-workbench):
  [history](#history), [diffs](#viewing-changes), [Excel workbooks](#excel-workbooks),
  [working tree](#working-tree), [stage and commit](#stage-and-commit),
  [branches and tags](#branches-and-tags), [sync](#sync-push-and-pull),
  [SSH](#ssh-authentication), [submodules](#submodules),
  [merge editor](#merge-editor), [WSL](#wsl-repositories)
- [Development](#development): [tests](#running-tests), [release](#release-package-windows),
  [shaders](#shaders), [source layout](#source-layout), [conventions](#code-conventions)

---

## Getting started

### Build and run

You need Odin, SDL3 (ships with Odin), Vulkan, and libgit2 with its
dependencies. [src/git/README.md](src/git/README.md) explains how to build
libgit2 with SSH support on Windows (MSYS2 UCRT64).

libgit2 is a Git submodule at `vendor/libgit2`, pinned to the commit the
bindings were written against. After cloning, fetch it once and build it:

```sh
git submodule update --init
```

Then run the commands below from the project root. Fonts are embedded at
compile time, but some tests read files from `assets`.

**Windows (cmd or PowerShell):** builds, then starts the app. Set `ODIN_ROOT`
and `MSYS2_UCRT64` if Odin or MSYS2 are not in their default locations.

```bat
build_and_run.bat
```

**MSYS2 UCRT64 / Linux / macOS:**

```sh
./build_and_run.sh
```

**PowerShell, by hand** (with Odin on PATH):

```powershell
$env:PATH = "$PWD\vendor\libgit2\build-ucrt64;C:\msys64\ucrt64\bin;$env:PATH"
odin build ./src -debug -linker:lld -out:Git-Workbench.exe
.\Git-Workbench.exe
```

On Windows the LLD linker (`-linker:lld`) is required, because libgit2 is
linked through a GNU import archive.

### First run

When `gitaris.json` is missing, empty or incomplete, Git-Workbench opens its
welcome screen:

1. Choose an SSH key file or key folder.
2. Select an existing local Git project.
3. Enter your commit name and email.

Paths can be typed, pasted with Ctrl+V, or chosen with the native file/folder
pickers. Tab and Shift+Tab move between controls.

**Open my workspace** checks the details and saves `gitaris.json` in the
process's **current working directory**. Later launches open the saved project
automatically. Invalid JSON or unavailable paths return to setup with an
explanation.

Only paths and the commit identity are saved, never key contents or
passphrases. The identity is used by the application only; your global Git
settings are not changed.

```json
{
    "ssh_key_path": "C:/Users/you/.ssh",
    "project_path": "C:/Projects/my-project",
    "username": "Your Name",
    "email": "you@example.com"
}
```

> `gitaris.json` keeps its name from the project's early codename so existing
> setups continue to work.

To change settings later, use the top menu:

- **Project** opens another local repository.
- **Preferences** changes your commit name, email or SSH key location.

**Open** and **Save** check the values and update `gitaris.json`; **Cancel**
leaves the current project and saved settings unchanged.

---

## Using Git-Workbench

### History

The workspace opens the combined history of local and remote-tracking branches.

- **Commit graph.** Colored lanes to the left of the messages follow parents,
  split at merges and join at shared ancestors. Branch names and HEAD appear on
  their tip commits, including unmerged branches. Wide graphs scroll sideways
  with a trackpad or the arrow buttons.
- **Branches.** Selecting a branch in the sidebar shows its ancestry without
  checking out any files; **All branches** returns to the combined view.
- **Loading.** History loads in batches of 100; **Load more** continues the
  same graph.
- **Search** filters the loaded messages, authors, hashes and branch labels.
  Graph connections are hidden while filtering so unrelated results are never
  joined.
- **Refresh** reloads the repository and keeps the selected branch and scope.

Empty repositories and detached HEAD are supported. Setup and history browsing
never touch the network; only **Sync** contacts a remote.

### Viewing changes

Select a commit to see its changed files, then select a file to see its diff
(the first file opens automatically).

- Added lines have green backgrounds and deleted lines red ones, with old/new
  line numbers and unchanged context around them.
- The file list and the diff scroll independently. Long lines scroll sideways
  with a trackpad or the diff's arrow buttons.
- Every scrollbar can be dragged; pressing elsewhere on its track jumps there.
  Bars thicken under the pointer to show they can be grabbed.
- **← History** returns to the commit list, keeping its scroll position and
  search.

Changes are compared with the first parent (also for merge commits); a
repository's first commit is compared with an empty tree. Renames, binary
files, empty files and commits without file changes are labelled. Browsing
changes never modifies HEAD, the index or your files.

### Excel workbooks

Workbooks (`.xlsx`, `.xlsm`, `.xltx`, `.xltm`) open as a spreadsheet, like
Excel: lettered columns, numbered rows, gridlines and one tab per sheet along
the bottom. Every row of the sheet is shown.

| You see | Meaning |
| --- | --- |
| Green row | Added |
| Red row, numbered like `−8` | Removed (the number is its row in the previous version) |
| Amber cells | Cells that differ in a changed row |
| Colored bar beside the row number | The kind of change, as above |
| Thick line between rows | Empty rows were skipped |

Cells show values, numbers right-aligned; a formula cell shows its cached
result.

- Click a cell (then use the arrow keys) to see its formula in the formula bar
  above the grid and, for a changed cell, what it was before.
- **↑** / **↓** step through the changed rows; **Changed rows only** hides the
  rest.
- Sheet tabs count their changed rows, or say **new** / **removed**.

**Text** (beside **Grid**) shows the same comparison as plain text:

- Each sheet starts with a `=== Sheet name ===` line, followed by one line per
  non-empty row with cells separated by ` | `.
- The gutter shows spreadsheet row numbers; hunk headers name the sheets they
  touch.
- Formulas appear as `=FORMULA [cached value]` (shared formulas are expanded
  per cell), booleans as TRUE/FALSE, and line breaks inside a cell as `\n`.
- A cell after a long run of empty columns is prefixed with its column, e.g.
  `AZ: value`.

**How rows are matched.** Inserting a row shows one added row, not every later
row changing: formulas are compared in relative R1C1 form, so `=SUM(B3:D3)`
that became `=SUM(B4:D4)` only because its row moved is not a change. A changed
row is paired with its new version in order, or by its first cell when rows
were also added or removed nearby.

**Limitations**

- If only formatting, comments or other non-cell content changed, the diff
  says so.
- Values are shown as stored: dates appear as serial numbers and number formats
  are not applied.
- Inserting a column still changes every row of that sheet.
- Workbooks stored with Git LFS are read from `.git/lfs/objects`; a version that
  has not been downloaded is reported with a `git lfs fetch` hint.
- Legacy `.xls`, binary `.xlsb` and password-protected workbooks cannot be
  read; the diff explains why instead.

### Working tree

**Working tree** (above the history) opens the same diff viewer for your
uncommitted work. It compares the last commit (HEAD) with the index and your
files, like `git diff HEAD`, so staged and unstaged edits appear together.

- Untracked files are listed as **U** with their full content; ignored files
  are not shown.
- Before the first commit, files are compared with an empty tree.
- **Reload** rescans and keeps the selected file.
- Viewing never stages or writes anything.

### Stage and commit

Each file in the working tree shows whether it is **Staged**, **Partly staged**
(staged, then edited again) or **Not staged**. Check the files you want (the
box above the list checks or clears all of them), then:

- **Stage** adds them to the index like `git add -A -- <files>`: new and
  modified files are added, deleted files are removed, and a rename stages both
  its old and new path.
- **Unstage** returns their index entries to the last commit like
  `git restore --staged -- <files>`; your files are not changed.

With nothing checked, Stage and Unstage act on the file being viewed. Other
files are never touched. Conflicted files must be resolved in the
[merge editor](#merge-editor) first.

**Committing.** Type a message in the box beside **Commit** (the first line is
the summary) and press **Commit**. Exactly what is staged is committed on the
current branch, with the name and email from Preferences as author and
committer.

- An empty message or an empty index is refused.
- After resolving a merge, revert or cherry-pick, committing concludes it as
  `git commit` would. During a rebase, finish with Git.
- Git hooks are not run and commits are not signed.
- History and the working tree reload afterwards, and the menu bar confirms the
  commit.

**Editor** (beside Commit) opens a larger commit window:

- A **Summary** line with a character count: 50 is ideal, and over 72 is
  flagged because Git tools cut it off.
- A monospaced **Description** that counts lines over 72 characters.
- The staged files, and how many changed files are not staged.

Enter in the summary moves to the description; **Ctrl+Enter** commits. **Esc**
or **Cancel** closes the window and keeps the draft in the small box (summary,
blank line, description), so nothing is lost.

### Branches and tags

The sidebar switches between **Branches** and **Tags**; **+** creates a branch
or tag at HEAD. On a commit's changes, **Branch…** and **Tag…** create one at
that commit instead. Names are checked as you type against Git's rules (no
spaces, `..`, `~`, `^`, `:` and so on), and existing names are refused.

- **New branch** is `git branch <name> <commit>`. With **Check out the new
  branch** (the default) it is also `git switch`: files are updated safely and
  uncommitted changes come along. If the switch would overwrite them, nothing
  changes and the branch is created but not checked out.
- **Check out** (with a branch selected in the sidebar) switches the same way.
  A remote-tracking branch such as `origin/topic` checks out the local `topic`,
  creating it to track `origin/topic` if needed.
- **Delete** (local branches other than the checked-out one, after a confirming
  click) is `git branch -D`. The menu bar names the old tip so it can be
  recreated.
- **New tag** without a message is a lightweight tag; with a message it is an
  annotated tag by the name and email from Preferences. **Push the tag to
  origin after creating it** pushes it right away.

Tags appear as lime chips on their commits in the history, and search finds
them too. Choosing a tag in the sidebar shows the history leading to it.

- **Push tag** sends it to the branch's remote (otherwise origin).
- **Delete** removes the local tag after a confirming click; a pushed tag stays
  on the remote.
- **Push tags** in Sync pushes every local tag.

Tag pushes never replace a tag that already exists on the remote with a
different commit. Switching branches and creating refs wait while a network
operation is running.

### Sync: push and pull

**Sync** in the top menu shows the checked-out branch, its upstream, and how
many commits it is ahead/behind as of the last fetch. Network operations run in
the background; the menu bar shows progress and the last result.

- **Push** sends the branch to its upstream. A branch without an upstream is
  published as `origin/<branch>` and tracks it from then on (like
  `git push -u`). If the remote has commits you do not have, the push is
  refused.
- **Force push (lease)** asks for confirmation, then replaces the remote branch
  only if it still matches your remote-tracking branch (like
  `git push --force-with-lease`). If someone pushed since your last fetch or
  pull, nothing is overwritten. The check uses the value the server advertises
  during the push, so it holds even if the remote changes mid-operation.
- **Pull** fetches the upstream and updates the branch using the chosen **pull
  strategy**:
  - **Fast-forward only** stops when the branch has diverged.
  - **Rebase local commits** replays your commits on top of the upstream (like
    `git pull --rebase`; merge commits are linearized and already-applied
    commits dropped). The rebase is computed in memory first, so a conflict
    leaves HEAD, the index and your files untouched.

  Either way, uncommitted edits that would be overwritten stop the pull.

The strategy is stored as `pull.rebase` in the repository's `.git/config` (and
updates `branch.<name>.rebase` if that overrides it), so the Git command line
pulls the same way. The panel shows the effective value, including a global
`pull.rebase`. Rebased commits keep their authors; you become the committer.

### SSH authentication

Push, pull and submodule updates try, in order:

1. Unencrypted key files from Preferences (the file itself, or `id_ed25519`,
   `id_ecdsa`, `id_rsa` in the key folder).
2. ssh-agent.
3. Encrypted key files, unlocked with **SSH key passphrase** in the Sync panel.

The passphrase stays in memory for this session only and is never written to
`gitaris.json`. **Forget** clears it, as do a rejected passphrase and a new key
location. If an encrypted key was skipped because no passphrase was entered,
the error says which key needs one. When the key folder holds several
encrypted keys, choose the specific key file in Preferences: a passphrase that
does not unlock the first one stops the push/pull.

Host keys are verified against `known_hosts`. HTTPS remotes are not supported,
because libgit2 does not use Git Credential Manager.

### Submodules

The sidebar lists the open repository's submodules with a status dot:

- **Lime**: checked out at the commit its parent records.
- **Orange**: needs attention.
- **Gray**: not checked out yet.

**Submodules** in the top menu (its badge counts the ones needing attention)
shows each one's path, URL, the commit the parent records and the commit
actually checked out:

| Status | Meaning |
| --- | --- |
| **Up to date** | Checked out at the recorded commit. Untracked files inside are listed but need no action. |
| **Not checked out** | Never cloned here, or its folder is empty or gone. |
| **Other commit** | A different commit is checked out. Update goes back to the recorded one; staging the submodule in the parent records the new one instead. |
| **New commit staged**, **Added**, **Removed** | The parent's index differs from its last commit; commit the parent to record it. |
| **Uncommitted changes** | Edits inside the submodule; open it to commit them. |

**Check status** rereads every submodule. Finding changes inside submodules
means reading all of their files, which libgit2 does slowly on Windows
(seconds for a submodule with thousands of files). So it runs in the
background: the sidebar shows *checking…* meanwhile, and opening the project or
its working tree never waits for it. For the same reason, the working tree
lists a submodule only when its checked-out commit moved; changes inside it are
reported here and committed from inside it.

**Update** (one) and **Update all** work like
`git submodule update --init --recursive`: missing submodules are cloned,
missing commits fetched, and the recorded commit checked out (detached HEAD),
then nested submodules the same way. Local changes inside a submodule are never
overwritten; the update stops and says so. Updates run in the background with
the same SSH keys as Sync. A malformed `.gitmodules` is reported in this view
and does not keep the project from opening.

**Opening a submodule.** **Open** (or clicking a checked-out submodule in the
sidebar, or **Open submodule** on a submodule entry in the working tree diff)
makes the submodule the workspace: history, working tree, staging, commits,
merge editor and sync all apply to it. It is always clear which repository is
open:

- the menu bar shows a breadcrumb such as `my-project › vendor/libgit2` with a
  **SUBMODULE** tag,
- the sidebar names the submodule and its parent,
- the window title shows the full path,
- the commit form and Sync panel name the target repository.

Click a parent in the breadcrumb, or **Back to …** in the sidebar, to return;
the submodule you left is highlighted with its new status. Saving Preferences
inside a submodule keeps it open, and `gitaris.json` keeps the outermost
project. Opening another project leaves the submodule.

### Merge editor

Open **Merge editor** in the top menu to resolve conflicts in the working tree
after a Git merge, rebase or cherry-pick.

1. Select a conflicted file.
2. Look at the next block's **Current (ours)** and **Incoming (theirs)** sides.
3. Choose **Use current**, **Use incoming**, or keep both in the order you
   want: **Current + incoming** or **Incoming + current**.

Each choice replaces only that block, keeps the rest of the file, and puts the
caret in the result where the block was. Standard, diff3 and zdiff3 markers are
supported. During a rebase, ours/theirs have Git's usual meanings: ours is the
rebased-onto state and theirs is the replayed commit.

The **Result** is a text editor:

- Click to place the caret; drag, or hold Shift with the arrow keys, Home/End
  or PageUp/PageDown, to select.
- Ctrl+A, Ctrl+C, Ctrl+X and Ctrl+V work. Typing replaces the selection.
- Tab inserts a tab (tabs line up every four columns); Shift+Tab and Escape
  leave the editor.
- The mouse wheel or the scrollbars move the view.

The same mouse and selection controls work in every text field.

- **Reset result** restores the loaded file. Drafts survive switching files and
  going back to history.
- **Reload conflicts** reloads the index and discards drafts. External changes
  to files or the index require a reload.
- **Save and stage** writes the result and stages only that file, once all
  conflict markers are removed.

Finish the merge, rebase or cherry-pick with Git, or commit the resolution from
**Working tree**. The editor does not start merges. It handles UTF-8 text
only: binary or non-UTF-8 files, missing files, symlinks and submodules show an
explanation and must be resolved elsewhere.

### WSL repositories

Repositories inside the Windows Subsystem for Linux open like any other. Any
of these forms work, for the project and for the SSH key location:

- the path as Windows shows it: `\\wsl.localhost\Ubuntu\home\you\project` (or
  the older `\\wsl$\...`),
- **Linux** in the folder picker,
- a Linux path pasted from a WSL terminal: `/home/you/project` is looked up in
  your default distribution (then the others), and `/mnt/c/...` means the
  Windows drive `C:\...`.

The sidebar tags such repositories **WSL · &lt;distribution&gt;**.

**Ownership check.** Windows reports WSL files as owned by another account, so
Git normally refuses them ("not owned by current user"). Git-Workbench skips
that check for WSL paths only, while a WSL repository is open; every other
repository is still checked. This is safe here because the check guards
against programs and hooks configured by the repository, which this app never
runs. Your global Git settings are not changed, so the Git command line still
needs:

```sh
git config --global --add safe.directory "//wsl.localhost/Ubuntu/home/you/project"
```

A non-WSL repository owned by another Windows user shows that same command.

**SSH inside WSL.** Push, pull and submodule updates of a WSL repository use
your Linux SSH setup too, as `git` inside WSL would:

- Keys in the Linux user's `~/.ssh` (the home the repository is in first, then
  every `/home/<user>`) are offered before the Preferences key.
- A host trusted in the Linux `~/.ssh/known_hosts` (plain or hashed entries) is
  accepted, as well as one in the Windows `known_hosts`.
- An `ssh-agent` running inside WSL cannot be reached from Windows: unlock an
  encrypted key with **SSH key passphrase**, or add it to the Windows OpenSSH
  agent or Pageant.

**Performance.** Windows reads WSL files over a slower file share: history is
quick, but the working tree of a large repository can take a few seconds.
Files with the executable bit may show as mode changes, because Windows cannot
see Linux permissions.

---

## Development

### Running tests

Run from the project root with the same runtime PATH as above (libgit2 and its
DLLs must be found):

```sh
odin test ./src/workspace -linker:lld -vet
odin test ./src/git -linker:lld
odin test ./src/app -linker:lld
odin test ./src/xlsx -vet
odin test ./src/ui
odin test ./src/font
odin test ./src/gpu
```

Optional Vulkan rendering/readback checks (including antialiased graph edges):

```sh
odin test ./src/app -linker:lld -define:TEXT_GPU_TESTS=true
```

### Release package (Windows)

```bat
build_release.bat
```

This builds an optimized exe without a console window and writes a portable
folder to `dist\Git-Workbench` and a zip to `dist\Git-Workbench.zip`. The
folder holds the exe, its runtime DLLs (SDL3, libgit2 and libgit2's MSYS2
dependencies) and license files; fonts and shaders are embedded in the exe. It
honours the same `ODIN_ROOT` and `MSYS2_UCRT64` overrides as
`build_and_run.bat`. `gitaris.json` is read and written in the working
directory.

### Shaders

Everything on screen is drawn as rectangles in one UI batch. Graph lines, round
nodes and rounded corners are rectangles too: the fragment shader
(`shaders/ui_rect.frag`) evaluates an antialiased distance field, so smooth
shapes need neither tessellation nor extra draw calls.

After changing a shader, rebuild with `--compile-shaders` (requires `glslc` on
PATH):

```sh
./build_and_run.sh --compile-shaders
```

The welcome heading uses the bundled Gambarino font with synthesized bold,
since that family contains only the Regular face.

### Source layout

```
src/
├── main.odin        Entry point; calls app.run()
├── app/             The application: state, views, drawing
├── workspace/       Repository logic on top of libgit2 (no UI)
├── git/             libgit2 bindings and higher-level Git operations
├── xlsx/            Reads Excel workbooks (ZIP + XML) into diffable text
├── ui/              Immediate-mode UI library (boxes, widgets, input)
├── font/            FreeType bindings for glyph loading and rasterizing
└── gpu/             Small Vulkan wrapper (device, memory, pipelines, swapchain)
```

**`src/app`**: the application itself.

| File | Contents |
| --- | --- |
| `run.odin` | Window, GPU, fonts and the frame loop |
| `workbench.odin` | Application state (`Workbench`) and the actions views call |
| `views.odin` | Chooses the view to draw, window title, view transitions |
| `view_*.odin` | One file per screen: `welcome`, `settings` (menu bar and settings panels), `history` (sidebar and commit list), `graph`, `changes`, `workbook`, `dialogs` (commit editor, new branch/tag), `merge`, `sync`, `submodules` |
| `controls.odin` | Buttons, fields, checkboxes and scroll areas shared by the views |
| `theme.odin` | Fonts, colors, shared layout sizes and small drawing helpers |
| `draw.odin`, `draw_text.odin` | Turn the UI into GPU geometry and draw it |
| `input_sdl3.odin`, `cursor_sdl3.odin` | SDL3 input events and native cursors |
| `*_tests.odin` | Tests next to the code they check |

**`src/workspace`**: everything the app does to a repository, without UI.

| File | Contents |
| --- | --- |
| `history.odin` | Opening a repository (`Model`), branches, paginated history |
| `graph.odin` | Commit graph lane layout |
| `changes.odin` | Changed files and diff lines of a commit or the working tree |
| `stage.odin` | Stage, unstage and commit |
| `refs.odin` | Branches and tags |
| `merge.odin` | Merge conflict editor |
| `sync.odin` | Upstream status, `pull.rebase`, and the background push/pull worker |
| `submodule.odin` | Submodule status and the background scan and update |
| `workbook_grid.odin` | Lays out a workbook diff as sheets of rows and cells |
| `config.odin` | Loading and saving `gitaris.json` |
| `wsl*.odin`, `known_hosts.odin` | WSL paths and ownership, SSH host key checks |
| `lfs.odin` | Git LFS pointer files |

### Code conventions

- **Names.** Procedures in `src/app` are prefixed by what they belong to:
  `workbench_*` for application actions and views, `theme_*` for drawing
  helpers. Constants are `UPPER_SNAKE_CASE`; colors and fonts start with
  `THEME_`.
- **Logical pixels.** Views lay out in logical pixels and pass a `scale` to the
  helpers, which convert to physical pixels for high-DPI displays. Layout
  variables spell out what they measure (`panel_x`, `inner_w`, `files_w`).
- **Immediate-mode UI.** Each frame, views call widgets that return whether
  they were clicked or changed; there are no retained widget objects. State
  lives in `Workbench` (app) and `workspace.Model` (repository).
- **Memory.** Per-frame strings use `context.temp_allocator`, which is cleared
  every frame. Anything kept longer is cloned and freed explicitly.
- **Tests** live next to the code in `*_tests.odin` files and create throwaway
  repositories in a temporary folder.
