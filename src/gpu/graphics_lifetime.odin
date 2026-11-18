package gpu

// Device shutdown and destruction of pipelines and samplers.

import "core:dynlib"
import vk "vendor:vulkan"

@(private = "package")
device_cleanup :: proc(device: ^Device) {
	if device.device != nil {
		vk.DestroyPipelineCache(device.device, device.pipeline_cache, nil)
		for pool in device.descriptor_pools do vk.DestroyDescriptorPool(device.device, pool.pool, nil)
		for block in device.memory_blocks {
			if block.mapped != nil do vk.UnmapMemory(device.device, block.memory)
			vk.FreeMemory(device.device, block.memory, nil)
		}
		vk.DestroyDevice(device.device, nil)
	}
	if device.instance != nil {
		if device.debug_messenger != 0 && vk.DestroyDebugUtilsMessengerEXT != nil do vk.DestroyDebugUtilsMessengerEXT(device.instance, device.debug_messenger, nil)
		vk.DestroyInstance(device.instance, nil)
	}
	if device.loader != nil do dynlib.unload_library(device.loader)
	free(device, device.allocator)
}
shutdown :: proc(device: ^^Device) -> Result {
	if device == nil do return .ERROR_INVALID_ARGUMENT
	if device^ == nil do return .NONE
	if device^.live_objects != 0 do return .ERROR_RESOURCE
	result := wait_idle(device^)
	if result == .NONE || result == .DEVICE_LOST {device_cleanup(device^); device^ = nil}
	return result
}
destroy_pipeline :: proc(device: ^Device, pipeline: ^Pipeline) -> Result {
	if device == nil do return .NO_DEVICE
	if pipeline == nil || (pipeline.owner != nil && pipeline.owner != device.device) do return .ERROR_INVALID_ARGUMENT
	if pipeline.pipeline != 0 {
		vk.DestroyPipeline(device.device, pipeline.pipeline, nil)
		vk.DestroyPipelineLayout(device.device, pipeline.layout, nil)
		for layout in pipeline.layouts[:pipeline.layout_count] do layout.references -= 1
		device.live_objects -= 1
	}
	pipeline^ = {}
	return .NONE
}
create_sampler :: proc(device: ^Device, desc: ^vk.SamplerCreateInfo, out: ^Sampler) -> Result {
	if device == nil do return .NO_DEVICE
	if out == nil || out.sampler != 0 do return .ERROR_INVALID_ARGUMENT
	info := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		mipmapMode   = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
		maxLod       = vk.LOD_CLAMP_NONE,
	}
	if desc != nil do info = desc^
	if info.sType != .SAMPLER_CREATE_INFO ||
	   info.pNext != nil ||
	   info.flags != {} ||
	   (info.anisotropyEnable &&
			   (!device.enabled.sampler_anisotropy ||
					   info.maxAnisotropy < 1 ||
					   info.maxAnisotropy >
						   device.properties.limits.maxSamplerAnisotropy)) {return .ERROR_INVALID_ARGUMENT}
	sampler: Sampler
	result := vk_result(
		device,
		vk.CreateSampler(device.device, &info, nil, &sampler.sampler),
		.ERROR_RESOURCE,
	)
	if result == .NONE {sampler.owner = device.device; out^ = sampler; device.live_objects += 1}
	return result
}
destroy_sampler :: proc(device: ^Device, sampler: ^Sampler) -> Result {
	if device == nil do return .NO_DEVICE
	if sampler == nil || (sampler.owner != nil && sampler.owner != device.device) do return .ERROR_INVALID_ARGUMENT
	if sampler.sampler !=
	   0 {vk.DestroySampler(device.device, sampler.sampler, nil); device.live_objects -= 1}
	sampler^ = {}
	return .NONE
}
