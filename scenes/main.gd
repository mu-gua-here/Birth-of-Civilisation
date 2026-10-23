extends Node3D

@export var world_environment_node: WorldEnvironment

# Underwater look = a camera-attached overlay (View/Camera/UnderwaterOverlay, shaders/underwater.gdshader).
# It is NOT environment fog, so the water surface's own shallow/deep colours are left alone.
# main.gd only toggles it and tells it how bright the day is.
@export_range(0.0, 1.0) var underwater_ambient_multiplier: float = 0.0  # darkens ambient relative to the surface's current level, not an absolute value
@export var underwater_day_luminance: float = 0.75  # surface fog luminance that counts as "full daylight" for the overlay
@export_range(0.0, 1.0) var underwater_min_light: float = 0.08  # overlay never goes darker than this (night)

@onready var day_night_cycle: Node = $DayNightCycle
@onready var view: Node3D = $View

@onready var _underwater_overlay := get_node_or_null("View/Camera/UnderwaterOverlay") as MeshInstance3D

var _camera_in_fluid := false
var _camera_water_level := 0.0 # surface height above the camera, set by _query_camera_in_fluid()
var _baseline_ambient_energy: float

func _ready():
	if world_environment_node == null:
		world_environment_node = $WorldEnvironment
	_swap_environment_for_renderer()
	# Run after DayNightCycle (default process_priority 0) so whenever we
	# read the environment's "current" values this frame, they're already
	# this frame's fresh day/night numbers, not last frame's.
	process_priority = 10
	if world_environment_node and world_environment_node.environment:
		var env := world_environment_node.environment
		_baseline_ambient_energy = env.ambient_light_energy

func _process(_delta: float) -> void:
	_dbg_fps_tick(_delta)
	if world_environment_node == null or world_environment_node.environment == null:
		return
	var camera := view.get_node_or_null("Camera") if view else null
	if camera == null:
		return
	var env := world_environment_node.environment

	var camera_in_fluid := _query_camera_in_fluid(camera)

	if not camera_in_fluid:
		# Track the surface's ambient while surfaced so the underwater darkening
		# always scales from the current time of day.
		_baseline_ambient_energy = env.ambient_light_energy
		if _underwater_overlay:
			_underwater_overlay.visible = false
		_camera_in_fluid = false
		return
	
	_camera_in_fluid = true
	env.ambient_light_energy = _baseline_ambient_energy * underwater_ambient_multiplier
	if _underwater_overlay:
		_underwater_overlay.visible = true
		# Env fog is no longer overwritten while submerged, so it still holds the
		# day/night colour -- use it as the "how bright is it up there" signal.
		var light := clampf(env.fog_light_color.get_luminance() / underwater_day_luminance, underwater_min_light, 1.0)
		var mat := _underwater_overlay.material_override as ShaderMaterial
		if mat:
			mat.set_shader_parameter("light_level", light)
			# Surface right above the camera, ocean waves or river, whichever FluidArea3D reports,
			# so only the below-water part of each view ray gets tinted.
			mat.set_shader_parameter("water_level", _camera_water_level)

# --- Debug perf A/B (debug builds only). Stand where fps drops, press one key at a time:
#   F1 3D render scale 1.0/0.75/0.5   F2 shadow splits 1/2/4   F3 MSAA on/off
#   F5 print fps once a second
var _dbg_scale_i := 0
var _dbg_fps_log := false
var _dbg_fps_t := 0.0

func _dbg_fps_tick(delta: float) -> void:
	if not _dbg_fps_log:
		return
	_dbg_fps_t += delta
	if _dbg_fps_t >= 1.0:
		_dbg_fps_t = 0.0
		print("[perf] %d fps (%.1f ms)" % [Engine.get_frames_per_second(), 1000.0 / maxf(Engine.get_frames_per_second(), 1.0)])

func _unhandled_input(event: InputEvent) -> void:
	if not OS.is_debug_build() or not (event is InputEventKey and event.pressed and not event.echo):
		return
	var vp := get_viewport()
	match event.keycode:
		KEY_F1:
			_dbg_scale_i = (_dbg_scale_i + 1) % 3
			vp.scaling_3d_scale = [1.0, 0.75, 0.5][_dbg_scale_i]
			print("[perf] 3D scale = ", vp.scaling_3d_scale)
		KEY_F2:
			var sun := get_node_or_null("Sun") as DirectionalLight3D
			if sun:
				# ORTHOGONAL(1 split) -> PARALLEL_2_SPLITS -> PARALLEL_4_SPLITS
				sun.directional_shadow_mode = ((int(sun.directional_shadow_mode) + 1) % 3) as DirectionalLight3D.ShadowMode
				print("[perf] shadow mode = ", ["1 split", "2 splits", "4 splits"][int(sun.directional_shadow_mode)])
		KEY_F3:
			vp.msaa_3d = Viewport.MSAA_2X if vp.msaa_3d == Viewport.MSAA_DISABLED else Viewport.MSAA_DISABLED
			print("[perf] MSAA = ", "2x" if vp.msaa_3d == Viewport.MSAA_2X else "off")
		KEY_F5:
			_dbg_fps_log = not _dbg_fps_log

func _swap_environment_for_renderer() -> void:
	# Compatibility ("gl_compatibility") and Forward+ ("forward_plus") render
	# fog/lighting/glow differently enough that one Environment resource
	# use different environment files for each
	if world_environment_node == null or world_environment_node.environment == null:
		return
	if RenderingServer.get_current_rendering_method() != "gl_compatibility":
		return

	var native_env := world_environment_node.environment
	var native_path := native_env.resource_path
	if native_path.is_empty() or not native_path.contains("native-"):
		push_warning("main.gd: on Compatibility renderer but current environment resource path (%s) doesn't follow the 'native-*' naming convention -- can't derive compat path, leaving as-is." % native_path)
		return

	var compat_path := native_path.replace("native-", "compat-")
	if not ResourceLoader.exists(compat_path):
		push_warning("main.gd: expected compat environment at %s but it doesn't exist, leaving native environment active." % compat_path)
		return

	var compat_env := ResourceLoader.load(compat_path)
	if compat_env == null or not (compat_env is Environment):
		push_warning("main.gd: failed to load compat environment at %s, leaving native environment active." % compat_path)
		return

	world_environment_node.environment = compat_env

func _query_camera_in_fluid(camera: Camera3D) -> bool:
	var space_state := get_world_3d().direct_space_state
	var params := PhysicsPointQueryParameters3D.new()
	params.position = camera.global_position
	params.collide_with_areas = true
	params.collide_with_bodies = false
	var hits := space_state.intersect_point(params, 4)
	for hit in hits:
		var collider = hit.get("collider")
		if collider is FluidArea3D:
			# The Area3D shape is only a coarse trigger volume (much taller than the real
			# water -- see FluidArea3D's own class comment), so being inside IT isn't the
			# same as being underwater
			var surface: float = collider.get_surface_height(camera.global_position)
			if camera.global_position.y <= surface:
				_camera_water_level = surface
				return true
	return false
