#[compute]
#version 450

// GLSL compute shader
// Location: res://shaders/snow_stamp.glsl
// Purpose: apply all pending stamps for this frame to the shared snow atlas
// in a single dispatch, order-independent via max-blend per pixel.
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
	uint _padding; //useless, but apparently this compute shader likes multiples of eight. 
};

layout(binding = 1, std430) restrict readonly buffer StampBuffer {
	Stamp stamps[];
};

layout(push_constant) uniform Params {
	int stamp_count;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 atlas_size = imageSize(snow_atlas);

	// guard in case dispatch grid slightly overshoots atlas bounds
	if (pixel.x >= atlas_size.x || pixel.y >= atlas_size.y) {
		return;
	}

	vec2 uv = (vec2(pixel) + 0.5) / vec2(atlas_size);

	float result = imageLoad(snow_atlas, pixel).r;

	for (int i = 0; i < params.stamp_count; i++) {
		Stamp s = stamps[i];
		float dist = distance(uv, s.uv_center);
		if (dist < s.radius) {
			float t = 1.0 - (dist / s.radius);
			float falloff = smoothstep(0.0, 1.0, t);
			float stamp_value = s.value * falloff;
			if (s.operation == OP_MAX_COMPRESS) {
				result = max(result, stamp_value);
			}
			else if (s.operation == OP_ACCUMULATE){
				result = max(result - stamp_value, 0.0);
			}
		}
	}

	imageStore(snow_atlas, pixel, vec4(result));
}
