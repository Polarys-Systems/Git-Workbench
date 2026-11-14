package ui

// Like text metrics, motion is cached per element slot and guarded by its ID.
// Recycling a virtual row cannot transfer another control's hover/focus state.
UiStyleAnimation :: struct {
	id: UiId,
	from, target: [3][4]f32,
	blend: UI_Anim_Float,
}

set_animations_enabled :: proc(self: ^UiContext, enabled: bool) {
	self.animations_enabled = enabled
}

@(private)
animate_style :: proc(self: ^UiContext, box: ^UiBox) {
	if box.actions == {} {
		box._animation = {}
		return
	}
	style := &box.style
	target := [3][4]f32{style.color_top, style.color_bottom,
		box.focused ? style.focus_color : style.border_color}
	anim := &box._animation
	if anim.id != box.id || !self.animations_enabled || self.delta_time <= 0 || style.transition_duration <= 0 {
		anim.id = box.id
		anim.from, anim.target = target, target
		anim_float_set(&anim.blend, 1)
	} else if anim.target != target {
		// Retarget from the currently displayed color, including mid-transition.
		for i in 0..<len(target) {
			anim.from[i] += (anim.target[i] - anim.from[i]) * anim.blend.value
		}
		anim.target = target
		anim_float_set(&anim.blend, 0)
		anim_float_to(&anim.blend, 1, box.active ? min(0.07, style.transition_duration) : style.transition_duration)
	}
	k := anim_float_tick(&anim.blend, self.delta_time)
	colors: [3][4]f32
	for i in 0..<len(colors) do colors[i] = anim.from[i] + (anim.target[i] - anim.from[i]) * k
	style.color_top, style.color_bottom = colors[0], colors[1]
	// Both renderer branches use the sampled outline, so blur fades out too.
	style.border_color, style.focus_color = colors[2], colors[2]
}

// Apply after end(), before rendering. Geometry, hit targets and cached target
// colors stay intact. Callers can fade a view while keeping its navigation solid.
fade_elements :: proc(self: ^UiContext, first, last: int, opacity: f32) {
	assert(!self.in_frame && first >= 0 && first <= last && last <= self.n_boxes)
	alpha := clamp(opacity, 0, 1)
	for &box in self.boxes[first:last] {
		box.style.color_top.a *= alpha
		box.style.color_bottom.a *= alpha
		box.style.border_color.a *= alpha
		box.style.focus_color.a *= alpha
		box.style.text_color.a *= alpha
	}
}
