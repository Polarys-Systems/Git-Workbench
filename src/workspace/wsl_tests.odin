package workspace

import "core:os"
import "core:strings"
import "core:testing"

import git "../git"

@(test)
wsl_paths_are_recognized_and_named :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	wsl := [?]string{`\\wsl.localhost\Ubuntu\home\ada\project`, `//wsl.localhost/Ubuntu/home/ada`, `\\WSL$\Debian\srv`, `\\wsl$\Debian`}
	for path in wsl do testing.expectf(t, is_wsl_path(path), "%s should be a WSL path", path)
	other := [?]string{`C:\devel\project`, `\\server\share\project`, `\\wsl.localhostish\x`, "/home/ada", ""}
	for path in other do testing.expectf(t, !is_wsl_path(path), "%s should not be a WSL path", path)
	testing.expect(t, wsl_distribution(wsl[0]) == "Ubuntu" && wsl_distribution(wsl[1]) == "Ubuntu")
	testing.expect(t, wsl_distribution(wsl[2]) == "Debian" && wsl_distribution(wsl[3]) == "Debian")
	testing.expect(t, wsl_distribution(other[0]) == "")
}

@(test)
linux_paths_translate_to_windows_paths :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	none: []string
	missing := []string{"NoSuchDistribution-gitaris"}
	// /mnt/<drive> is the Windows drive itself, with or without WSL installed.
	testing.expect(t, wsl_translate("/mnt/c/devel/project", none) == `C:\devel\project`)
	testing.expect(t, wsl_translate("/mnt/D/", none) == `D:\`)
	// Elsewhere it lives in a distribution; the default names the error when absent.
	testing.expect(t, wsl_translate("/home/ada/project/", missing) == `\\wsl.localhost\NoSuchDistribution-gitaris\home\ada\project`)
	testing.expect(t, wsl_translate("/home/ada/project", none) == "")
	not_linux := [?]string{`C:\devel`, "relative/path", "//wsl.localhost/Ubuntu", `\\wsl$\Ubuntu`}
	for path in not_linux do testing.expectf(t, wsl_translate(path, missing) == "", "%s should stay as it is", path)
	when ODIN_OS == .Windows {
		testing.expect(t, normalize_path("/mnt/c/Windows") == `C:\Windows`)
	}
	message := ownership_message(`D:\shared\project`)
	testing.expect(t, strings.contains(message, `safe.directory "D:/shared/project"`))
}

@(test)
wsl_trust_relaxes_ownership_only_while_held :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	if !testing.expect(t, git.libgit2_init() > 0) do return
	defer _ = git.libgit2_shutdown()
	root := test_folder(t)
	defer delete(root)
	defer _ = os.remove_all(root)
	repo := test_repo(t, root)
	if repo == nil do return
	git.repository_free(repo)

	testing.expect(t, owner_validation_enabled())
	wsl_trust_begin()
	wsl_trust_begin()
	testing.expect(t, !owner_validation_enabled())
	// Opening a regular repository checks it, then restores the relaxed state.
	opened: ^git.Repository
	testing.expect(t, open_repository(&opened, root) == git.OK)
	git.repository_free(opened)
	testing.expect(t, !owner_validation_enabled())
	wsl_trust_end()
	testing.expect(t, !owner_validation_enabled()) // Still held once.
	wsl_trust_end()
	testing.expect(t, owner_validation_enabled())
	// Unbalanced ends never leave the check disabled.
	wsl_trust_end()
	testing.expect(t, owner_validation_enabled())

	// A missing WSL folder fails like any missing folder, and leaves the check on.
	model: Model
	defer destroy(&model)
	err := open(&model, Config{root, `\\wsl.localhost\NoSuchDistribution-gitaris\home\x`, "Ada", "ada@example.invalid"})
	testing.expect(t, err != "" && owner_validation_enabled())
	testing.expect(t, open(&model, Config{root, root, "Ada", "ada@example.invalid"}) == "" && !model.wsl && owner_validation_enabled())
}
