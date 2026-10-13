shader_type spatial;
// Underwater look, drawn as a fullscreen quad parented to the camera (View/Camera/UnderwaterOverlay).
// main.gd only shows/hides it and pushes `light_level`.
//
// Why this instead of environment fog: fog tints EVERYTHING by one colour, including the water
// surface itself, which cancelled water_surface.gdshader's shallow/deep colours. This is an
// ordinary alpha-blended layer, so it is composited over whatever is already drawn (opaque
// scene AND the water surface) and only adds as much water as is actually in the way.
render_mode unshaded, fog_disabled, depth_test_disabled, depth_draw_never, cull_disabled, blend_mix;

group_uniforms Underwater;
uniform vec3 shallow_tint : source_color = vec3(0.10, 0.55, 0.60); // water close to the camera
uniform vec3 deep_tint : source_color = vec3(0.02, 0.15, 0.90);    // water far away
uniform float density : hint_range(0.0, 0.5, 0.001) = 0.1;        // opacity gained per metre
uniform float max_alpha : hint_range(0.0, 1.0) = 1.0;              // cap, so far things never vanish completely
uniform float color_distance = 0.0;                               // metres over which shallow -> deep
uniform float max_distance = 10.0;                                // sky / far plane is clamped to this

// Pushed by main.gd from the surface's current brightness (0 = night, 1 = full day).
uniform float light_level : hint_range(0.0, 1.0) = 0.0;
// Pushed by main.gd: world Y of the water surface above the camera (WaterSurface.height_at).
// Only the part of each view ray that is BELOW this gets tinted, so things above the water
// keep their own colour.
uniform float water_level = 0.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_nearest;

// Debug: tick this in the inspector. If you still see NOTHING, the quad isn't being drawn at
// all (culling / clipping). If you see a flat magenta wash, drawing works and the depth math
// or tuning is the problem.
uniform bool debug_flat = false;

void vertex() {
	// Fullscreen, ignoring the node transform. depth_test_disabled makes the z irrelevant, so use
	// the middle of the clip range: z = 1.0 sits exactly ON a clip plane in one renderer or the
	// other (reverse-Z Forward+ vs GL Compatibility) and can get clipped away.
	POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

void fragment() {
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 v = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 vp = v.xyz / v.w;
	float dist = length(vp);
	if (isnan(dist) || isinf(dist)) {
		dist = max_distance;
	}

	// Only the part of the ray that is under water counts. If the thing we hit is above the
	// surface, the ray leaves the water on the way there: shorten it to the surface crossing.
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp, 1.0)).xyz;
	if (wp.y > water_level && cam.y < water_level) {
		float up = max(wp.y - cam.y, 0.0001);
		dist *= clamp((water_level - cam.y) / up, 0.0, 1.0);
	}
	dist = min(dist, max_distance);

	float amount = 1.0 - exp(-density * dist);        // how much water is in the way
	float far_mix = 1.0 - exp(-dist / color_distance); // 0 near, 1 far

	ALBEDO = mix(shallow_tint, deep_tint, far_mix) * light_level;
	ALPHA = amount * max_alpha;
	if (debug_flat) {
		ALBEDO = vec3(1.0, 0.0, 1.0);
		ALPHA = 0.5;
	}
}
