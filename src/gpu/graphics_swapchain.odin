package gpu

// Swapchain creation, resizing and per-frame image acquire/present.

import "core:c"
import SDL "vendor:sdl3"
import vk "vendor:vulkan"

@(private = "file")
destroy_images :: proc(device: ^Device, images: ^Swapchain_Images) {
	for image, i in images.images {
		vk.DestroySemaphore(device.device, images.complete[i], nil)
		vk.DestroyImageView(device.device, image.view, nil)
	}
	vk.DestroySwapchainKHR(device.device, images.handle, nil)
	images^ = {}
}
@(private = "file")
build_images :: proc(swapchain: ^Swapchain, out: ^Swapchain_Images, retired: ^bool) -> Result {
	device := swapchain.device
	width, height: c.int
	if !SDL.GetWindowSizeInPixels(swapchain.window, &width, &height) do return .NO_WINDOW
	if width <= 0 || height <= 0 || .MINIMIZED in SDL.GetWindowFlags(swapchain.window) do return .SWAPCHAIN_OUT_OF_DATE
	capabilities: vk.SurfaceCapabilitiesKHR
	result := vk_result(
		device,
		vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(
			device.physical_device,
			swapchain.surface,
			&capabilities,
		),
		.NO_SWAPCHAIN,
	)
	if result != .NONE do return result
	if .COLOR_ATTACHMENT not_in capabilities.supportedUsageFlags do return .UNSUPPORTED
	formats: [MAX_ENUMERATED]vk.SurfaceFormatKHR
	count := u32(len(formats))
	queried := vk.GetPhysicalDeviceSurfaceFormatsKHR(
		device.physical_device,
		swapchain.surface,
		&count,
		raw_data(formats[:]),
	)
	if queried != .SUCCESS && queried != .INCOMPLETE do return vk_result(device, queried, .NO_SWAPCHAIN)
	if count == 0 do return .UNSUPPORTED
	selected := formats[0]
	if selected.format == .UNDEFINED do selected.format = .B8G8R8A8_SRGB
	for format in formats[:count] {
		if (format.format == .B8G8R8A8_SRGB || format.format == .R8G8B8A8_SRGB) &&
		   format.colorSpace == .SRGB_NONLINEAR {selected = format; break}
	}
	extent := capabilities.currentExtent
	if extent.width == ~u32(0) {
		extent = {
			clamp(
				u32(width),
				capabilities.minImageExtent.width,
				capabilities.maxImageExtent.width,
			),
			clamp(
				u32(height),
				capabilities.minImageExtent.height,
				capabilities.maxImageExtent.height,
			),
		}
	}
	if extent.width == 0 || extent.height == 0 do return .SWAPCHAIN_OUT_OF_DATE
	image_count := capabilities.minImageCount + 1
	if capabilities.maxImageCount != 0 do image_count = min(image_count, capabilities.maxImageCount)
	if image_count > MAX_SWAPCHAIN_IMAGES do return .CAPACITY
	alpha := vk.CompositeAlphaFlagsKHR{.OPAQUE}
	choices := [?]vk.CompositeAlphaFlagsKHR {
		{.OPAQUE},
		{.PRE_MULTIPLIED},
		{.POST_MULTIPLIED},
		{.INHERIT},
	}
	for choice in choices {if capabilities.supportedCompositeAlpha & choice != {} {alpha = choice; break}}
	info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = swapchain.surface,
		minImageCount    = image_count,
		imageFormat      = selected.format,
		imageColorSpace  = selected.colorSpace,
		imageExtent      = extent,
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		imageSharingMode = .EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = alpha,
		presentMode      = .FIFO,
		clipped          = true,
		oldSwapchain     = swapchain.images.handle,
	}
	retired^ = info.oldSwapchain != 0
	result = vk_result(
		device,
		vk.CreateSwapchainKHR(device.device, &info, nil, &out.handle),
		.NO_SWAPCHAIN,
	)
	when GRAPHICS_TESTING {if result == .NONE && test_failure(.SWAPCHAIN) do result = .NO_MEMORY}
	images: [MAX_SWAPCHAIN_IMAGES]vk.Image
	count = 0
	if result == .NONE do result = vk_result(device, vk.GetSwapchainImagesKHR(device.device, out.handle, &count, nil), .NO_SWAPCHAIN)
	if result == .NONE && (count == 0 || count > MAX_SWAPCHAIN_IMAGES) do result = .CAPACITY
	if result == .NONE do result = vk_result(device, vk.GetSwapchainImagesKHR(device.device, out.handle, &count, raw_data(images[:])), .NO_SWAPCHAIN)
	if result == .NONE {
		out.count, out.format, out.extent = count, selected.format, extent
		for i: u32 = 0; i < count && result == .NONE; i += 1 {
			out.images[i] = {
				image      = images[i],
				format     = selected.format,
				extent     = {extent.width, extent.height, 1},
				aspects    = {.COLOR},
				mip_levels = 1,
				usage      = {.COLOR_ATTACHMENT},
				owner      = device.device,
			}
			view := vk.ImageViewCreateInfo {
				sType            = .IMAGE_VIEW_CREATE_INFO,
				image            = images[i],
				viewType         = .D2,
				format           = selected.format,
				subresourceRange = {{.COLOR}, 0, 1, 0, 1},
			}
			result = vk_result(
				device,
				vk.CreateImageView(device.device, &view, nil, &out.images[i].view),
				.NO_SWAPCHAIN,
			)
			when GRAPHICS_TESTING {if result == .NONE && test_failure(.VIEW) do result = .NO_MEMORY}
			if result == .NONE {
				semaphore := vk.SemaphoreCreateInfo {
					sType = .SEMAPHORE_CREATE_INFO,
				}
				result = vk_result(
					device,
					vk.CreateSemaphore(device.device, &semaphore, nil, &out.complete[i]),
					.NO_SWAPCHAIN,
				)
			}
		}
	}
	return result
}
@(private = "file")
cleanup_swapchain :: proc(swapchain: ^Swapchain) {
	device := swapchain.device
	destroy_images(device, &swapchain.images)
	for &frame, i in swapchain.frames {
		vk.DestroySemaphore(device.device, swapchain.acquired[i], nil)
		if frame != nil {frame.frame_owned = false; destroy_command(&frame)}
	}
	vk.DestroySurfaceKHR(device.instance, swapchain.surface, nil)
	free(swapchain, device.allocator)
}
@(private = "file")
drain_acquisitions :: proc(swapchain: ^Swapchain) -> Result {
	device := swapchain.device
	// A failed submission did not consume the WSI signal. Device idle alone
	// cannot wait for an outstanding acquisition; consume it explicitly.
	for &pending, i in swapchain.acquire_pending {
		if pending {
			wait := vk.SemaphoreSubmitInfo {
				sType     = .SEMAPHORE_SUBMIT_INFO,
				semaphore = swapchain.acquired[i],
				stageMask = {.ALL_COMMANDS},
			}
			submit := vk.SubmitInfo2 {
				sType                  = .SUBMIT_INFO_2,
				waitSemaphoreInfoCount = 1,
				pWaitSemaphoreInfos    = &wait,
			}
			result := vk_result(
				device,
				vk.QueueSubmit2(device.queue, 1, &submit, 0),
				.ERROR_QUEUE_SUBMIT,
			)
			if result != .NONE do return result
			pending = false
		}
	}
	return wait_idle(device)
}
create_swapchain :: proc(device: ^Device, window: ^SDL.Window) -> (^Swapchain, Result) {
	if device == nil do return nil, .NO_DEVICE
	if window == nil do return nil, .ERROR_INVALID_ARGUMENT
	if !device.presentation do return nil, .UNSUPPORTED
	swapchain, err := new(Swapchain, device.allocator)
	if err != nil do return nil, .NO_MEMORY
	swapchain.device, swapchain.window = device, window
	result :=
		SDL.Vulkan_CreateSurface(window, device.instance, nil, &swapchain.surface) ? Result.NONE : Result.NO_SURFACE
	if result == .NONE {
		supported: b32
		result = vk_result(
			device,
			vk.GetPhysicalDeviceSurfaceSupportKHR(
				device.physical_device,
				device.queue_family,
				swapchain.surface,
				&supported,
			),
			.NO_SURFACE,
		)
		if result == .NONE && !supported do result = .UNSUPPORTED
	}
	if result == .NONE {
		retired := false
		result = build_images(swapchain, &swapchain.images, &retired)
	}
	for i := 0; i < FRAMES && result == .NONE; i += 1 {
		swapchain.frames[i], result = create_command(device)
		if result == .NONE {
			swapchain.frames[i].frame_owned = true
			info := vk.SemaphoreCreateInfo {
				sType = .SEMAPHORE_CREATE_INFO,
			}
			result = vk_result(
				device,
				vk.CreateSemaphore(device.device, &info, nil, &swapchain.acquired[i]),
				.NO_SWAPCHAIN,
			)
		}
	}
	if result != .NONE {cleanup_swapchain(swapchain); return nil, result}
	device.live_objects += 1
	return swapchain, .NONE
}
destroy_swapchain :: proc(swapchain: ^^Swapchain) -> Result {
	if swapchain == nil do return .ERROR_INVALID_ARGUMENT
	if swapchain^ == nil do return .NONE
	if swapchain^.active && !swapchain^.device.lost do return .ERROR_STATE
	device := swapchain^.device
	result := device.lost ? Result.DEVICE_LOST : drain_acquisitions(swapchain^)
	if result == .NONE ||
	   result ==
		   .DEVICE_LOST {cleanup_swapchain(swapchain^); device.live_objects -= 1; swapchain^ = nil}
	return result
}
update_swapchain :: proc(swapchain: ^Swapchain) -> Result {
	if swapchain == nil do return .ERROR_INVALID_ARGUMENT
	if swapchain.active do return .ERROR_STATE
	device := swapchain.device
	result := drain_acquisitions(swapchain)
	if result != .NONE do return result
	replacement: Swapchain_Images
	retired := false
	result = build_images(swapchain, &replacement, &retired)
	if retired || result == .NONE {
		destroy_images(device, &swapchain.images)
		swapchain.needs_rebuild = true
		for frame, i in swapchain.frames {
			reset := wait_command(frame)
			if reset == .NONE do reset = command_reset(frame)
			vk.DestroySemaphore(device.device, swapchain.acquired[i], nil)
			swapchain.acquired[i] = 0
			info := vk.SemaphoreCreateInfo {
				sType = .SEMAPHORE_CREATE_INFO,
			}
			if reset == .NONE do reset = vk_result(device, vk.CreateSemaphore(device.device, &info, nil, &swapchain.acquired[i]), .NO_SWAPCHAIN)
			if result == .NONE do result = reset
		}
	}
	if result ==
	   .NONE {swapchain.images, swapchain.needs_rebuild, swapchain.frame = replacement, false, 0
	} else {destroy_images(device, &replacement)}
	return result
}
swapchain_format :: proc(swapchain: ^Swapchain) -> vk.Format {return(
		swapchain != nil ? swapchain.images.format : .UNDEFINED \
	)}
swapchain_extent :: proc(swapchain: ^Swapchain) -> vk.Extent2D {return(
		swapchain != nil ? swapchain.images.extent : vk.Extent2D{} \
	)}
swapchain_target :: proc(swapchain: ^Swapchain) -> ^Texture {return(
		swapchain != nil && swapchain.active ? &swapchain.images.images[swapchain.image] : nil \
	)}
start_frame :: proc(swapchain: ^Swapchain) -> (^Command, Result) {
	if swapchain == nil do return nil, .ERROR_INVALID_ARGUMENT
	if swapchain.active do return nil, .ERROR_STATE
	if swapchain.needs_rebuild || swapchain.images.handle == 0 do return nil, .SWAPCHAIN_OUT_OF_DATE
	command := swapchain.frames[swapchain.frame]
	result := wait_command(command)
	if result == .NONE do result = command_begin(command)
	if result != .NONE {swapchain.needs_rebuild = true; return nil, result}
	acquired := vk.AcquireNextImageKHR(
		swapchain.device.device,
		swapchain.images.handle,
		~u64(0),
		swapchain.acquired[swapchain.frame],
		0,
		&swapchain.image,
	)
	if acquired == .SUCCESS || acquired == .SUBOPTIMAL_KHR {
		swapchain.active, swapchain.acquire_pending[swapchain.frame], swapchain.needs_rebuild =
			true, true, acquired == .SUBOPTIMAL_KHR
		return command, .NONE
	}
	command_reset(command)
	swapchain.needs_rebuild = true
	return nil,
		acquired == .ERROR_OUT_OF_DATE_KHR ? .SWAPCHAIN_OUT_OF_DATE : vk_result(swapchain.device, acquired, .NO_SWAPCHAIN)
}
end_frame :: proc(swapchain: ^Swapchain) -> Result {
	if swapchain == nil do return .ERROR_INVALID_ARGUMENT
	if !swapchain.active do return .ERROR_STATE
	command := swapchain.frames[swapchain.frame]
	if command.phase != .RECORDING do return .ERROR_STATE
	result := transition_texture(
		command,
		&swapchain.images.images[swapchain.image],
		.PRESENT_SRC_KHR,
		{},
		{},
	)
	if result != .NONE do return result
	result = command_submit(
		command,
		swapchain.acquired[swapchain.frame],
		swapchain.images.complete[swapchain.image],
	)
	swapchain.active = false
	if result != .NONE {swapchain.needs_rebuild = true; return result}
	swapchain.acquire_pending[swapchain.frame] = false
	present := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &swapchain.images.complete[swapchain.image],
		swapchainCount     = 1,
		pSwapchains        = &swapchain.images.handle,
		pImageIndices      = &swapchain.image,
	}
	presented := vk.QueuePresentKHR(swapchain.device.queue, &present)
	swapchain.frame = (swapchain.frame + 1) % FRAMES
	if presented == .ERROR_OUT_OF_DATE_KHR ||
	   presented == .SUBOPTIMAL_KHR {swapchain.needs_rebuild = true
	} else if presented !=
	   .SUCCESS {swapchain.needs_rebuild = true; return vk_result(swapchain.device, presented, .ERROR_PRESENT)}
	return swapchain.needs_rebuild ? .SWAPCHAIN_OUT_OF_DATE : .NONE
}
cancel_frame :: proc(swapchain: ^Swapchain) -> Result {
	if swapchain == nil do return .ERROR_INVALID_ARGUMENT
	if !swapchain.active do return .ERROR_STATE
	command := swapchain.frames[swapchain.frame]
	result := command_reset(command)
	if result == .NONE do result = command_begin(command)
	if result == .NONE do result = end_frame(swapchain)
	if result != .NONE {swapchain.active, swapchain.needs_rebuild = false, true}
	return result
}
