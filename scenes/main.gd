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

func _query_camera_in_fluid(camera: Camera3D) -> bool:
	var space_state := get_world_3d().direct_space_state
	var params := PhysicsPointQueryParameters3D.new()
	params.position = camera.global_position
	params.collide_with_areas = true
	params.collide_with_bodies = false
	var hits := space_state.intersect_point(params, 4)
	for hit in hits:
		if hit.get("collider") is FluidArea3D:
			return true
	return false
