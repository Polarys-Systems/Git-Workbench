package workspace

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

import git "../git"

test_submodule :: proc(model: ^Model, path: string) -> (Submodule_Info, int) {
	for info, i in model.submodules do if info.path == path do return info, i
	return {}, -1
}

// Records lib (at commit) as a submodule at vendor/lib, the way a fresh
// clone of the parent looks before git submodule update --init.
test_record_submodule :: proc(t: ^testing.T, repo: ^git.Repository, root, url: string, commit: ^git.Oid) {
	testing.expect(t, os.make_directory(fmt.tprintf("%s/vendor", root)) == nil)
	test_write_file(t, root, ".gitmodules", fmt.tprintf("[submodule \"lib\"]\n\tpath = vendor/lib\n\turl = %s\n", url))
	index: ^git.Index
	if !test_ok(t, git.repository_index(&index, repo)) do return
	defer git.index_free(index)
	_ = test_ok(t, git.index_add_bypath(index, ".gitmodules"))
	entry := git.Index_Entry{mode = u32(git.FILEMODE_COMMIT), id = commit^, path = "vendor/lib"}
	_ = test_ok(t, git.index_add(index, &entry))
	_ = test_ok(t, git.index_write(index))
}

@(test)
submodules_report_status_update_and_open :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	// Git config strings treat backslashes as escapes.
	lib_path, _ := strings.replace_all(fmt.tprintf("%s/lib", root), "\\", "/", context.temp_allocator)
	parent_path := fmt.tprintf("%s/parent", root)
	lib := test_repo(t, lib_path)
	if lib == nil do return
	defer git.repository_free(lib)
	test_write_file(t, lib_path, "lib.txt", "v1\n")
	if !test_ok(t, git.stage_all(lib)) do return
	recorded := test_commit(t, lib, "Library v1")
	parent := test_repo(t, parent_path)
	if parent == nil do return
	defer git.repository_free(parent)
	test_record_submodule(t, parent, parent_path, lib_path, &recorded)
	_ = test_commit(t, parent, "Add lib as a submodule")

	model: Model
	defer destroy(&model)
	task: Remote_Task
	defer remote_destroy(&task)
	config := Config{root, parent_path, "Submodule user", "submodule@example.invalid"}
	if !testing.expect(t, open(&model, config) == "") do return
	info, index := test_submodule(&model, "vendor/lib")
	if !testing.expectf(t, index == 0 && len(model.submodules) == 1, "submodules: %q", model.submodule_error) do return
	testing.expect(t, info.name == "lib" && info.url == lib_path && info.head != "" && info.workdir == "")
	testing.expect(t, info.state == .NOT_INITIALIZED && !info.checked_out && submodule_attention(info))
	label, detail := submodule_describe(info, "parent")
	testing.expect(t, label == "Not checked out" && strings.contains(detail, info.head))
	_, location_error := submodule_location(model, index)
	testing.expect(t, location_error != "")
	testing.expect(t, submodule_attention_count(model) == 1)

	// git submodule update --init: clone and check out the recorded commit.
	testing.expect(t, remote_submodule_start(&task, &model, "missing") != "")
	if !testing.expect(t, remote_submodule_start(&task, &model, "lib") == "") do return
	testing.expect(t, remote_submodule_start(&task, &model) != "") // One operation at a time.
	testing.expect(t, remote_wait(&task))
	testing.expectf(t, !task.failed, "update failed: %s", remote_message(&task))
	testing.expect(t, strings.contains(remote_message(&task), "vendor/lib"))
	if !testing.expect(t, refresh(&model) == "") do return
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .CURRENT && info.checked_out && info.workdir == info.head, "state %v", info.state)
	testing.expect(t, !submodule_attention(info) && submodule_attention_count(model) == 0)
	data, read_err := os.read_entire_file(fmt.tprintf("%s/vendor/lib/lib.txt", parent_path), context.temp_allocator)
	// The clone follows the machine's core.autocrlf.
	testing.expect(t, read_err == nil && strings.trim_space(string(data)) == "v1")

	// The checked-out submodule opens as its own workspace.
	sub_path, open_error := submodule_location(model, 0)
	if !testing.expect(t, open_error == "") do return
	child: Model
	defer destroy(&child)
	if !testing.expect(t, open(&child, Config{root, sub_path, "Submodule user", "submodule@example.invalid"}) == "") do return
	testing.expect(t, len(child.commits) == 1 && child.commits[0].message == "Library v1")
	settings: ^git.Config
	if test_ok(t, git.repository_config(&settings, child.repo)) {
		_ = test_ok(t, git.config_set_string(settings, "user.name", "Submodule user"))
		_ = test_ok(t, git.config_set_string(settings, "user.email", "submodule@example.invalid"))
		git.config_free(settings)
	}

	// Untracked files inside count, but do not need attention.
	test_write_file(t, sub_path, "scratch.txt", "notes\n")
	if !testing.expect(t, refresh(&model) == "") do return
	// Loading never looks inside (slow); the scan does, in the background in the app.
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .CURRENT && !info.scanned && submodule_scan_needed(model), "state %v", info.state)
	scan_submodules(&model)
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .UNTRACKED && info.dirty && !submodule_attention(info), "state %v", info.state)
	testing.expect(t, os.remove(fmt.tprintf("%s/scratch.txt", sub_path)) == nil)

	// A new commit inside the submodule differs from the recorded one.
	test_write_file(t, sub_path, "lib.txt", "v2\n")
	if !test_ok(t, git.stage_all(child.repo)) do return
	_ = test_commit(t, child.repo, "Library v2")
	if !testing.expect(t, refresh(&model) == "") do return
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .OTHER_COMMIT && info.workdir != info.head, "state %v", info.state)
	label, detail = submodule_describe(info, "parent")
	testing.expect(t, label == "Other commit" && strings.contains(detail, info.workdir) && strings.contains(detail, info.head))

	// The parent's working tree lists the gitlink; staging it records the new commit.
	if !testing.expect(t, select_working_changes(&model) == "") do return
	file, file_index := test_find_file(&model, "vendor/lib")
	if !testing.expect(t, file_index >= 0) do return
	testing.expect(t, file.new_mode == git.FILEMODE_COMMIT && submodule_for_path(model, file.path) == 0)
	if !testing.expect(t, stage_files(&model, []int{file_index}) == "") do return
	if !testing.expect(t, refresh(&model) == "") do return
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .POINTER_STAGED && info.index == info.workdir, "state %v", info.state)

	// Uncommitted changes inside block an update instead of being overwritten.
	if !testing.expect(t, select_working_changes(&model) == "") do return
	_, file_index = test_find_file(&model, "vendor/lib")
	if !testing.expect(t, file_index >= 0 && unstage_files(&model, []int{file_index}) == "") do return
	if !testing.expect(t, refresh(&model) == "") do return
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .OTHER_COMMIT, "state %v", info.state)
	test_write_file(t, sub_path, "lib.txt", "local edit\n")
	if !testing.expect(t, remote_submodule_start(&task, &model) == "") do return
	testing.expect(t, remote_wait(&task) && task.failed)
	testing.expectf(t, strings.contains(remote_message(&task), "local changes"), "message: %s", remote_message(&task))
	data, read_err = os.read_entire_file(fmt.tprintf("%s/lib.txt", sub_path), context.temp_allocator)
	testing.expect(t, read_err == nil && string(data) == "local edit\n")

	// Without local changes, Update returns it to the recorded commit.
	test_write_file(t, sub_path, "lib.txt", "v2\n")
	if !testing.expect(t, remote_submodule_start(&task, &model, "lib") == "") do return
	testing.expect(t, remote_wait(&task))
	testing.expectf(t, !task.failed, "update failed: %s", remote_message(&task))
	if !testing.expect(t, refresh(&model) == "") do return
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .CURRENT && info.workdir == info.head, "state %v", info.state)

	// The background scan finds edits inside; results for an older load are dropped.
	test_write_file(t, sub_path, "lib.txt", "edited inside\n")
	scan: Submodule_Scan
	defer submodule_scan_destroy(&scan)
	if !testing.expect(t, submodule_scan_start(&scan, &model)) do return
	testing.expect(t, !submodule_scan_start(&scan, &model)) // One at a time.
	if !testing.expect(t, refresh(&model) == "") do return // A newer load.
	thread.join(scan.worker)
	testing.expect(t, !submodule_scan_poll(&scan, &model) && !submodule_scan_busy(&scan))
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expect(t, !info.scanned && info.state == .CURRENT)
	if !testing.expect(t, submodule_scan_start(&scan, &model)) do return
	thread.join(scan.worker)
	testing.expect(t, submodule_scan_poll(&scan, &model) && !submodule_scan_needed(model))
	info, _ = test_submodule(&model, "vendor/lib")
	testing.expectf(t, info.state == .MODIFIED && info.dirty && info.scanned, "state %v", info.state)
	// The working tree lists only moved submodules, never their insides.
	if !testing.expect(t, select_working_changes(&model) == "") do return
	_, file_index = test_find_file(&model, "vendor/lib")
	testing.expect(t, file_index < 0)
}
