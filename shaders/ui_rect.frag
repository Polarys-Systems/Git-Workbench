#version 450

layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 2) flat in vec4 line;

layout(set = 0, binding = 0) uniform sampler2D font_atlas;

layout(location = 0) out vec4 out_color;

vec3 srgb_to_linear(vec3 value) {
    return mix(value / 12.92, pow((value + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), value));
}

void main() {
    float coverage;
    if (uv.x < 0.0) {
        // A capsule's distance field draws both straight segments and round
        // commit nodes (equal endpoints) inside one ordinary rectangle.
        vec2 direction = line.zw - line.xy;
        vec2 point = gl_FragCoord.xy - line.xy;
        float along = clamp(dot(point, direction) / max(dot(direction, direction), 0.0001), 0.0, 1.0);
        float distance_to_line = length(point - direction * along) + uv.x;
        // Derivatives keep the transition smooth at every angle and DPI.
        float aa = max(fwidth(distance_to_line) * 0.5, 0.5);
        coverage = 1.0 - smoothstep(-aa, aa, distance_to_line);
    } else {
        coverage = texture(font_atlas, uv).r;
    }
    float alpha = color.a * coverage;
    // Premultiplied alpha: the pipeline uses ONE / ONE_MINUS_SRC_ALPHA.
    out_color = vec4(srgb_to_linear(max(color.rgb, vec3(0.0))) * alpha, alpha);
}
