package workspace

// Windows side of WSL support: lists the installed distributions.

import win "core:sys/windows"

// Installed WSL distributions by name, the default one first. Read from the
// per-user Lxss registry key that wsl.exe maintains; empty without WSL.
wsl_distributions :: proc() -> [dynamic]string {
	names := make([dynamic]string, context.temp_allocator)
	key: win.HKEY
	if win.RegOpenKeyExW(win.HKEY_CURRENT_USER, win.L(`Software\Microsoft\Windows\CurrentVersion\Lxss`), 0, win.KEY_READ, &key) != 0 {
		return names
	}
	defer win.RegCloseKey(key)
	default_id := registry_string(key, "", "DefaultDistribution")
	for i: u32 = 0; ; i += 1 {
		buffer: [256]u16
		length := u32(len(buffer))
		if win.RegEnumKeyExW(key, i, &buffer[0], &length, nil, nil, nil, nil) != 0 do break
		id, _ := win.wstring_to_utf8(win.wstring(&buffer[0]), int(length))
		name := registry_string(key, id, "DistributionName")
		if name == "" do continue
		if id == default_id {
			inject_at(&names, 0, name)
		} else {
			append(&names, name)
		}
	}
	return names
}

@(private = "file")
registry_string :: proc(key: win.HKEY, subkey, value: string) -> string {
	buffer: [512]u16
	size := u32(size_of(buffer))
	sub: win.wstring = nil
	if subkey != "" do sub = win.utf8_to_wstring(subkey)
	if win.RegGetValueW(key, sub, win.utf8_to_wstring(value), win.RRF_RT_REG_SZ, nil, &buffer[0], &size) != 0 do return ""
	text, _ := win.wstring_to_utf8(win.wstring(&buffer[0]), -1)
	return text
}
