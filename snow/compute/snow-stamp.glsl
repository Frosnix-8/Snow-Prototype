#[compute]
#version 450

// GLSL compute shader
// Purpose: apply ONE stamp to the shared snow atlas per dispatch.
// The CPU dispatches only enough threads to cover the stamp's bounding box,
// and pixel_offset shifts those threads to the box's position in the atlas.
// Convention: black (0.0) = full snow, white (1.0) = fully compressed.

layout(local_size_x = 8, local_size_y = 8) in;

layout(r32f, binding = 0) uniform image2D snow_atlas;

const uint OP_MAX_COMPRESS = 0;
const uint OP_ACCUMULATE = 1;

struct Stamp {
	vec2 uv_center;
	float radius;
	float value;
	uint operation;
	uint _padding; // keeps the struct at 24 bytes, matching _pack_stamps() in GDScript
};

layout(binding = 1, std430) restrict readonly buffer StampBuffer {
	Stamp stamps[];
};

layout(push_constant) uniform Params {
	ivec2 pixel_offset; // top-left pixel of the stamp's bounding box
	int stamp_index;    // which stamp in the buffer this dispatch applies
	int _pad;           // push constants must be a multiple of 16 bytes
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy) + params.pixel_offset;
	ivec2 atlas_size = imageSize(snow_atlas);

	// guard: the dispatch is rounded up to 8x8 groups, so it can overshoot the atlas edge
	if (pixel.x >= atlas_size.x || pixel.y >= atlas_size.y) {
		return;
	}

	Stamp s = stamps[params.stamp_index];
	vec2 uv = (vec2(pixel) + 0.5) / vec2(atlas_size);

	// squared distance first, so pixels outside the stamp skip the sqrt
	vec2 d = uv - s.uv_center;
	float dist_sq = dot(d, d);
	if (dist_sq >= s.radius * s.radius) {
		return;
	}

	float result = imageLoad(snow_atlas, pixel).r;

	float t = 1.0 - (sqrt(dist_sq) / s.radius);
	float falloff = smoothstep(0.0, 1.0, t);
	float stamp_value = clamp(s.value * falloff, 0.0, 1.0);

	if (s.operation == OP_MAX_COMPRESS) {
		result = max(result, stamp_value);
	}
	else if (s.operation == OP_ACCUMULATE) {
		result = max(result - stamp_value, 0.0);
	}

	imageStore(snow_atlas, pixel, vec4(result));
}
