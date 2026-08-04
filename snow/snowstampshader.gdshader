shader_type canvas_item;
render_mode blend_add;
//radius in meters. may exceed snow tile size!
uniform float stamp_radius : hint_range(0.0, 10.0, 0.1);
//depth in % of the height reduced. 0 means no more snow, 1 means max.
uniform float stamp_depth : hint_range(0.0, 1.0, 0.1);
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

//void vertex() {
	//// Called for every vertex the material is visible on.
//}

void fragment() {
	// Called for every pixel the material is visible on.
	float dist = length(UV - vec2(0.5));
	float falloff = 1.0 - smoothstep(0.0, stamp_radius, dist);
	//COLOR = vec4(falloff,falloff,falloff,1.0);
	float depth = (falloff * stamp_depth) * 2.0;
	COLOR = vec4(depth,depth,depth,1.0);
	//vec2 SCREEN_UV_CLAMP = clamp(SCREEN_UV, vec2(0.0), vec2(1.0));
	//vec4 existing = texture(SCREEN_TEXTURE, SCREEN_UV_CLAMP);
	////float result = min(existing.r, depth);
	//float result = existing.r + depth;
	//result = clamp(result, 0.0, 1.0);
	//depth is outputed as a height reduction
	//COLOR = vec4(result,result,result, 1.0);
	
}

//void light() {
//	// Called for every pixel for every light affecting the CanvasItem.
//	// Uncomment to replace the default light processing function with this one.
//}
