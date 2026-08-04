shader_type spatial;

uniform sampler2D snow_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D snow_curve_intensity;
//height of the snow when at max height.
uniform float max_height : hint_range(0.0, 2.0, 0.1) = 2.0;


void vertex() {
	vec3 local_up = normalize((inverse(MODEL_MATRIX) * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	

	float final_height = (1.0 - texture(snow_tex, clamp(UV, vec2(0.01), vec2(0.99))).r) * max_height;
	VERTEX = VERTEX + local_up * (final_height * texture(snow_curve_intensity, vec2(final_height/max_height)).rgb);
	
}
void fragment() {
	ALBEDO = vec3(1.0 - texture(snow_tex, UV).r);
}

//void light() {
//	// Called for every pixel for every light affecting the material.
//	// Uncomment to replace the default light processing function with this one.
//}
