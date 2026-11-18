package app

// Startup and the frame loop: creates the window, GPU device, swapchain and fonts,
// then each frame reads input, builds the UI, and draws it.

import "core:math"
import "core:strings"

import font_core "../font"
import "../git"
import "../gpu"
import "../ui"
import SDL "vendor:sdl3"

WINDOW_TITLE :: "Git-Workbench"
WINDOW_SIZE :: [2]i32{1600, 900}
WINDOW_MIN_SIZE :: [2]i32{1000, 720}

// The embedded font faces. Each needs its own FreeType face id.
Fonts :: struct {
	body, title, icons, welcome, code: font_core.Face,
}

run :: proc() {
	// `ensure` (unlike `assert`) is never compiled out, so it may do the work it checks.
	ensure(git.libgit2_init() > 0, "Could not initialize libgit2")
	defer _ = git.libgit2_shutdown()
	ensure(SDL.Init(SDL.INIT_VIDEO), "Could not initialize SDL video")
	defer SDL.Quit()
	ensure(SDL.Vulkan_LoadLibrary(nil), "Could not load Vulkan")
	defer SDL.Vulkan_UnloadLibrary()

	window := SDL.CreateWindow(WINDOW_TITLE, WINDOW_SIZE.x, WINDOW_SIZE.y, {.VULKAN, .RESIZABLE, .HIGH_PIXEL_DENSITY})
	ensure(window != nil, "Could not create window")
	defer SDL.DestroyWindow(window)
	_ = SDL.SetWindowMinimumSize(window, WINDOW_MIN_SIZE.x, WINDOW_MIN_SIZE.y)
	cursors := init_system_cursors()
	defer destroy_system_cursors(&cursors)

	device, device_result := gpu.init({
		window = window,
		validation = ODIN_DEBUG,
		synchronization_validation = ODIN_DEBUG,
		buffer_device_address = true,
		gpu_timestamps = true,
	})
	check(device_result)
	defer check(gpu.shutdown(&device))

	swapchain, swapchain_result := gpu.create_swapchain(device, window)
	check(swapchain_result)
	defer check(gpu.destroy_swapchain(&swapchain))

	text_batch := init_text_batch(device, gpu.swapchain_format(swapchain))
	fonts := load_fonts()
	defer destroy_fonts(&fonts)
	defer check(destroy_text_batch(device, &text_batch))

	ui_ctx := ui.init(measure_text = ui_measure_text)
	defer ui.destroy(ui_ctx)
	state: Workbench
	workbench_init(&state)
	defer workbench_destroy(&state)
	// The native file/folder pickers report back through this custom event.
	state.picker_event = SDL.RegisterEvents(1)
	text_input_active := false
	defer if text_input_active do _ = SDL.StopTextInput(window)

	clear_color := srgb_to_linear(THEME_BACKGROUND)
	previous_ticks := SDL.GetTicksNS()
	rebuild_swapchain := false

	for {
		defer free_all(context.temp_allocator)
		scale := max(1, SDL.GetWindowPixelDensity(window))

		// 1. Input.
		quit := poll_events(ui_ctx, &state, scale, &rebuild_swapchain)
		if quit do break

		// 2. Make sure there is a swapchain matching the window.
		if rebuild_swapchain {
			if !recreate_swapchain(device, swapchain, &text_batch) {
				SDL.Delay(16) // Minimized or mid-resize: try again shortly.
				continue
			}
			rebuild_swapchain = false
		}
		command, frame_result := gpu.start_frame(swapchain)
		if frame_result == .SWAPCHAIN_OUT_OF_DATE {
			rebuild_swapchain = true
			continue
		}
		check(frame_result)

		// 3. Build this frame's UI.
		ticks := SDL.GetTicksNS()
		ui.set_delta_time(ui_ctx, f32(f64(ticks - previous_ticks) / 1e9))
		previous_ticks = ticks
		extent := gpu.swapchain_extent(swapchain)
		workbench_ui(ui_ctx, &fonts.body, &fonts.title, &fonts.welcome, &fonts.icons, &state, window,
			f32(extent.width), f32(extent.height), scale, &fonts.code)

		// 4. Pass what the UI asked for on to the operating system.
		update_system_cursor(&cursors, window, state.picker_pending ? .PROGRESS : ui.mouse_cursor(ui_ctx))
		copy_requested_text(ui_ctx)
		text_input_active = update_text_input(ui_ctx, window, scale, text_input_active)

		// 5. Draw and present.
		render_frame(&text_batch, ui_ctx, command, swapchain, clear_color)
		end_result := gpu.end_frame(swapchain)
		if end_result == .SWAPCHAIN_OUT_OF_DATE {
			rebuild_swapchain = true
		} else {
			check(end_result)
		}
	}
}

// Stops the program with a readable message when a GPU call fails.
check :: proc(result: gpu.Result, loc := #caller_location) {
	ensure(result == .NONE, gpu.result_string(result), loc)
}

load_fonts :: proc() -> (fonts: Fonts) {
	load :: proc(id: u32, data: []byte, name: string) -> font_core.Face {
		face, loaded := font_core.face_load_from_data(id, data)
		ensure(loaded, strings.concatenate({"Could not load the ", name, " font"}))
		return face
	}
	fonts.body = load(0, THEME_BODY_FONT, "Satoshi body")
	fonts.title = load(1, THEME_TITLE_FONT, "Satoshi title")
	fonts.icons = load(2, THEME_ICON_FONT, "icon")
	fonts.welcome = load(3, THEME_WELCOME_FONT, "Gambarino welcome")
	fonts.code = load(4, THEME_DIFF_FONT, "Geist Mono diff")
	return
}

destroy_fonts :: proc(fonts: ^Fonts) {
	font_core.face_destroy(&fonts.code)
	font_core.face_destroy(&fonts.welcome)
	font_core.face_destroy(&fonts.icons)
	font_core.face_destroy(&fonts.title)
	font_core.face_destroy(&fonts.body)
}

// Feeds all pending SDL events to the UI. Returns true when the user closes the window.
poll_events :: proc(ctx: ^ui.UiContext, state: ^Workbench, scale: f32, rebuild_swapchain: ^bool) -> (quit: bool) {
	ui.input_reset(ctx)
	event: SDL.Event
	for SDL.PollEvent(&event) {
		if u32(event.type) == state.picker_event {
			workbench_picker_event(state, &event)
			continue
		}
		input_process_sdl_event(ctx, &event, scale)
		#partial switch event.type {
		case .QUIT, .WINDOW_CLOSE_REQUESTED:
			quit = true
		case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_MINIMIZED, .WINDOW_RESTORED:
			rebuild_swapchain^ = true
		}
	}
	return
}

// Resizes the swapchain to the window. Returns false when that is not possible
// yet (for example while minimized); the caller tries again next frame.
recreate_swapchain :: proc(device: ^gpu.Device, swapchain: ^gpu.Swapchain, text_batch: ^Text_Batch) -> bool {
	result := gpu.update_swapchain(swapchain)
	if result == .SWAPCHAIN_OUT_OF_DATE do return false
	check(result)
	// A new size only changes the projection, but the surface may also pick a
	// different pixel format, which the pipeline is built for.
	format := gpu.swapchain_format(swapchain)
	if text_batch.pipeline.colors[0] != format {
		check(destroy_text_batch(device, text_batch))
		text_batch^ = init_text_batch(device, format)
	}
	return true
}

// Ctrl+C / Ctrl+X in a text field: the UI asks, the OS clipboard receives.
copy_requested_text :: proc(ctx: ^ui.UiContext) {
	if !ctx.clipboard_pending do return
	text := strings.clone_to_cstring(strings.to_string(ctx.clipboard), context.temp_allocator)
	_ = SDL.SetClipboardText(text)
	ctx.clipboard_pending = false
}

// Turns the OS text input (and the IME candidate window) on while an editable
// field has focus, positioned at its caret. Returns whether text input is now on.
update_text_input :: proc(ctx: ^ui.UiContext, window: ^SDL.Window, scale: f32, active: bool) -> bool {
	focused: ^ui.UiBox
	for &box in ui.elements(ctx) {
		if box.focused && .EDITABLE in box.actions {
			focused = &box
			break
		}
	}
	if focused != nil {
		rect := focused.rect
		area := SDL.Rect{i32(rect.x / scale), i32(rect.y / scale), i32(rect.width / scale), i32(rect.height / scale)}
		caret_offset := i32((focused.caret_rect.x - rect.x) / scale)
		_ = SDL.SetTextInputArea(window, &area, caret_offset)
	}
	wanted := focused != nil
	if wanted == active do return active
	if wanted do return SDL.StartTextInput(window)
	_ = SDL.StopTextInput(window)
	return false
}

// Records and submits the draw commands for one frame. GPU timing sections
// measure setup, the UI draw and the finish separately.
render_frame :: proc(batch: ^Text_Batch, ctx: ^ui.UiContext, command: ^gpu.Command, swapchain: ^gpu.Swapchain, clear_color: [4]f32) {
	queued := draw_ui(batch, ctx)
	ensure(queued, "Could not queue UI geometry")
	check(text_prepare_render(batch))
	extent := gpu.swapchain_extent(swapchain)

	check(gpu.begin_gpu_timing(command, .RENDER_SETUP))
	check(gpu.begin_render(command, {
		area = {extent = extent},
		colors = []gpu.Attachment{{
			texture = gpu.swapchain_target(swapchain),
			load = .CLEAR,
			store = .STORE,
			clear = {color = {float32 = clear_color}},
		}},
	}))
	check(gpu.end_gpu_timing(command, .RENDER_SETUP))

	check(gpu.begin_gpu_timing(command, .TEXT_DRAW))
	check(text_render(batch, command, extent))
	check(gpu.end_gpu_timing(command, .TEXT_DRAW))

	check(gpu.begin_gpu_timing(command, .RENDER_FINISH))
	check(gpu.end_render(command))
	check(gpu.end_gpu_timing(command, .RENDER_FINISH))
}

// Rectangle colors are decoded by the fragment shader, but a render pass
// clear bypasses it, so the clear color must be converted to linear first.
srgb_to_linear :: proc(color: [4]f32) -> [4]f32 {
	linear := color
	for &channel in linear[:3] {
		channel = channel <= 0.04045 ? channel / 12.92 : math.pow((channel + 0.055) / 1.055, 2.4)
	}
	return linear
}
