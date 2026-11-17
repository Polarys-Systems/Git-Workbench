package app

import "core:math"
import "core:strings"

import font_core "../font"
import "../gpu"
import "../ui"
import "../git"
import SDL "vendor:sdl3"

run :: proc() {
	assert(git.libgit2_init() > 0, "Could not initialize libgit2")
	defer _ = git.libgit2_shutdown()
	assert(SDL.Init(SDL.INIT_VIDEO), "Could not initialize SDL video")
	defer SDL.Quit()

	assert(SDL.Vulkan_LoadLibrary(nil), "Could not load Vulkan")
	defer SDL.Vulkan_UnloadLibrary()

	window := SDL.CreateWindow(
		"Git-Workbench",
		1600,
		900,
		{.VULKAN, .RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	assert(window != nil, "Could not create window")
	defer SDL.DestroyWindow(window)
	_ = SDL.SetWindowMinimumSize(window, 1000, 720)
	cursors := init_system_cursors()
	defer destroy_system_cursors(&cursors)

	device, result := gpu.init(
		{
			window = window,
			validation = ODIN_DEBUG,
			synchronization_validation = ODIN_DEBUG,
			buffer_device_address = true,
			gpu_timestamps = true,
		},
	)
	assert(result == .NONE, gpu.result_string(result))
	defer {
		shutdown_result := gpu.shutdown(&device)
		assert(shutdown_result == .NONE, gpu.result_string(shutdown_result))
	}

	swapchain, swapchain_result := gpu.create_swapchain(device, window)
	assert(swapchain_result == .NONE, gpu.result_string(swapchain_result))
	defer {
		destroy_result := gpu.destroy_swapchain(&swapchain)
		assert(destroy_result == .NONE, gpu.result_string(destroy_result))
	}

	text_batch := init_text_batch(device, gpu.swapchain_format(swapchain))
	font, font_loaded := font_core.face_load_from_data(0, TEMPLATE_BODY_FONT)
	assert(font_loaded, "Could not load font")
	defer font_core.face_destroy(&font)
	title_font, title_font_loaded := font_core.face_load_from_data(1, TEMPLATE_TITLE_FONT)
	assert(title_font_loaded, "Could not load Satoshi title font")
	defer font_core.face_destroy(&title_font)
	welcome_font, welcome_font_loaded := font_core.face_load_from_data(3, GITARIS_WELCOME_FONT)
	assert(welcome_font_loaded, "Could not load Gambarino welcome font")
	defer font_core.face_destroy(&welcome_font)
	icon_font, icon_font_loaded := font_core.face_load_from_data(2, TEMPLATE_ICON_FONT)
	assert(icon_font_loaded, "Could not load icon font")
	defer font_core.face_destroy(&icon_font)
	code_font, code_font_loaded := font_core.face_load_from_data(4, GITARIS_DIFF_FONT)
	assert(code_font_loaded, "Could not load Geist Mono diff font")
	defer font_core.face_destroy(&code_font)
	defer {
		destroy_result := destroy_text_batch(device, &text_batch)
		assert(destroy_result == .NONE, gpu.result_string(destroy_result))
	}

	ui_ctx := ui.init(measure_text = ui_measure_text)
	defer ui.destroy(ui_ctx)
	state: Gitaris
	gitaris_init(&state)
	defer gitaris_destroy(&state)
	state.picker_event = SDL.RegisterEvents(1)
	text_input_active := false
	defer if text_input_active do _ = SDL.StopTextInput(window)

	previous_ticks := SDL.GetTicksNS()
	// Rectangle colors are decoded by the fragment shader; attachment clears
	// bypass it, so decode this sRGB palette color before clearing an sRGB target.
	clear_color := TEMPLATE_BACKGROUND
	for &channel in clear_color[:3] {
		channel = channel <= 0.04045 ? channel / 12.92 : math.pow((channel + 0.055) / 1.055, 2.4)
	}

	running := true
	rebuild_swapchain := false
	for running {
		defer free_all(context.temp_allocator)
		scale := max(1, SDL.GetWindowPixelDensity(window))
		ui.input_reset(ui_ctx)
		event: SDL.Event
		for SDL.PollEvent(&event) {
			if u32(event.type) == state.picker_event {
				gitaris_picker_event(&state, &event)
				continue
			}
			input_process_sdl_event(ui_ctx, &event, scale)
			#partial switch event.type {
			case .QUIT, .WINDOW_CLOSE_REQUESTED:
				running = false
			case .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_MINIMIZED, .WINDOW_RESTORED:
				rebuild_swapchain = true
			}
		}
		if !running {
			break
		}

		if rebuild_swapchain {
			result = gpu.update_swapchain(swapchain)
			if result == .SWAPCHAIN_OUT_OF_DATE {
				SDL.Delay(16)
				continue
			}
			assert(result == .NONE, gpu.result_string(result))
			// Extent changes only affect projection; rebuild the pipeline/cache if
			// the surface chooses a different attachment format after recreation.
			if text_batch.pipeline.colors[0] != gpu.swapchain_format(swapchain) {
				result = destroy_text_batch(device, &text_batch)
				assert(result == .NONE, gpu.result_string(result))
				text_batch = init_text_batch(device, gpu.swapchain_format(swapchain))
			}
			rebuild_swapchain = false
		}

		command, frame_result := gpu.start_frame(swapchain)
		if frame_result == .SWAPCHAIN_OUT_OF_DATE {
			rebuild_swapchain = true
			continue
		}
		assert(frame_result == .NONE, gpu.result_string(frame_result))

		ticks := SDL.GetTicksNS()
		elapsed_ms := f64(ticks - previous_ticks) / 1_000_000.0
		previous_ticks = ticks
		extent := gpu.swapchain_extent(swapchain)
		ui.set_delta_time(ui_ctx, f32(elapsed_ms / 1000))
		gitaris_ui(ui_ctx, &font, &title_font, &welcome_font, &icon_font, &state, window,
			f32(extent.width), f32(extent.height), scale, &code_font)
		update_system_cursor(&cursors, window, state.picker_pending ? .PROGRESS : ui.mouse_cursor(ui_ctx))
		if ui_ctx.clipboard_pending {
			_ = SDL.SetClipboardText(strings.clone_to_cstring(strings.to_string(ui_ctx.clipboard), context.temp_allocator))
			ui_ctx.clipboard_pending = false
		}
		wants_text_input := false
		for &box in ui.elements(ui_ctx) {
			if box.focused && .EDITABLE in box.actions {
				wants_text_input = true
				area := SDL.Rect{i32(box.rect.x / scale), i32(box.rect.y / scale),
					i32(box.rect.width / scale), i32(box.rect.height / scale)}
				_ = SDL.SetTextInputArea(window, &area, i32((box.caret_rect.x - box.rect.x) / scale))
				break
			}
		}
		if wants_text_input != text_input_active {
			if wants_text_input {
				text_input_active = SDL.StartTextInput(window)
			} else {
				_ = SDL.StopTextInput(window)
				text_input_active = false
			}
		}
		queued := draw_ui(&text_batch, ui_ctx)
		assert(queued, "Could not queue UI geometry")

		result = text_prepare_render(&text_batch)
		assert(result == .NONE, gpu.result_string(result))
		result = gpu.begin_gpu_timing(command, .RENDER_SETUP)
		assert(result == .NONE, gpu.result_string(result))

		result = gpu.begin_render(
			command,
			{
				area = {extent = gpu.swapchain_extent(swapchain)},
				colors = []gpu.Attachment {
					{
						texture = gpu.swapchain_target(swapchain),
						load = .CLEAR,
						store = .STORE,
						clear = {color = {float32 = clear_color}},
					},
				},
			},
		)
		assert(result == .NONE, gpu.result_string(result))
		result = gpu.end_gpu_timing(command, .RENDER_SETUP)
		assert(result == .NONE, gpu.result_string(result))
		result = gpu.begin_gpu_timing(command, .TEXT_DRAW)
		assert(result == .NONE, gpu.result_string(result))
		result = text_render(&text_batch, command, gpu.swapchain_extent(swapchain))
		assert(result == .NONE, gpu.result_string(result))
		result = gpu.end_gpu_timing(command, .TEXT_DRAW)
		assert(result == .NONE, gpu.result_string(result))
		result = gpu.begin_gpu_timing(command, .RENDER_FINISH)
		assert(result == .NONE, gpu.result_string(result))

		result = gpu.end_render(command)
		assert(result == .NONE, gpu.result_string(result))
		result = gpu.end_gpu_timing(command, .RENDER_FINISH)
		assert(result == .NONE, gpu.result_string(result))

		result = gpu.end_frame(swapchain)
		if result == .SWAPCHAIN_OUT_OF_DATE {
			rebuild_swapchain = true
		} else {
			assert(result == .NONE, gpu.result_string(result))
		}
	}
}
