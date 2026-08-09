shader_type spatial;
render_mode depth_draw_opaque, cull_disabled, specular_schlick_ggx; 

uniform sampler2D snow_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D snow_curve_intensity;
//height of the snow when at max height.
uniform float max_height : hint_range(0.0, 2.0, 0.1) = 2.0;
//x,y are U and V min. z, w are U and V max.
instance uniform vec2 UV_local_coordinates = vec2(0.0,0.0);
// = 128 / 2048
uniform float tile_scale = 0.0625 ;
uniform bool update_normal_on_vertex_displace = true;

group_uniforms normal_blur;
uniform float normal_blur_radius : hint_range(1.0, 6.0, 0.1) = 2.0;


group_uniforms parallax_depracated;
uniform bool enable_POM = false;
uniform int max_layers : hint_range(0, 64, 1) = 32;
uniform int min_layers : hint_range(0, 64, 1) = 16;
uniform float depth_scale : hint_range(-16.0, 16.0, 0.001) = 0.005;

group_uniforms detail;
uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D detail_albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float detail_scale : hint_range(1.0, 32.0, 0.5) = 8.0;
uniform float detail_normal_strength : hint_range(0.0, 2.0, 0.05) = 0.5;
uniform float detail_albedo_strength : hint_range(0.0, 1.0, 0.05) = 0.3;

group_uniforms stylized_ice;
uniform vec3 ice_deep_color : source_color = vec3(0.05, 0.25, 0.65);
uniform vec3 ice_shallow_color : source_color = vec3(0.85, 0.95, 1.0);
uniform float ice_tint_power : hint_range(0.5, 4.0, 0.1) = 1.5;
uniform vec3 ice_glow_color : source_color = vec3(0.4, 0.75, 1.0);
uniform float ice_glow_strength : hint_range(0.0, 3.0, 0.05) = 1.0;

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
void update_snow_normal(vec2 uv, float texel_size, out vec3 out_normal, out vec3 out_tangent) {
	float center_height = sample_snow_height_smooth(uv, texel_size);
	float height_x = sample_snow_height_smooth(uv + vec2(texel_size, 0.0), texel_size);
	float height_y = sample_snow_height_smooth(uv + vec2(0.0, texel_size), texel_size);
	
	vec3 tangent_x = vec3(1.0, (height_x - center_height) / texel_size, 0.0);
	vec3 tangent_y = vec3(0.0, (height_y - center_height) / texel_size, 1.0);
	
	out_normal = normalize(cross(tangent_y, tangent_x));
	out_tangent = normalize(tangent_x);
}

void vertex() {
	vec2 UV_local = (UV * tile_scale) + UV_local_coordinates;
	vec3 local_up = normalize((inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	
	float final_height = sample_snow_height(UV_local);
	VERTEX = VERTEX + local_up * final_height;
	
	if (update_normal_on_vertex_displace) {
		float texel_size = tile_scale / 128.0; // one atlas texel, in local UV units
		vec3 new_normal;
		vec3 new_tangent;
		update_snow_normal(UV_local, texel_size, new_normal, new_tangent);
		
		NORMAL = normalize(new_normal * 0.75 + vec3(0.0,0.25,0.0));
		TANGENT = new_tangent;
		BINORMAL = normalize(cross(NORMAL, TANGENT));
	}
	
	
	
	
}



void fragment() {
	vec2 UV_local = (UV * tile_scale) + UV_local_coordinates;
	
	float depth_factor = pow(1.0 - texture(snow_tex, UV_local).r, ice_tint_power);
	vec3 ice_color = mix(ice_shallow_color, ice_deep_color, depth_factor);
	
	
	
	vec2 detail_uv = UV * detail_scale;
	vec3 detail_normal = texture(detail_normal_tex, detail_uv).rgb * 2.0 - 1.0;
	vec3 detail_albedo = texture(detail_albedo_tex, detail_uv).rgb;
	NORMAL_MAP = detail_normal;
	NORMAL_MAP_DEPTH = detail_normal_strength;NORMAL_MAP = detail_normal;
	
	float rim_fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(ice_color, ice_color * detail_albedo, detail_albedo_strength);
	ALBEDO = mix(ALBEDO, vec3(1.0), rim_fresnel * 0.5);
	
	float glow_fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
	EMISSION = ice_glow_color * glow_fresnel * ice_glow_strength * depth_factor;
	
	
}