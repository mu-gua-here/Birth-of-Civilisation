extends Node3D

@export var world_environment_node: WorldEnvironment

# Underwater tint -- blended on top of whatever the surface environment
# CURRENTLY looks like (captured continuously while surfaced, see
# _baseline_* below), rather than swapped in as a fixed separate resource.
# A fixed resource can't track DayNightCycle, which is exactly what caused
# underwater to read brighter than the surface at night -- this way "murky
# water" is always relative to whatever the surface is doing right now.
@export var underwater_fog_color: Color = Color(0.0716115, 0.4142087, 0.43344468, 1)
@export var underwater_fog_density: float = 0.35
@export_range(0.0, 1.0) var underwater_fog_blend: float = 0.85  # how strongly the tint overrides the surface's current fog color
@export_range(0.0, 1.0) var underwater_ambient_multiplier: float = 0.5  # darkens ambient relative to the surface's current level, not an absolute value

@onready var day_night_cycle: Node = $DayNightCycle
@onready var view: Node3D = $View

var _camera_in_fluid := false
var _baseline_fog_color: Color
var _baseline_fog_density: float
var _baseline_ambient_energy: float

func _ready():
	if world_environment_node == null:
		world_environment_node = $WorldEnvironment
	_swap_environment_for_renderer()
	_apply_web_quality()
	# Run after DayNightCycle (default process_priority 0) so whenever we
	# read the environment's "current" values this frame, they're already
	# this frame's fresh day/night numbers, not last frame's.
	process_priority = 10
	if world_environment_node and world_environment_node.environment:
		var env := world_environment_node.environment
		_baseline_fog_color = env.fog_light_color
		_baseline_fog_density = env.fog_density
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
		# Keep tracking the surface's current look every frame we're NOT
		# submerged, so the tint always blends from an up-to-date baseline
		# the next time the camera goes under.
		_baseline_fog_color = env.fog_light_color
		_baseline_fog_density = env.fog_density
		_baseline_ambient_energy = env.ambient_light_energy
		if _camera_in_fluid and day_night_cycle:
			day_night_cycle.suppress_fog = false
		_camera_in_fluid = false
		return

	if not _camera_in_fluid and day_night_cycle:
		# DayNightCycle re-fetches world_environment.environment fresh each
		# frame -- without this it'd fight us over fog_light_color/density
		# every frame we're both trying to write to the same resource.
		day_night_cycle.suppress_fog = true
	_camera_in_fluid = true

	env.fog_enabled = true
	env.fog_light_color = _baseline_fog_color.lerp(underwater_fog_color, underwater_fog_blend)
	env.fog_density = max(_baseline_fog_density, underwater_fog_density)
	env.ambient_light_energy = _baseline_ambient_energy * underwater_ambient_multiplier

# --- Debug perf A/B (debug builds only). Stand where fps drops, press one key at a time:
#   F1 3D render scale 1.0/0.75/0.5   F2 shadow splits 1/2/4   F3 MSAA on/off
#   F4 hide/show Ocean                F5 print fps once a second
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
		KEY_F4:
			var ocean := find_child("Ocean", true, false) as Node3D
			if ocean:
				ocean.visible = not ocean.visible
				print("[perf] Ocean visible = ", ocean.visible)
		KEY_F5:
			_dbg_fps_log = not _dbg_fps_log

func _apply_web_quality() -> void:
	# Shadow bias applies everywhere: the stripes on gentle terrain slopes are shadow acne (the
	# surface shadowing itself because the depth comparison is too tight), fixed by pushing the
	# receiver out along its normal. Tune these two in code or per-light in the inspector.
	var sun := get_node_or_null("Sun") as DirectionalLight3D
	if sun:
		sun.shadow_bias = 0.1
		sun.shadow_normal_bias = 3.0

	# Web/WebGL2 is far more fill-rate and draw-call bound than native. Everything below is
	# web-only; native keeps its project settings untouched.
	if not OS.has_feature("web"):
		return
	# MSAA on a HiDPI (retina) canvas is one of the biggest fill-rate costs in a browser.
	get_viewport().msaa_3d = Viewport.MSAA_DISABLED
	# Each PSSM split re-renders every shadow caster; the default is 4. Two splits over a
	# shorter distance is much cheaper for a third-person camera this close to the ground.
	if sun:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		sun.directional_shadow_max_distance = 80.0
	RenderingServer.directional_shadow_atlas_set_size(4096, true)

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
			# same as being underwater. Compare against the actual sculpted/waved surface
			# height instead, or the overlay shows far above where the water really is.
			if camera.global_position.y <= collider.get_surface_height(camera.global_position):
				return true
	return false
