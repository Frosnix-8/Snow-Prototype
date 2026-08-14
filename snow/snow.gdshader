shader_type spatial;
render_mode depth_draw_opaque, cull_back, diffuse_lambert_wrap, specular_schlick_ggx; 

uniform sampler2D snow_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D snow_curve_intensity;
//height of the snow when at max height.
uniform float max_height : hint_range(0.0, 2.0, 0.1) = 2.0;
//x,y are U and V min. z, w are U and V max.
instance uniform vec2 UV_local_coordinates = vec2(0.0,0.0);
instance uniform int lod_level : hint_range(0, 6, 1) = 0;
// = 128 / 2048
uniform float tile_scale = 0.0625 ;
uniform bool update_normal_on_vertex_displace = true;


group_uniforms normal_blur;
uniform float normal_blur_radius : hint_range(1.0, 6.0, 0.1) = 2.0;
uniform int blur_quality : hint_range(1, 4, 1) = 2; // taps per axis = 2*quality+1
uniform bool use_vertex_normals = false;
group_uniforms detail;
uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_scale : hint_range(0.1, 32.0, 0.1) = 8.0;
uniform float detail_normal_strength : hint_range(0.0, 2.0, 0.05) = 0.5;
uniform float detail_albedo_strength : hint_range(0.0, 1.0, 0.05) = 0.3;
group_uniforms stylized_ice;
uniform vec3 ice_deep_color : source_color = vec3(0.05, 0.25, 0.65);
uniform vec3 ice_shallow_color : source_color = vec3(0.85, 0.95, 1.0);
uniform float ice_tint_power : hint_range(0.5, 4.0, 0.1) = 1.5;
uniform vec3 ice_glow_color : source_color = vec3(0.4, 0.75, 1.0);
uniform float minimum_glow_strength : hint_range(0.0, 1.0, 0.05) = 0.2;
uniform float ice_glow_strength : hint_range(0.0, 3.0, 0.05) = 1.0;
uniform float glow_contrast : hint_range(1.0, 8.0, 0.1) = 4.0;
uniform float ice_glow_sensitivity : hint_range(0.0, 10.0, 0.1) = 2.0;
uniform float glow_min_depth : hint_range(0.0, 0.3, 0.01) = 0.05;
uniform float glow_average_mip : hint_range(0.0, 6.0, 1.0) = 4.0;

varying vec3 world_position;
varying mat3 modelview_normal_matrix;
varying float strongest_attenuation;
// Samples the heightmap at a UV and returns world-space-scale height,
// using the same black=snow/white=compressed convention as everywhere else.
float sample_snow_height(vec2 uv) {
	return (1.0 - textureLod(snow_tex, uv, 0.0).r) * max_height;
}

float blur_1d(vec2 uv, vec2 direction, float texel_size) {
	float weights[9] = float[](1.0, 8.0, 28.0, 56.0, 70.0, 56.0, 28.0, 8.0, 1.0);
	float total_weight = 256.0; // sum of the weights above (2^8 binomial row)
	
	float h = 0.0;
	for (int i = -4; i <= 4; i++) {
		vec2 offset = direction * texel_size * normal_blur_radius * float(i);
		h += sample_snow_height(uv + offset) * weights[i + 4];
	}
	return h / total_weight;
}

float sample_snow_height_smooth(vec2 uv, float texel_size) {
	float h = 0.0;
	float total_weight = 0.0;
	
	// weight table for a 5x5 gaussian-ish kernel (rows/cols -2..2)
	float weights[5] = float[](1.0, 4.0, 6.0, 4.0, 1.0);
	
	for (int y = -2; y <= 2; y++) {
		for (int x = -2; x <= 2; x++) {
			float w = weights[x + 2] * weights[y + 2];
			vec2 offset = vec2(float(x), float(y)) * texel_size * normal_blur_radius;
			h += sample_snow_height(uv + offset) * w;
			total_weight += w;
		}
	}
	
	return h / total_weight;
}
// Derives a normal (and tangent) from the heightmap's local slope at uv,
// by sampling two neighboring texels and cross-producting the resulting
// tangent directions. Call this after displacing VERTEX, so the normal
// actually matches the deformed surface instead of the flat original.
void _update_snow_normal(vec2 uv, float texel_size, out vec3 out_normal, out vec3 out_tangent) {
	float center_height = sample_snow_height_smooth(uv, texel_size);
	float height_x = sample_snow_height_smooth(uv + vec2(texel_size, 0.0), texel_size);
	float height_y = sample_snow_height_smooth(uv + vec2(0.0, texel_size), texel_size);
	
	vec3 tangent_x = vec3(1.0, (height_x - center_height) / texel_size, 0.0);
	vec3 tangent_y = vec3(0.0, (height_y - center_height) / texel_size, 1.0);
	
	out_normal = normalize(cross(tangent_y, tangent_x));
	out_tangent = normalize(tangent_x);
}
void update_snow_normal(
	vec2 uv,
	float texel_size,
	out vec3 out_normal,
	out vec3 out_tangent,
	out vec3 out_binormal
) {
	float lod_scale = float(1 << lod_level);

	float sample_step = texel_size * lod_scale;
	float blur_step = sample_step * 0.5;

	float height_x_minus = 0.0;
	float height_x_plus = 0.0;
	float height_y_minus = 0.0;
	float height_y_plus = 0.0;

	float weight_sum = 0.0;

	vec3 detail_normal_sum = vec3(0.0);

	for (int y = -blur_quality; y <= blur_quality; y++) {
		for (int x = -blur_quality; x <= blur_quality; x++) {

			vec2 offset =
				vec2(float(x), float(y)) * blur_step;

			float sigma = max(normal_blur_radius, 0.001);

			float w = exp(
				-float(x * x + y * y) /
				(2.0 * sigma * sigma)
			);

			// Your existing snow height samples...

			vec2 detail_uv = (uv / tile_scale) * detail_scale;
			vec2 detail_offset = (offset / tile_scale) * detail_scale;

			vec3 detail_normal = texture(
				detail_normal_tex,
				detail_uv + detail_offset
			).rgb * 2.0 - 1.0;

			detail_normal_sum += detail_normal * w;

			weight_sum += w;
		}
	}

	vec3 detail_normal = normalize(
		detail_normal_sum / max(weight_sum, 0.0001)
	);

	height_x_minus /= weight_sum;
	height_x_plus  /= weight_sum;
	height_y_minus /= weight_sum;
	height_y_plus  /= weight_sum;

	float gx =
		(height_x_plus - height_x_minus) /
		(2.0 * sample_step);

	float gy =
		(height_y_plus - height_y_minus) /
		(2.0 * sample_step);

	vec3 tangent_x = normalize(vec3(1.0, gx, 0.0));
	vec3 tangent_y = normalize(vec3(0.0, gy, 1.0));

	vec3 normal = normalize(
		cross(tangent_y, tangent_x)
	);

	out_normal = normal;
	out_tangent = tangent_x;
	out_binormal = tangent_y;
}
float sample_average_snow_height(vec2 uv, float mip) {
	float texel = tile_scale / 128.0;
	float h = 0.0;

	h += textureLod(snow_tex, uv + texel * vec2( 4.0,  0.0), mip).r;
	h += textureLod(snow_tex, uv + texel * vec2(-4.0,  0.0), mip).r;
	h += textureLod(snow_tex, uv + texel * vec2( 0.0,  4.0), mip).r;
	h += textureLod(snow_tex, uv + texel * vec2( 0.0, -4.0), mip).r;

	return (1.0 - h * 0.25) * max_height;
}
// Returns local snow height relative to the average snow height.
// If local snow is higher than the regional average, it is treated as 100%.
// This prevents large-scale compression from killing the glow.
float sample_relative_snow_height(vec2 uv, float mip_level) {
	float local_height = sample_snow_height(uv);
	float average_height = sample_average_snow_height(uv, mip_level);

	return clamp(
		local_height / max(average_height, 0.0001),
		0.0,
		1.0
	);
}
void vertex() {
	vec2 UV_local = (UV * tile_scale) + UV_local_coordinates;
	vec3 local_up = normalize((inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	
	float final_height = sample_snow_height(UV_local);
	VERTEX = VERTEX + local_up * final_height;
	
	if (use_vertex_normals && update_normal_on_vertex_displace) {
		float texel_size = tile_scale / 128.0; // one atlas texel, in local UV units
		vec3 new_normal;
		vec3 new_tangent;
		_update_snow_normal(UV_local, texel_size, new_normal, new_tangent);
		
		NORMAL = new_normal;
		TANGENT = new_tangent;
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	}
	modelview_normal_matrix = MODELVIEW_NORMAL_MATRIX;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}


void fragment() {
	
	vec2 UV_local = (UV * tile_scale) + UV_local_coordinates;
	float local_height = sample_snow_height(UV_local);


	vec2 detail_uv = UV * detail_scale;

	vec3 detail_normal =
	texture(detail_normal_tex, detail_uv).rgb * 2.0 - 1.0;

	vec3 detail_albedo =
	texture(detail_albedo_tex, detail_uv).rgb;

	
	
	NORMAL_MAP = detail_normal;
	NORMAL_MAP_DEPTH = detail_normal_strength;
	NORMAL_MAP = detail_normal;

	if (!use_vertex_normals && update_normal_on_vertex_displace){
		float texel_size = tile_scale / 128.0;

		vec3 snow_normal;
		vec3 snow_tangent;
		vec3 snow_binormal;

		update_snow_normal(
			UV_local,
			texel_size,
			snow_normal,
			snow_tangent,
			snow_binormal
		);

		NORMAL = normalize(
			modelview_normal_matrix * snow_normal
		);

		TANGENT = normalize(
			modelview_normal_matrix * snow_tangent
		);

		BINORMAL = normalize(
			modelview_normal_matrix * snow_binormal
		);
	}

	float depth = texture(snow_tex, UV_local).r;
	float detail_reductor_factor;
	float depth_factor = pow(1.0 - depth, ice_tint_power);
	vec3 ice_color = mix(ice_shallow_color, ice_deep_color, depth_factor);
	
	float rim_fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(ice_color, ice_color * detail_albedo, detail_albedo_strength);
	ALBEDO = mix(ALBEDO, vec3(1.0), rim_fresnel * 0.5);

	;
	float average_height = sample_average_snow_height(UV_local, glow_average_mip);

	float ratio = local_height / max(average_height, 0.0001);

	// ratio >= 1: local is at/above the surrounding average (homogeneous or a bump) -> full glow
	// ratio < 1: local is a depression relative to surroundings -> occlusion curve
	float glow_factor = pow(clamp(ratio, 0.0, 1.0), glow_contrast);

	// low-snow cutoff: kill glow when almost no snow is left, overriding the ratio rule
	float depth_cutoff = smoothstep(0.0, glow_min_depth, local_height / max_height);
	glow_factor *= depth_cutoff;

	float glow_fresnel = pow(
		1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0),
		ice_glow_sensitivity
	);

	EMISSION = ice_glow_color * glow_fresnel * ice_glow_strength * glow_factor;
	}
//void light() {
	//float attenuation = max(strongest_attenuation, ATTENUATION);
	//float NdotL = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	//vec3 base_diffuse = ALBEDO * LIGHT_COLOR * NdotL * ATTENUATION;
	//float smooth_attenuation = smoothstep(0.0, 1.0, attenuation);
	//vec2 UV_local = (UV * tile_scale) + UV_local_coordinates;
	//float depth = texture(snow_tex, UV_local).r;
	//float depth_factor = pow(1.0 - depth, ice_tint_power);
	//float shadow_dim = mix(1.0, smooth_attenuation, depth_factor * 0.5);
	//DIFFUSE_LIGHT = vec3(shadow_dim);
	////DIFFUSE_LIGHT += base_diffuse * 0.5;
//}
