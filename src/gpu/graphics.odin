package gpu

// Public API types of the small Vulkan wrapper: devices, buffers, textures,
// pipelines, bindings and result codes.

import SDL "vendor:sdl3"
import vk "vendor:vulkan"

// Bounded, single-graphics-queue Vulkan 1.3 API. All device calls run on one
// thread. Owning objects must not be copied; destroy them after final GPU use.
// Creation is transactional. Native handles and SDL windows are borrowed.
// Initialize owning values to zero. Keep referenced objects alive from recording
// or staging until completion/cancellation. Caller-supplied Vulkan state must
// satisfy Vulkan valid usage and the enabled features. SDL initialization,
// Vulkan window creation, and window lifetime remain the caller's responsibility.
MAX_COLOR_ATTACHMENTS :: 8
MAX_BINDINGS :: 64
MAX_SET_LAYOUTS :: 8
MAX_PUSH_RANGES :: 2
MAX_DESCRIPTOR_WRITES :: 64
MAX_DESCRIPTOR_VALUES :: 128
MAX_UPLOADS :: 128
FRAMES :: 2

Result :: enum {
	NONE,
	ERROR_INVALID_ARGUMENT,
	ERROR_STATE,
	ERROR_RESOURCE,
	NO_DEVICE,
	NO_MEMORY,
	NO_DEVICE_MEM,
	NO_MAPPEABLE,
	OUT_OF_RANGE,
	CAPACITY,
	UNSUPPORTED,
	LAYER_NON_AVAILABLE,
	EXTENSION_NON_AVAILABLE,
	NO_WINDOW,
	NO_SURFACE,
	NO_SWAPCHAIN,
	SWAPCHAIN_OUT_OF_DATE,
	NO_COMMAND_BUFFER,
	ERROR_QUEUE_SUBMIT,
	ERROR_PRESENT,
	ERROR_FENCE,
	DEVICE_LOST,
	BUSY,
}

// A zero description creates a headless device without validation.
Device_Desc :: struct {
	window:                     ^SDL.Window,
	validation:                 bool,
	synchronization_validation: bool,
	debug_callback:             vk.ProcDebugUtilsMessengerCallbackEXT,
	debug_user:                 rawptr,
	buffer_device_address:      bool,
	scalar_block_layout:        bool,
	sampler_anisotropy:         bool,
	gpu_timestamps:             bool, // Optional; unsupported queues keep rendering without timings.
}

// GPU pipeline intervals, not CPU recording time. FRAME is recorded
// automatically for swapchain commands and excludes presentation/VSync.
// Other sections can be bracketed with begin_gpu_timing/end_gpu_timing once per
// command submission. Nested intervals overlap and must not be added together.
GPU_Timing_Section :: enum {
	FRAME,
	RENDER_SETUP,
	TEXT_DRAW,
	RENDER_FINISH,
	UPLOAD_TOTAL,
	UPLOAD_COPIES,
}
GPU_Timing :: struct {
	milliseconds, total_milliseconds: f64,
	samples: u64, // Zero means no completed result yet, not a zero-duration command.
}

Stats :: struct {
	memory_allocations, allocation_search_steps:                                     u64,
	descriptor_pool_creations, descriptor_layout_creations, descriptor_update_calls: u64,
	upload_submissions, uploaded_bytes, upload_barrier_calls:                        u64,
	pipeline_binds, dynamic_state_commands, validation_errors:                       u64,
	draw_calls, vertices_drawn, indices_drawn:                                       u64,
	reserved_bytes:                                                                  vk.DeviceSize,
	gpu_timings:                                                                     [GPU_Timing_Section]GPU_Timing,
}

// Host-visible allocations are coherent. Synchronize before reading or writing.
Alloc_Type :: enum {
	UPLOAD,
	DEVICE,
	READBACK,
}
Buffer_Desc :: struct {
	size:   vk.DeviceSize,
	usage:  vk.BufferUsageFlags,
	memory: Alloc_Type,
}
Buffer :: struct {
	buffer:     vk.Buffer,
	size:       vk.DeviceSize,
	usage:      vk.BufferUsageFlags,
	mapped:     rawptr,
	address:    vk.DeviceAddress,
	owner:      vk.Device,
	allocation: u32,
}
Texture_Desc :: struct {
	width, height: u32,
	format:        vk.Format,
	usage:         vk.ImageUsageFlags,
	mip_levels:    u32, // Zero selects one mip.
}
// Keep the object's address stable through submission. layout is committed only
// after successful submission; submit before recording another touching context.
Texture :: struct {
	image:      vk.Image,
	view:       vk.ImageView,
	format:     vk.Format,
	extent:     vk.Extent3D,
	aspects:    vk.ImageAspectFlags,
	mip_levels: u32,
	layout:     vk.ImageLayout,
	usage:      vk.ImageUsageFlags,
	owner:      vk.Device,
	allocation: u32, // Zero for borrowed swapchain images.
}
// Samplers are independently owned and may be shared among bindings.
Sampler :: struct {
	sampler: vk.Sampler,
	owner:   vk.Device,
}
Binding_Desc :: struct {
	binding: u32,
	type:    vk.DescriptorType,
	stages:  vk.ShaderStageFlags,
	count:   u32,
}
Binding_Set :: struct {
	set:        vk.DescriptorSet,
	owner:      vk.Device,
	layout:     ^Binding_Layout,
	pool_index: u32,
}
Binding_Value :: struct {
	buffer:       ^Buffer,
	offset, size: vk.DeviceSize,
	texture:      ^Texture,
	sampler:      ^Sampler,
	image_layout: vk.ImageLayout,
}
// Each write covers a contiguous descriptor-array range. The entire batch is
// validated before any update is applied; synchronize with prior GPU use first.
Binding_Write :: struct {
	set:                    ^Binding_Set,
	binding, first_element: u32,
	values:                 []Binding_Value,
}
Color_Target :: struct {
	format: vk.Format,
	blend:  vk.PipelineColorBlendAttachmentState,
}
// SPIR-V slices contain words, not bytes. nil optional state uses defaults;
// topology defaults to triangle list. Empty colors supports depth-only pipelines.
Pipeline_Desc :: struct {
	vertex_spirv, fragment_spirv: []u32,
	vertex_entry, fragment_entry: cstring, // nil selects "main".
	colors:                       []Color_Target,
	depth_format, stencil_format: vk.Format,
	rasterization:                ^vk.PipelineRasterizationStateCreateInfo,
	vertex_input:                 ^vk.PipelineVertexInputStateCreateInfo,
	topology:                     ^vk.PrimitiveTopology,
	layouts:                      []^Binding_Layout,
	push_ranges:                  []vk.PushConstantRange,
}
Pipeline :: struct {
	pipeline:                     vk.Pipeline,
	layout:                       vk.PipelineLayout,
	owner:                        vk.Device,
	layouts:                      [MAX_SET_LAYOUTS]^Binding_Layout,
	layout_count:                 u32,
	push_ranges:                  [MAX_PUSH_RANGES]vk.PushConstantRange,
	push_range_count:             u32,
	colors:                       [MAX_COLOR_ATTACHMENTS]vk.Format,
	color_count:                  u32,
	depth_format, stencil_format: vk.Format,
}
// Rendering uses the full image view and requires a single mip. Depth and
// stencil attachments may reference the same texture.
Attachment :: struct {
	texture: ^Texture,
	load:    vk.AttachmentLoadOp,
	store:   vk.AttachmentStoreOp,
	clear:   vk.ClearValue,
}
Render_Desc :: struct {
	area:           vk.Rect2D,
	colors:         []Attachment,
	depth, stencil: ^Attachment,
}
// Tightly packed color mip rectangle. Zero extent selects the complete mip.
// final_layout must be GENERAL or SHADER_READ_ONLY_OPTIMAL and consistent for
// all uploads of an image in a batch. Consumer masks describe its later use.
Texture_Upload :: struct {
	mip_level:       u32,
	offset:          vk.Offset2D,
	extent:          vk.Extent2D,
	final_layout:    vk.ImageLayout,
	consumer_stages: vk.PipelineStageFlags2,
	consumer_access: vk.AccessFlags2,
}
