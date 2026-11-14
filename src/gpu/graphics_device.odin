package gpu

import "base:runtime"
import "core:dynlib"
import "core:fmt"
import "core:os"
import SDL "vendor:sdl3"
import vk "vendor:vulkan"

@(private = "package")
vk_result :: proc(device: ^Device, result: vk.Result, fallback: Result) -> Result {
	if result == .SUCCESS do return .NONE
	if device != nil {
		device.last_vk_result = result
		device.lost = device.lost || result == .ERROR_DEVICE_LOST
	}
	#partial switch result {
	case .ERROR_DEVICE_LOST:
		return .DEVICE_LOST
	case .ERROR_OUT_OF_HOST_MEMORY:
		return .NO_MEMORY
	case .ERROR_OUT_OF_DEVICE_MEMORY:
		return .NO_DEVICE_MEM
	case:
		return fallback
	}
}

result_string :: proc(result: Result) -> string {
	names := [?]string {
		"success",
		"invalid argument",
		"invalid recording state",
		"resource error",
		"no suitable device",
		"host allocation failed",
		"device allocation failed",
		"buffer is not mapped",
		"out of range",
		"bounded capacity exhausted",
		"unsupported",
		"validation layer unavailable",
		"extension unavailable",
		"window unavailable",
		"surface unavailable",
		"swapchain unavailable",
		"swapchain out of date",
		"command buffer error",
		"queue submission failed",
		"presentation failed",
		"fence error",
		"device lost",
		"busy",
	}
	if int(result) < 0 || int(result) >= len(names) do return "unknown"
	return names[int(result)]
}

@(private = "file")
debug_message :: proc "system" (
	severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	types: vk.DebugUtilsMessageTypeFlagsEXT,
	data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	user: rawptr,
) -> b32 {
	context = runtime.default_context()
	device := (^Device)(user)
	if .ERROR in severity do device.stats.validation_errors += 1
	if device.enabled.debug_callback != nil {
		return device.enabled.debug_callback(severity, types, data, device.enabled.debug_user)
	}
	fmt.fprintln(os.stderr, "[Vulkan]", data.pMessage)
	return false
}

@(private = "file")
has_layer :: proc(name: cstring) -> bool {
	count: u32
	if vk.EnumerateInstanceLayerProperties(&count, nil) != .SUCCESS || count == 0 || count > MAX_DISCOVERY_PROPERTIES do return false
	layers, err := make([]vk.LayerProperties, int(count))
	if err != nil do return false
	defer delete(layers)
	result := vk.EnumerateInstanceLayerProperties(&count, raw_data(layers))
	if result == .SUCCESS || result == .INCOMPLETE {
		for &layer in layers[:count] {
			if string(cstring(raw_data(layer.layerName[:]))) == string(name) do return true
		}
	}
	return false
}
@(private = "file")
has_instance_extension :: proc(layer, name: cstring) -> bool {
	count: u32
	if vk.EnumerateInstanceExtensionProperties(layer, &count, nil) != .SUCCESS || count == 0 || count > MAX_DISCOVERY_PROPERTIES do return false
	extensions, err := make([]vk.ExtensionProperties, int(count))
	if err != nil do return false
	defer delete(extensions)
	result := vk.EnumerateInstanceExtensionProperties(layer, &count, raw_data(extensions))
	if result == .SUCCESS || result == .INCOMPLETE {
		for &extension in extensions[:count] {
			if string(cstring(raw_data(extension.extensionName[:]))) == string(name) do return true
		}
	}
	return false
}
@(private = "file")
has_device_extension :: proc(physical: vk.PhysicalDevice, name: cstring) -> bool {
	count: u32
	if vk.EnumerateDeviceExtensionProperties(physical, nil, &count, nil) != .SUCCESS || count == 0 || count > MAX_DISCOVERY_PROPERTIES do return false
	extensions, err := make([]vk.ExtensionProperties, int(count))
	if err != nil do return false
	defer delete(extensions)
	result := vk.EnumerateDeviceExtensionProperties(physical, nil, &count, raw_data(extensions))
	if result == .SUCCESS || result == .INCOMPLETE {
		for &extension in extensions[:count] {
			if string(cstring(raw_data(extension.extensionName[:]))) == string(name) do return true
		}
	}
	return false
}

@(private = "file")
create_instance :: proc(device: ^Device) -> Result {
	get_proc: vk.ProcGetInstanceProcAddr
	if device.presentation {
		get_proc = auto_cast SDL.Vulkan_GetVkGetInstanceProcAddr()
	} else {
		// A zero description must work headlessly, without SDL initialization.
		when ODIN_OS == .Windows {loader_name :: "vulkan-1.dll"
		} else when ODIN_OS == .Darwin {loader_name :: "libvulkan.1.dylib"
		} else {loader_name :: "libvulkan.so.1"}
		loader, loaded := dynlib.load_library(loader_name)
		if !loaded do return .NO_DEVICE
		device.loader = loader
		get_proc = auto_cast dynlib.symbol_address(loader, "vkGetInstanceProcAddr")
	}
	if get_proc == nil do return .EXTENSION_NON_AVAILABLE
	vk.load_proc_addresses_global(auto_cast get_proc)
	version: u32
	if vk.EnumerateInstanceVersion == nil || vk.EnumerateInstanceVersion(&version) != .SUCCESS || version < vk.API_VERSION_1_3 do return .UNSUPPORTED
	layer: cstring = "VK_LAYER_KHRONOS_validation"
	if device.enabled.validation && !has_layer(layer) do return .LAYER_NON_AVAILABLE
	extensions: [32]cstring
	count: u32
	if device.presentation {
		sdl_count: u32
		sdl_extensions := SDL.Vulkan_GetInstanceExtensions(&sdl_count)
		if sdl_extensions == nil do return .EXTENSION_NON_AVAILABLE
		if sdl_count > 30 do return .CAPACITY
		for i in 0 ..< sdl_count {extensions[count] = sdl_extensions[i]; count += 1}
	}
	if device.enabled.validation {extensions[count] = vk.EXT_DEBUG_UTILS_EXTENSION_NAME; count += 1}
	if device.enabled.synchronization_validation {extensions[count] = vk.EXT_VALIDATION_FEATURES_EXTENSION_NAME; count += 1}
	for extension in extensions[:count] {
		if !has_instance_extension(nil, extension) && !(device.enabled.validation && has_instance_extension(layer, extension)) do return .EXTENSION_NON_AVAILABLE
	}
	debug := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.INFO, .WARNING, .ERROR},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_message,
		pUserData       = device,
	}
	sync := vk.ValidationFeatureEnableEXT.SYNCHRONIZATION_VALIDATION
	validation := vk.ValidationFeaturesEXT {
		sType                         = .VALIDATION_FEATURES_EXT,
		pNext                         = &debug,
		enabledValidationFeatureCount = 1,
		pEnabledValidationFeatures    = &sync,
	}
	app := vk.ApplicationInfo {
		sType            = .APPLICATION_INFO,
		pApplicationName = "base graphics",
		apiVersion       = vk.API_VERSION_1_3,
	}
	info := vk.InstanceCreateInfo {
		sType                   = .INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app,
		enabledExtensionCount   = count,
		ppEnabledExtensionNames = raw_data(extensions[:]),
		enabledLayerCount       = device.enabled.validation ? 1 : 0,
		ppEnabledLayerNames     = device.enabled.validation ? &layer : nil,
	}
	if device.enabled.synchronization_validation {info.pNext = &validation
	} else if device.enabled.validation {info.pNext = &debug}
	result := vk_result(device, vk.CreateInstance(&info, nil, &device.instance), .NO_DEVICE)
	if result == .NONE {
		vk.load_proc_addresses_instance(device.instance)
		if device.enabled.validation {
			if vk.CreateDebugUtilsMessengerEXT == nil do return .EXTENSION_NON_AVAILABLE
			result = vk_result(
				device,
				vk.CreateDebugUtilsMessengerEXT(
					device.instance,
					&debug,
					nil,
					&device.debug_messenger,
				),
				.ERROR_RESOURCE,
			)
		}
	}
	return result
}

@(private = "file")
device_suitable :: proc(
	device: ^Device,
	physical: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
) -> (
	u32,
	bool,
) {
	properties: vk.PhysicalDeviceProperties
	vk.GetPhysicalDeviceProperties(physical, &properties)
	if properties.apiVersion < vk.API_VERSION_1_3 do return 0, false
	f13 := vk.PhysicalDeviceVulkan13Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
	}
	f12 := vk.PhysicalDeviceVulkan12Features {
		sType = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext = &f13,
	}
	f := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &f12,
	}
	vk.GetPhysicalDeviceFeatures2(physical, &f)
	if !f13.dynamicRendering ||
	   !f13.synchronization2 ||
	   (device.enabled.buffer_device_address && !f12.bufferDeviceAddress) ||
	   (device.enabled.scalar_block_layout && !f12.scalarBlockLayout) ||
	   (device.enabled.sampler_anisotropy && !f.features.samplerAnisotropy) {return 0, false}
	if device.presentation && !has_device_extension(physical, vk.KHR_SWAPCHAIN_EXTENSION_NAME) do return 0, false
	queues: [MAX_ENUMERATED]vk.QueueFamilyProperties
	count := u32(len(queues))
	vk.GetPhysicalDeviceQueueFamilyProperties(physical, &count, raw_data(queues[:]))
	for queue, i in queues[:count] {
		present: b32 = true
		if surface != 0 && vk.GetPhysicalDeviceSurfaceSupportKHR(physical, u32(i), surface, &present) != .SUCCESS do present = false
		if queue.queueCount != 0 && .GRAPHICS in queue.queueFlags && present do return u32(i), true
	}
	return 0, false
}

@(private = "file")
create_device :: proc(device: ^Device, surface: vk.SurfaceKHR) -> Result {
	physical: [MAX_ENUMERATED]vk.PhysicalDevice
	count := u32(len(physical))
	enumerated := vk.EnumeratePhysicalDevices(device.instance, &count, raw_data(physical[:]))
	if enumerated != .SUCCESS && enumerated != .INCOMPLETE do return vk_result(device, enumerated, .NO_DEVICE)
	best := -1
	for candidate in physical[:count] {
		if family, suitable := device_suitable(device, candidate, surface); suitable {
			properties: vk.PhysicalDeviceProperties
			vk.GetPhysicalDeviceProperties(candidate, &properties)
			score := properties.deviceType == .DISCRETE_GPU ? 2 : 1
			if score > best {
				best = score
				device.physical_device, device.queue_family, device.properties =
					candidate, family, properties
			}
		}
	}
	if best < 0 do return .NO_DEVICE
	queues: [MAX_ENUMERATED]vk.QueueFamilyProperties
	queue_count := u32(len(queues))
	vk.GetPhysicalDeviceQueueFamilyProperties(device.physical_device, &queue_count, raw_data(queues[:]))
	device.timestamp_valid_bits = queues[device.queue_family].timestampValidBits
	priority: f32 = 1
	queue := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = device.queue_family,
		queueCount       = 1,
		pQueuePriorities = &priority,
	}
	f13 := vk.PhysicalDeviceVulkan13Features {
		sType            = .PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
		synchronization2 = true,
		dynamicRendering = true,
	}
	f12 := vk.PhysicalDeviceVulkan12Features {
		sType               = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext               = &f13,
		bufferDeviceAddress = b32(device.enabled.buffer_device_address),
		scalarBlockLayout   = b32(device.enabled.scalar_block_layout),
		descriptorIndexing  = b32(true),
	}
	f := vk.PhysicalDeviceFeatures {
		samplerAnisotropy = b32(device.enabled.sampler_anisotropy),
	}
	extension: cstring = vk.KHR_SWAPCHAIN_EXTENSION_NAME
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &f12,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue,
		pEnabledFeatures        = &f,
		enabledExtensionCount   = device.presentation ? 1 : 0,
		ppEnabledExtensionNames = &extension,
	}
	result := vk_result(
		device,
		vk.CreateDevice(device.physical_device, &info, nil, &device.device),
		.NO_DEVICE,
	)
	if result == .NONE do vk.load_proc_addresses_device(device.device)
	when GRAPHICS_TESTING {if result == .NONE && test_failure(.DEVICE) do result = .NO_MEMORY}
	if result == .NONE {
		vk.GetDeviceQueue(device.device, device.queue_family, 0, &device.queue)
		vk.GetPhysicalDeviceMemoryProperties(device.physical_device, &device.memory_properties)
		cache := vk.PipelineCacheCreateInfo {
			sType = .PIPELINE_CACHE_CREATE_INFO,
		}
		result = vk_result(
			device,
			vk.CreatePipelineCache(device.device, &cache, nil, &device.pipeline_cache),
			.NO_MEMORY,
		)
	}
	return result
}

init :: proc(desc: Device_Desc, allocator := context.allocator) -> (^Device, Result) {
	if desc.synchronization_validation && !desc.validation do return nil, .ERROR_INVALID_ARGUMENT
	device, err := new(Device, allocator)
	if err != nil do return nil, .NO_MEMORY
	device.allocator, device.enabled, device.presentation = allocator, desc, desc.window != nil
	device.free_allocation = 1
	for &entry, i in device.allocations {entry.next = i + 1 < MAX_ALLOCATIONS ? u32(i + 2) : 0}
	result := create_instance(device)
	when GRAPHICS_TESTING {if result == .NONE && test_failure(.INSTANCE) do result = .NO_MEMORY}
	surface: vk.SurfaceKHR
	if result == .NONE && device.presentation && !SDL.Vulkan_CreateSurface(desc.window, device.instance, nil, &surface) do result = .NO_SURFACE
	if result == .NONE do result = create_device(device, surface)
	if surface != 0 do vk.DestroySurfaceKHR(device.instance, surface, nil)
	device.enabled.window = nil
	if result != .NONE {device_cleanup(device); return nil, result}
	return device, .NONE
}

wait_idle :: proc(device: ^Device) -> Result {
	if device == nil || device.device == nil do return .NO_DEVICE
	return vk_result(device, vk.DeviceWaitIdle(device.device), .ERROR_FENCE)
}
native_device :: proc(device: ^Device) -> vk.Device {return device != nil ? device.device : nil}
device_properties :: proc(device: ^Device) -> ^vk.PhysicalDeviceProperties {return(
		device != nil ? &device.properties : nil \
	)}
stats :: proc(device: ^Device) -> Stats {return device != nil ? device.stats : Stats{}}
last_vk_result :: proc(device: ^Device) -> vk.Result {return(
		device != nil ? device.last_vk_result : .SUCCESS \
	)}
