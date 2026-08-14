#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform image2D noise_output;

layout(push_constant, std430) uniform Params {
	int seed;
	float frequency;
	int resolution;
	float padding;
} params;

int hash(ivec2 p, int seed) {
	int n = p.x * 374761393 + p.y * 668265263 + seed * 2246822519;
	n = (n ^ (n >> 13)) * 1274126177;
	return n ^ (n >> 16);
}

float hash_float(ivec2 p, int seed) {
	return float(hash(p, seed)) / 2147483648.0; // [-1, 1]
}

float value_noise(vec2 uv, int seed) {
	ivec2 i = ivec2(floor(uv));
	vec2 f = fract(uv);

	float a = hash_float(i, seed);
	float b = hash_float(i + ivec2(1, 0), seed);
	float c = hash_float(i + ivec2(0, 1), seed);
	float d = hash_float(i + ivec2(1, 1), seed);

	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= params.resolution || pixel.y >= params.resolution) {
		return;
	}

	vec2 uv = vec2(pixel) * params.frequency;
	float n = value_noise(uv, params.seed); // [-1, 1]
	float n01 = (n + 1.0) * 0.5;

	imageStore(noise_output, pixel, vec4(n01, 0.0, 0.0, 0.0));
}
