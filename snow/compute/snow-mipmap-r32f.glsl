#[compute]
#version 450

// 8x8 threads per group. This matches the "size / 8" dispatch in _generate_atlas_mipmaps().
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// binding 0 = the mip level being read (mip N-1)
// binding 1 = the mip level being written (mip N)
// r32f must match the atlas format (DATA_FORMAT_R32_SFLOAT).
layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D source_mip;
layout(r32f, set = 0, binding = 1) uniform restrict writeonly image2D destination_mip;

void main() {
	ivec2 dst_pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 dst_size = imageSize(destination_mip);

	// Guard against threads outside the destination mip.
	if (dst_pixel.x >= dst_size.x || dst_pixel.y >= dst_size.y) {
		return;
	}

	// Each destination pixel covers a 2x2 block of source pixels.
	ivec2 src_pixel = dst_pixel * 2;

	float a = imageLoad(source_mip, src_pixel + ivec2(0, 0)).r;
	float b = imageLoad(source_mip, src_pixel + ivec2(1, 0)).r;
	float c = imageLoad(source_mip, src_pixel + ivec2(0, 1)).r;
	float d = imageLoad(source_mip, src_pixel + ivec2(1, 1)).r;

	float result = (a + b + c + d) * 0.25;

	imageStore(destination_mip, dst_pixel, vec4(result, 0.0, 0.0, 0.0));
}
