package workspace

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import git "../git"

@(test)
merge_choices_preserve_surrounding_edits_and_line_endings :: proc(t: ^testing.T) {
	cases := [?]struct { text, current, incoming, both: string }{
		{"before\n<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\nafter", "before\nours\nafter", "before\ntheirs\nafter", "before\nours\ntheirs\nafter"},
		{"<<<<<<< HEAD\n=======\ntheirs\n>>>>>>> feature\n", "", "theirs\n", "theirs\n"},
		{"<<<<<<< HEAD\nours\n||||||| base\nold\n=======\n>>>>>>> feature", "ours\n", "", "ours\n"},
		{"prefix\r\n<<<<<<<<< ours\r\né\r\n||||||||| base\r\nold\r\n=========\r\nnew\r\n>>>>>>>>> theirs\r\ntail", "prefix\r\né\r\ntail", "prefix\r\nnew\r\ntail", "prefix\r\né\r\nnew\r\ntail"},
	}
	for item in cases {
		for choice in Merge_Choice {
			file := Merge_File{result = strings.builder_make()}
			strings.write_string(&file.result, item.text)
			testing.expect(t, choose_merge_hunk(&file, choice) == "")
			want := choice == .CURRENT ? item.current : (choice == .INCOMING ? item.incoming : item.both)
			testing.expect(t, strings.to_string(file.result) == want)
			strings.builder_destroy(&file.result)
		}
	}
	file := Merge_File{result = strings.builder_make()}
	defer strings.builder_destroy(&file.result)
	block := "<<<<<<< HEAD\nours\n=======\ntheirs\n>>>>>>> feature\n"
	strings.write_string(&file.result, block)
	strings.write_string(&file.result, "manual edit\n")
	strings.write_string(&file.result, block)
	testing.expect(t, choose_merge_hunk(&file, .CURRENT) == "")
	testing.expect(t, strings.has_suffix(strings.to_string(file.result), block))
	testing.expect(t, choose_merge_hunk(&file, .INCOMING) == "")
	testing.expect(t, strings.to_string(file.result) == "ours\nmanual edit\ntheirs\n")
	malformed := [?]string{"<<<<<<< HEAD\nours\n", "=======\n", "<<<<<<< HEAD\n<<<<<<< nested\n", "<<<<<<< HEAD\n=======\ntheirs\n>>>>>>>> bad-size\n"}
	for text in malformed {
		_, found, err := next_merge_hunk(text)
		testing.expect(t, !found && err != "")
	}
}

@(test)
merge_editor_resolves_real_conflicts_and_preserves_other_work :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !test_ok(t, git.repository_init(&repo, cstring_temp(root), 0)) do return
	defer git.repository_free(repo)
	_ = test_ok(t, git.repository_set_head(repo, "refs/heads/main"))
	settings: ^git.Config
	if !test_ok(t, git.repository_config(&settings, repo)) do return
	_ = test_ok(t, git.config_set_string(settings, "user.name", "Merge fixture"))
	_ = test_ok(t, git.config_set_string(settings, "user.email", "merge@example.invalid"))
	_ = test_ok(t, git.config_set_string(settings, "core.autocrlf", "false"))
	git.config_free(settings)
	names := [?]string{"a.txt", "b.txt"}
	for name in names do testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "before\nbase\nafter\n") == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	base := test_commit(t, repo, "Base")
	for name in names do testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "before\nincoming\nafter\n") == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	incoming := test_commit(t, repo, "Incoming")
	test_ref(t, repo, "refs/heads/feature", &incoming)
	ref: ^git.Reference
	if !test_ok(t, git.reference_create(&ref, repo, "refs/heads/main", &base, 1, nil)) do return
	git.reference_free(ref)
	options: git.Checkout_Options
	_ = test_ok(t, git.checkout_options_init(&options, git.CHECKOUT_OPTIONS_VERSION))
	options.checkout_strategy = git.CHECKOUT_FORCE
	if !test_ok(t, git.checkout_head(repo, &options)) do return
	for name in names do testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "before\ncurrent\nafter\n") == nil)
	if !test_ok(t, git.stage_all(repo)) do return
	head := test_commit(t, repo, "Current")
	annotated: ^git.Annotated_Commit
	if !test_ok(t, git.annotated_commit_lookup(&annotated, repo, &incoming)) do return
	defer git.annotated_commit_free(annotated)
	heads := [1]^git.Annotated_Commit{annotated}
	if !test_ok(t, git.merge(repo, raw_data(heads[:]), 1, nil, nil)) do return

	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Resolver", "resolver@example.invalid"}) == "") do return
	if !testing.expect(t, load_merge(&model) == "" && len(model.merge.files) == 2) do return
	file := &model.merge.files[0]
	testing.expect(t, file.path == "a.txt" && strings.contains(file.original, "<<<<<<<"))
	testing.expect(t, save_merge_file(&model) != "")
	if !testing.expect(t, choose_merge_hunk(file, .BOTH) == "") do return
	testing.expect(t, strings.to_string(file.result) == "before\ncurrent\nincoming\nafter\n")
	// Switching files keeps drafts in memory and never touches the worktree.
	testing.expect(t, select_merge_file(&model, 1) == "")
	testing.expect(t, select_merge_file(&model, 0) == "")
	disk, disk_err := os.read_entire_file(fmt.tprintf("%s/a.txt", root), context.temp_allocator)
	testing.expect(t, disk_err == nil && string(disk) == file.original)
	// A stale editor must not replace edits made by another tool.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.txt", root), "external edit\n") == nil)
	testing.expect(t, strings.contains(save_merge_file(&model), "working file changed"))
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a.txt", root), file.original) == nil)

	index: ^git.Index
	if !test_ok(t, git.repository_index(&index, repo)) do return
	defer git.index_free(index)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/unrelated.txt", root), "staged\n") == nil)
	if !test_ok(t, git.index_add_bypath(index, "unrelated.txt")) do return
	if !test_ok(t, git.index_write(index)) do return
	unrelated := git.index_get_bypath(index, "unrelated.txt", 0).id
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/unrelated.txt", root), "unstaged\n") == nil)
	// A locked index leaves the saved result available for a retry.
	lock := fmt.tprintf("%sindex.lock", string(git.repository_path(repo)))
	testing.expect(t, os.write_entire_file(lock, "locked") == nil)
	testing.expect(t, strings.contains(save_merge_file(&model), "staging failed") && !file.staged)
	testing.expect(t, os.remove(lock) == nil)
	if !testing.expect(t, save_merge_file(&model) == "" && file.staged) do return
	if !test_ok(t, git.index_read(index, 1)) do return
	testing.expect(t, git.index_get_bypath(index, "a.txt", 0) != nil && git.index_get_bypath(index, "a.txt", 2) == nil)
	testing.expect(t, git.index_has_conflicts(index) == 1)
	testing.expect(t, git.oid_equal(&unrelated, &git.index_get_bypath(index, "unrelated.txt", 0).id) == 1)
	if !testing.expect(t, select_merge_file(&model, 1) == "") do return
	testing.expect(t, choose_merge_hunk(&model.merge.files[1], .INCOMING) == "")
	if !testing.expect(t, save_merge_file(&model) == "") do return
	if !test_ok(t, git.index_read(index, 1)) do return
	testing.expect(t, git.index_has_conflicts(index) == 0)
	actual_head: git.Oid
	_ = test_ok(t, git.reference_name_to_id(&actual_head, repo, "HEAD"))
	testing.expect(t, git.oid_equal(&head, &actual_head) == 1 && git.repository_state(repo) != 0)
	testing.expect(t, load_merge(&model) == "" && len(model.merge.files) == 0)
}

@(test)
merge_editor_handles_unsupported_files_and_stale_index :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo: ^git.Repository
	if !test_ok(t, git.repository_init(&repo, cstring_temp(root), 0)) do return
	defer git.repository_free(repo)
	index: ^git.Index
	if !test_ok(t, git.repository_index(&index, repo)) do return
	defer git.index_free(index)
	names := [?]cstring{"binary.dat", "missing.txt", "manual.txt", "invalid.txt"}
	contents := [?]string{"\x00binary", "deleted later", "already resolved\n", "\xff\xfeinvalid"}
	for name, i in names {
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), contents[i]) == nil)
		if !test_ok(t, git.index_add_bypath(index, name)) do return
		entry := git.index_get_bypath(index, name, 0)^
		entry.path = name
		if !test_ok(t, git.index_conflict_add(index, &entry, &entry, &entry)) do return
	}
	if !test_ok(t, git.index_write(index)) do return
	testing.expect(t, os.remove(fmt.tprintf("%s/missing.txt", root)) == nil)
	model: Model
	defer destroy(&model)
	if !testing.expect(t, open(&model, {root, root, "Resolver", "resolver@example.invalid"}) == "") do return
	if !testing.expect(t, load_merge(&model) == "" && len(model.merge.files) == 4) do return
	for &file, i in model.merge.files {
		testing.expect(t, select_merge_file(&model, i) == "")
		if file.path == "manual.txt" {
			testing.expect(t, file.loaded && file.issue == "")
			// An external git add resolves the index, even when the worktree is
			// unchanged. The old editor must not stage over that newer decision.
			if !test_ok(t, git.index_add_bypath(index, "manual.txt")) do return
			if !test_ok(t, git.index_write(index)) do return
			testing.expect(t, strings.contains(save_merge_file(&model), "index conflict changed"))
		} else {
			testing.expect(t, file.issue != "" && !file.loaded && save_merge_file(&model) != "")
		}
	}
}
