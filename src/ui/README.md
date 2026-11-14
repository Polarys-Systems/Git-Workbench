# Immediate-mode UI

Create one context with `ui.init()` and release it with `ui.destroy(ctx)`.
Feed platform-independent input events **before** `ui.begin`. `ui.end` clears
transient events, retaining held keys/buttons. Pass `pressed = true` to
`input_key` for keyboard repeat events.

```odin
ctx := ui.init()
defer ui.destroy(ctx)
name := strings.builder_make()
defer strings.builder_destroy(&name)
notes := strings.builder_make()
defer strings.builder_destroy(&notes)
enabled := true

// Each frame, after feeding input_mouse_move, input_mouse_button,
// input_key, input_text (UTF-8), and input_scroll:
ui.begin(ctx, width, height)
{
	ui.begin_window(ctx, {20, 20, 400, 340}, "settings")
	// begin_window automatically calls end_window at this scope's exit.
	ui.label(ctx, "Settings")
	if ui.button(ctx, "Save") == .SUBMIT {
		// Save settings.
	}
	ui.check(ctx, "Enabled", &enabled)
	ui.input_box(ctx, "name", &name)
	ui.layout_push_box_size(ctx, {360, 100})
	ui.textbox(ctx, "notes", &notes)
}
ui.end(ctx)
```

## Controls and layout

- `button(ctx, text, rect = AUTO_RECT, align = {.CENTER}, id = "")`
  returns `.SUBMIT` on release inside, `.PRESSED` on mouse-down, `.ACTIVE`
  while held, and `.NOT_ACTIVE` otherwise. A focused button also accepts
  Return/Space. `button_am` is an alias.
- `label(ctx, text, rect = AUTO_RECT, align = {.NONE})` returns its element.
- `check(ctx, text, ^bool, rect = AUTO_RECT, id = "")` toggles on activation
  and returns `.MODIFIED`.
- `input_box(ctx, id, ^strings.Builder, rect = AUTO_RECT)` edits one line;
  Return produces `.SUBMIT`.
- `secret_box(ctx, id, ^strings.Builder, rect = AUTO_RECT)` is an `input_box`
  that draws `*` per character, for passwords and passphrases.
- `textbox(ctx, id, ^strings.Builder, rect = AUTO_RECT)` edits multiple lines;
  Return inserts a newline. Both editors return `.MODIFIED` for changes.

Editors support UTF-8 insertion, Backspace/Delete, arrows, Home/End,
Ctrl+Home/End, and Escape to leave focus. Clicking focuses at the end of the
text; keyboard movement positions the caret. The caller owns the builders.
Multiline text uses explicit newlines, without automatic wrapping.

Interactive IDs are scoped to a window. Buttons/checks use their text by
default; supply an explicit `id` for repeated or changing captions. Keep window
submission order stable for their cached scroll state. Hit testing uses the
previous frame's draw order; new/moved overlapping elements settle on the next
frame. Later windows appear above earlier ones.

Coordinates are top-left based, with Y increasing downwards. Omitted rects
use vertical layout. `layout_row(ctx, n)` starts equal-width columns and wraps
automatically. Negative rect components use layout defaults; a rect with both
coordinates supplied uses absolute coordinates and does not advance layout.
`layout_push`/`layout_pop` and `style_push`/`style_pop` scope overrides; the
`layout_push_*` and `style_push_*` helpers modify the current stack entry.

`UiStyle.border_color` and `focus_color` control normal/focused outlines in
the application renderer. Set `hover_color` and `active_color` for explicit
solid interaction fills (useful for light themes); leaving their alpha zero
retains the default brightness-based highlighting.

### Motion and cursors

Call `set_delta_time(ctx, seconds)` each frame to animate interaction fills,
selection colors, and focus outlines using `UI_Anim_Float`. Transitions take
`UiStyle.transition_duration` seconds (default 0.14; presses use at most 0.07).
Interrupted transitions continue from their displayed color. Recycled element
slots reset on ID changes, so virtual rows never inherit another row's motion.
Set the duration to zero for an instant control, or call
`set_animations_enabled(ctx, false)` to snap all controls to their current state.
Without a positive frame delta, styles are applied immediately.

For view transitions, drive `anim_float_set` / `anim_float_to` /
`anim_float_tick` from caller-owned state. After `end`, use
`fade_elements(ctx, first, last, opacity)` on a submitted element range. It
affects rendering colors only; layout and hit targets stay intact.

After building the frame, `mouse_cursor(ctx)` returns `.POINTER` over buttons
and checks, `.TEXT` over editors, and `.DEFAULT` elsewhere. It respects clipping
and overlapping windows, including decorative labels over clickable rows.
The platform backend maps these to native system cursors; `.PROGRESS` is
available for a caller's busy-state override.

Use `layout_begin_scroll`/`layout_end_scroll` around a window's scrollable
content (one scroll region per window). A pushed layout can define its viewport.
Wheel movement is clamped against the cached content extent. Fully clipped
elements cannot receive pointer input or appear in `next_element` iteration.

## Renderer-independent iteration

After `ui.end`, iterate visible elements in draw order:

```odin
cursor := 0
for element := ui.next_element(ctx, &cursor); element != nil;
    element = ui.next_element(ctx, &cursor) {
	// Apply element.boundary_rect as the clip/scissor.
	// If draw_background: generate a rect using element.rect and element.style.
	// Generate text from strings.to_string(element.text) at element.text_pos,
	// using style.font_id, style.font_size, and style.text_color.
	// If icon != .NONE: generate the icon inside element.icon_rect.
	// If caret_rect.width > 0: generate the caret using style.text_color.
}
```

`ui.elements(ctx)` also exposes the full contiguous slice, including clipped
elements. Both APIs borrow read-only data valid until the next `begin` or
`destroy`. There are no rendering callbacks, GPU dependencies, tree traversal,
sorting, or allocations in iteration.

Pass `measure_text = your_measure_proc` to `init` for your font metrics:

```odin
measure :: proc(font: ui.UiFont, text: string, size: f32) -> [2]f32
```

Return advance width (including trailing spaces) and total line height.
Without a callback, simple monospace metrics are used. Text storage and
measurements are reused per element slot; only changed text, font, or font size
requires remeasurement. Caret measurements are cached too. Call
`set_text_measure` to invalidate metrics after changing the measuring backend
or font data. Buffers retain capacity until `destroy`, so unchanged frames do
not allocate UI memory. `MAX_BOXES` bounds the flat array, including window
backgrounds.

Run the CPU-only checks with `odin test src/ui`.
