#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform image2D atlas;
layout(set = 0, binding = 1, r32f) uniform readonly image2D noise_map;

layout(push_constant, std430) uniform Params {
	float amount; // tiny per-tick increase, e.g. 0.001
	float padding0;
	float padding1;
	float padding2;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);

	float current = imageLoad(atlas, pixel).r;
	//float noise_value = imageLoad(noise_map, pixel).r; // [0, 1]

	// remember: black = more snow, white = compressed (per your existing convention)
	float increase = params.amount;// * noise_value;

	float new_value = clamp(current - increase, 0.0, 1.0);

	imageStore(atlas, pixel, vec4(new_value, 0.0, 0.0, 0.0));
}
