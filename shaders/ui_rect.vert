#version 450

#extension GL_EXT_buffer_reference : require

// std430 offsets/stride match Text_Vertex in draw_text.odin: 0, 8, 16, 32 / 48.
struct TextVertex {
    vec2 position;
    vec2 uv;
    vec4 color;
    vec4 line;
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer TextVertices {
    TextVertex vertices[];
};

layout(push_constant, std430) uniform TextPush {
    TextVertices vertex_buffer;
    vec2 viewport_size;
} push;

layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 color;
layout(location = 2) flat out vec4 line;

void main() {
    TextVertex vertex = push.vertex_buffer.vertices[gl_VertexIndex];
    // The Vulkan viewport has positive height: pixel (0, 0) is top-left.
    vec2 ndc = vertex.position / push.viewport_size * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    uv = vertex.uv;
    color = vertex.color;
    line = vertex.line;
}
