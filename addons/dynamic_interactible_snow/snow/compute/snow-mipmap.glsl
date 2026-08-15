#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, r8) uniform readonly image2D source_image;
layout(set = 0, binding = 1, r8) uniform writeonly image2D destination_image;

void main() {
	ivec2 dst = ivec2(gl_GlobalInvocationID.xy);

	ivec2 dst_size = imageSize(destination_image);

	if (dst.x >= dst_size.x || dst.y >= dst_size.y) {
		return;
	}

	ivec2 src = dst * 2;

	float a = imageLoad(source_image, src + ivec2(0, 0)).r;
	float b = imageLoad(source_image, src + ivec2(1, 0)).r;
	float c = imageLoad(source_image, src + ivec2(0, 1)).r;
	float d = imageLoad(source_image, src + ivec2(1, 1)).r;

	float average = (a + b + c + d) * 0.25;

	imageStore(
		destination_image,
		dst,
		vec4(average, 0.0, 0.0, 1.0)
	);
}
