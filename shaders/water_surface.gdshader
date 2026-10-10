shader_type spatial;
// Pairs with scripts/water_surface.gd. Waves are PLAIN SINES evaluated from a single set of
// parameters that WaterSurface pushes in and also uses for height_at() on the CPU, so the
// rendered surface and the physics surface are the same function.
//
// Why this matches between vertices: the mesh is a world-aligned lattice (vertices sit on
// multiples of cell_size), the wave is only ever evaluated AT vertices, and the rasteriser
// interpolates linearly inside each triangle. height_at() does the same barycentric blend with
// the same triangulation, so there is no floor()/stepping anywhere -- the low-poly look comes
// from coarse cells + flat normals only.
render_mode blend_mix, depth_draw_always, diffuse_lambert, specular_schlick_ggx, cull_disabled;

group_uniforms Water_Colors;
uniform vec3 deep_water_color : source_color = vec3(0.0, 0.4, 0.76);
uniform vec3 shallow_water_color : source_color = vec3(0.0, 0.6, 0.7);
uniform vec3 foam_color : source_color = vec3(0.9, 0.95, 1.0);
uniform float roughness : hint_range(0.0, 1.0) = 0.5;
uniform float water_alpha : hint_range(0.0, 1.0) = 1.0;

// Set by WaterSurface -- do not edit by hand.
// wave_a[i] = (direction.x, direction.y, wavenumber k, amplitude); wave_phase[i] = radians,
// already wrapped on the CPU in double precision (so there is no TIME in this shader at all).
group_uniforms Waves_Driven_By_Script;
uniform vec4 wave_a[4];
uniform vec4 wave_phase;

group_uniforms Depth_Settings;
uniform float foam_distance : hint_range(0.001, 1.0, 0.001) = 0.05;
uniform float foam_stepping : hint_range(2.0, 100.0) = 100.0;
uniform float depth_distance : hint_range(0.1, 10.0) = 4.0;

// The grid follows the camera, so its far edge must dissolve into the sky colour.
// Radii are measured from the camera in XZ; WaterSurface sets them from the grid size.
group_uniforms Horizon_Fade;
uniform vec3 edge_fog_color : source_color = vec3(0.65, 0.78, 0.92);
uniform float fade_start = 100.0;
uniform float fade_end = 150.0;
uniform float edge_fog_max_strength : hint_range(0.0, 1.0) = 1.0;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

varying vec3 v_world_pos;

float wave_height(vec2 p) {
	float h = 0.0;
	for (int i = 0; i < 4; i++) {
		h += wave_a[i].w * sin(wave_a[i].z * dot(wave_a[i].xy, p) + wave_phase[i]);
	}
	return h;
}

void vertex() {
	// The WaterSurface mesh node is translation-only (top_level, no rotation/scale), so
	// MODEL_MATRIX only shifts the lattice and world XZ here is exactly what the CPU uses.
	vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = wave_height(world_pos.xz);
	VERTEX.y += h;
	v_world_pos = world_pos + vec3(0.0, h, 0.0);
}

void fragment() {
	// Flat face normals (see the NaN note in the old fork: only use the derived normal when valid).
	vec3 face_cross = cross(dFdy(VERTEX), dFdx(VERTEX));
	if (dot(face_cross, face_cross) > 1e-12) {
		NORMAL = normalize(face_cross);
	}

	// Depth -> shallow/deep blend and foam. NDC depth range differs per backend.
	float depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0);
#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
#endif
	vec4 upos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	vec3 pixel_position = upos.xyz / upos.w;
	float water_depth = abs(pixel_position.z - VERTEX.z);

	float depth_blend = clamp(water_depth / depth_distance, 0.0, 1.0);
	vec3 water_base = mix(shallow_water_color, deep_water_color, depth_blend);
	vec3 background_color = textureLod(screen_texture, SCREEN_UV, 0.0).rgb;
	float dynamic_alpha = mix(water_alpha * 0.3, water_alpha, depth_blend);
	vec3 transparent_water = mix(background_color, water_base, dynamic_alpha);

	// Stepped foam at intersections (depth-based aesthetic, unrelated to wave motion)
	float stepped_depth = floor(water_depth * foam_stepping) / foam_stepping;
	float foam_mask = step(stepped_depth, foam_distance);
	vec3 result = mix(transparent_water, foam_color, foam_mask);

	// Horizon fade, radial from the camera
	float dist = length(v_world_pos.xz - CAMERA_POSITION_WORLD.xz);
	float fade = smoothstep(fade_start, fade_end, dist) * edge_fog_max_strength;
	result = mix(result, edge_fog_color, fade);

	ALBEDO = result;
	ROUGHNESS = roughness;
	SPECULAR = 0.5;
}
