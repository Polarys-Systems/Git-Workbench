package app

// Native mouse cursor (arrow, hand, I-beam, progress) chosen by the UI.

import "../ui"
import SDL "vendor:sdl3"

System_Cursors :: struct {
	handles: [ui.UiCursor]^SDL.Cursor,
}

// Native cursors retain the user's OS size/theme and are allocated only once.
init_system_cursors :: proc() -> System_Cursors {
	cursors: System_Cursors
	cursors.handles[.POINTER] = SDL.CreateSystemCursor(.POINTER)
	cursors.handles[.TEXT] = SDL.CreateSystemCursor(.TEXT)
	cursors.handles[.PROGRESS] = SDL.CreateSystemCursor(.PROGRESS)
	return cursors
}

destroy_system_cursors :: proc(cursors: ^System_Cursors) {
	_ = SDL.SetCursor(SDL.GetDefaultCursor())
	for handle in cursors.handles do if handle != nil do SDL.DestroyCursor(handle)
	cursors^ = {}
}

update_system_cursor :: proc(cursors: ^System_Cursors, window: ^SDL.Window, cursor: ui.UiCursor) {
	if SDL.GetMouseFocus() != window do return
	handle := cursors.handles[cursor]
	// Unsupported system shapes gracefully fall back to the default arrow.
	if handle == nil do handle = SDL.GetDefaultCursor()
	if handle != nil && SDL.GetCursor() != handle do _ = SDL.SetCursor(handle)
}
