package gpu

// Internal state behind the public handles: memory blocks, descriptor pools,
// commands, swapchain images and upload batches.

import "base:runtime"
import "core:dynlib"
import SDL "vendor:sdl3"
import vk "vendor:vulkan"

@(private = "package")
MAX_SWAPCHAIN_IMAGES :: 16
@(private = "package")
MAX_MEMORY_BLOCKS :: 32
@(private = "package")
MAX_ALLOCATIONS :: 512
@(private = "package")
MEMORY_BLOCK_SIZE :: 16 * 1024 * 1024
@(private = "package")
MAX_DESCRIPTOR_POOLS :: 16
@(private = "package")
DESCRIPTOR_TYPES :: 6
@(private = "package")
MAX_ENUMERATED :: 256
@(private = "package")
MAX_DISCOVERY_PROPERTIES :: 4096

@(private = "package")
Memory_Block :: struct {
	memory:                               vk.DeviceMemory,
	size:                                 vk.DeviceSize,
	mapped:                               rawptr,
	memory_type, live_allocations, first: u32,
	image, dedicated:                     bool,
}
@(private = "package")
Allocation :: struct {
	offset, size: vk.DeviceSize,
	block, next:  u32,
}
@(private = "package")
Descriptor_Pool :: struct {
	pool:      vk.DescriptorPool,
	live_sets: u32,
	available: [DESCRIPTOR_TYPES]u32,
}

Device :: struct {
	loader:                        dynlib.Library,
	instance:                      vk.Instance,
	debug_messenger:               vk.DebugUtilsMessengerEXT,
	physical_device:               vk.PhysicalDevice,
	device:                        vk.Device,
	queue:                         vk.Queue,
	queue_family:                  u32,
	timestamp_valid_bits:          u32,
	properties:                    vk.PhysicalDeviceProperties,
	memory_properties:             vk.PhysicalDeviceMemoryProperties,
	enabled:                       Device_Desc,
	presentation, lost:            bool,
	last_vk_result:                vk.Result,
	pipeline_cache:                vk.PipelineCache,
	live_objects, free_allocation: u32,
	memory_blocks:                 [MAX_MEMORY_BLOCKS]Memory_Block,
	allocations:                   [MAX_ALLOCATIONS]Allocation,
	descriptor_pools:              [MAX_DESCRIPTOR_POOLS]Descriptor_Pool,
	stats:                         Stats,
	allocator:                     runtime.Allocator,
}
Binding_Layout :: struct {
	owner:             vk.Device,
	layout:            vk.DescriptorSetLayout,
	references, count: u32,
	bindings:          [MAX_BINDINGS]Binding_Desc,
	budgets:           [DESCRIPTOR_TYPES]u32,
}
@(private = "package")
Command_Phase :: enum {
	IDLE,
	RECORDING,
	RENDERING,
	PENDING,
	FAILED,
}
@(private = "package")
Image_State :: struct {
	texture: ^Texture,
	layout:  vk.ImageLayout,
}
Command :: struct {
	device:                                                   ^Device,
	pool:                                                     vk.CommandPool,
	command:                                                  vk.CommandBuffer,
	fence:                                                    vk.Fence,
	phase:                                                    Command_Phase,
	frame_owned, state_valid, depth_enabled, stencil_enabled: bool,
	pipeline:                                                 ^Pipeline,
	sets:                                                     [MAX_SET_LAYOUTS]vk.DescriptorSet,
	colors:                                                   [MAX_COLOR_ATTACHMENTS]vk.Format,
	color_count:                                              u32,
	depth_format, stencil_format:                             vk.Format,
	index_bytes:                                              vk.DeviceSize,
	index_stride, image_count:                                u32,
	images:                                                   [MAX_UPLOADS]Image_State,
	timing_queries:                                           vk.QueryPool,
	timing_used, timing_open:                                 bit_set[GPU_Timing_Section],
}
@(private = "package")
Swapchain_Images :: struct {
	handle:   vk.SwapchainKHR,
	format:   vk.Format,
	extent:   vk.Extent2D,
	count:    u32,
	images:   [MAX_SWAPCHAIN_IMAGES]Texture,
	complete: [MAX_SWAPCHAIN_IMAGES]vk.Semaphore,
}
Swapchain :: struct {
	device:                ^Device,
	window:                ^SDL.Window,
	surface:               vk.SurfaceKHR,
	images:                Swapchain_Images,
	frames:                [FRAMES]^Command,
	acquired:              [FRAMES]vk.Semaphore,
	acquire_pending:       [FRAMES]bool,
	frame, image:          u32,
	active, needs_rebuild: bool,
}
@(private = "package")
Upload_Record :: struct {
	buffer:                 ^Buffer,
	texture:                ^Texture,
	staging_offset, offset: vk.DeviceSize,
	size:                   int,
	region:                 Texture_Upload,
	stages:                 vk.PipelineStageFlags2,
	access:                 vk.AccessFlags2,
}
Upload_Batch :: struct {
	device:          ^Device,
	staging:         Buffer,
	command:         ^Command,
	used:            vk.DeviceSize,
	count:           u32,
	recording:       bool,
	records:         [MAX_UPLOADS]Upload_Record,
	buffer_barriers: [MAX_UPLOADS]vk.BufferMemoryBarrier2,
	image_barriers:  [MAX_UPLOADS]vk.ImageMemoryBarrier2,
	profile_queries: vk.QueryPool, // Used only by GRAPHICS_BENCHMARK builds.
}

GRAPHICS_TESTING :: #config(GRAPHICS_TESTING, false)
GRAPHICS_BENCHMARK :: #config(GRAPHICS_BENCHMARK, false)
when GRAPHICS_TESTING {
	Test_Fault :: enum {
		NONE,
		INSTANCE,
		DEVICE,
		SWAPCHAIN,
		VIEW,
		BEGIN,
		SUBMIT,
	}
	@(private = "package")
	fault: Test_Fault
	test_fault :: proc(value: Test_Fault) {fault = value}
	@(private = "package")
	test_failure :: proc(value: Test_Fault) -> bool {
		hit := fault == value
		if hit do fault = .NONE
		return hit
	}
}
