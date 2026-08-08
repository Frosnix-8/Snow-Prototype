#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8) in;

layout(r8, binding = 0) uniform image2D target_atlas;
layout(r8, binding = 1) uniform image2D displayed_atlas;

layout(push_constant) uniform Params {
	float smoothing_speed;
	float dampen_factor;
} params;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(target_atlas);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	
	float target_val = imageLoad(target_atlas, pixel).r;
	float current_val = imageLoad(displayed_atlas, pixel).r;
	
	float gap = target_val - current_val;
	float dampened_gap = gap / (1.0 + abs(gap) * params.dampen_factor);
	float result = current_val + dampened_gap * params.smoothing_speed;
	
	imageStore(displayed_atlas, pixel, vec4(result));
}
