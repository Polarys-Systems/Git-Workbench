package workspace

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

CONFIG_FILE :: "gitaris.json"

Config :: struct {
	ssh_key_path: string,
	project_path: string,
	username: string,
	email: string,
}

config_destroy :: proc(config: ^Config) {
	delete(config.ssh_key_path)
	delete(config.project_path)
	delete(config.username)
	delete(config.email)
	config^ = {}
}

config_clone :: proc(config: Config) -> Config {
	return {strings.clone(config.ssh_key_path), strings.clone(config.project_path),
		strings.clone(config.username), strings.clone(config.email)}
}

config_complete :: proc(config: Config) -> bool {
	return strings.trim_space(config.ssh_key_path) != "" && strings.trim_space(config.project_path) != "" &&
		strings.trim_space(config.username) != "" && strings.trim_space(config.email) != ""
}

// The filename is relative to the process working directory, not the executable.
// Returned config strings are owned; error descriptions use the temp allocator.
config_load :: proc(path := CONFIG_FILE) -> (Config, string) {
	if !os.exists(path) do return {}, ""
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return {}, fmt.tprintf("Could not read %s: %v", path, err)
	text := strings.trim_space(string(data))
	if text == "" do return {}, ""
	parsed: Config
	if !strings.has_prefix(text, "{") do return {}, "gitaris.json must contain a JSON object. Please complete setup again."
	if json.unmarshal(transmute([]u8)text, &parsed, allocator = context.temp_allocator) != nil {
		return {}, "Could not read the JSON in gitaris.json. Please complete setup again."
	}
	return config_clone(parsed), ""
}

// Replace only after a complete write; a failed save leaves the old config intact.
config_save :: proc(config: Config, path := CONFIG_FILE) -> string {
	data, encode_err := json.marshal(config, {pretty = true, use_spaces = true}, context.temp_allocator)
	if encode_err != nil do return "Could not encode the workspace settings."
	file, err := os.create_temp_file(filepath.dir(path), ".gitaris-*.tmp")
	if err != nil do return fmt.tprintf("Could not create gitaris.json in this folder: %v", err)
	temporary := strings.clone(os.name(file), context.temp_allocator)
	defer _ = os.remove(temporary)
	written, write_err := os.write(file, data)
	flush_err := os.flush(file)
	close_err := os.close(file)
	if write_err != nil || written != len(data) || flush_err != nil || close_err != nil {
		return "Could not finish writing gitaris.json. Check the folder permissions and available space."
	}
	if err = os.rename(temporary, path); err != nil do return fmt.tprintf("Could not save gitaris.json: %v", err)
	return ""
}

// Accept pasted paths and ~/ paths; store absolute paths for subsequent launches.
normalize_path :: proc(value: string) -> string {
	path := strings.trim_space(value)
	if len(path) >= 2 && path[0] == '"' && path[len(path) - 1] == '"' do path = path[1:len(path) - 1]
	if path == "" || strings.contains(path, "\x00") do return ""
	if path == "~" || strings.has_prefix(path, "~/") || strings.has_prefix(path, "~\\") {
		home, err := os.user_home_dir(context.temp_allocator)
		if err != nil do return ""
		path = path == "~" ? home : fmt.tprintf("%s/%s", home, path[2:])
	}
	absolute, err := filepath.abs(path, context.temp_allocator)
	return err == nil ? absolute : ""
}
