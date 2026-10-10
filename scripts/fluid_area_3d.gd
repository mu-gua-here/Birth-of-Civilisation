extends Area3D
class_name FluidArea3D

@export var density: float = 1.0
@export var simulate_turbulence := true

# Bridges this Area3D (a coarse trigger volume only) to the actual sculpted water surface,
# which lives in a totally separate system: the LowPolyTerrain "Ocean" manager's height matrix
@export var ocean_terrain_manager: LowPolyTerrainManager
# Auto-resolved from the scene root by name if left empty, following the terrain_node_name
# convention used elsewhere in this project (see main.gd)
@export var terrain_node_name: String = "Ocean"

# Wave params -- MUST match the ShaderMaterial on the visible ocean mesh
@export_category("Wave Settings")
@export var wave_direction := Vector2(1.0, 1.0)
@export var wave_speed := 1.0
@export var wave_scale := 0.05
@export var wave_height := 0.1
@export var low_poly_stepping := 1.0

const NOISE_PERIOD := 256.0

@onready var time := 0.0
var surface_height: float = 0.0
# Ocean ShaderMaterial, cached so the wave clock can be pushed to it every physics tick
var _wave_material: ShaderMaterial = null

## Prints one line per second describing what get_height() sees under the first Carrier
## (player/citizen) inside this area. Turn off once the wave tracking is verified.
@export var debug_log := true
var _debug_timer := 0.0

func _ready() -> void:
	surface_height = position.y
	for owner_id in get_shape_owners():
		var collision = shape_owner_get_owner(owner_id)
		if collision is CollisionShape3D:
			var shape: Shape3D = collision.shape
			if shape is BoxShape3D:
				var collision_top = Vector3(0.0, shape.size.y * 0.5, 0.0)
				surface_height += (collision.transform * collision_top).y
				break

	if ocean_terrain_manager == null:
		var scene_root := get_tree().edited_scene_root if Engine.is_editor_hint() else get_tree().current_scene
		if scene_root:
			ocean_terrain_manager = scene_root.find_child(terrain_node_name, true, false) as LowPolyTerrainManager
			# Name lookup can miss (wrong/renamed node, or the match found by name isn't
			# actually a LowPolyTerrainManager) -- fall back to a DFS scan for the first
			# LowPolyTerrainManager anywhere under the scene root, same as
			# TerrainChunkLoader._find_terrain_manager() does, rather than permanently
			# settling for the flat box-derived height for the rest of the session.
			if ocean_terrain_manager == null:
				ocean_terrain_manager = _find_terrain_manager(scene_root)
		if ocean_terrain_manager == null:
			push_warning("FluidArea3D '%s': couldn't resolve a LowPolyTerrainManager named '%s' (or any other). " % [name, terrain_node_name] \
				+ "Falling back to the flat box-derived surface_height for get_height() -- buoyancy/underwater checks will be wrong.")
		else:
			print("FluidArea3D '%s': resolved ocean_terrain_manager to '%s'" % [name, ocean_terrain_manager.name])
			_sync_wave_params_from_shader()

	body_entered.connect(body_enter)
	body_exited.connect(body_exit)


func _physics_process(delta: float) -> void:
	time += delta
	# Drive the shader's wave clock from OUR clock, so get_height() and the rendered waves
	# share one time base. Shader TIME starts at engine boot and ours at this node's _ready,
	# so without this the two wave patterns sit at different phases.
	if _wave_material != null:
		_wave_material.set_shader_parameter("sync_time", time)
	if debug_log:
		_debug_timer += delta
		if _debug_timer >= 1.0:
			_debug_timer = 0.0
			for body in get_overlapping_bodies():
				if body is Carrier:
					var p: Vector3 = body.global_position
					var inside: bool = ocean_terrain_manager != null and ocean_terrain_manager.is_inside_terrain(p.x, p.z)
					print("FluidArea3D debug | manager=%s mat_synced=%s inside_terrain=%s wave=%.3f surface=%.3f body_y=%.3f time=%.1f params(h=%s scale=%s step=%s speed=%s)" % [
						ocean_terrain_manager.name if ocean_terrain_manager else "NONE",
						_wave_material != null, inside,
						_low_poly_wave(Vector2(p.x, p.z), time), get_height(p), p.y, time,
						wave_height, wave_scale, low_poly_stepping, wave_speed])
					break


func body_enter(body: Node3D) -> void:
	if body is PhysicsBody3D and body.has_method("fluid_area_enter"):
		body.fluid_area_enter(self)


func body_exit(body: Node3D) -> void:
	if body is PhysicsBody3D and body.has_method("fluid_area_exit"):
		body.fluid_area_exit(self)


## Depth-first search for a LowPolyTerrainManager under `root`, used only as a last-resort
## fallback when `terrain_node_name` doesn't resolve anything by exact name. A scene can have
## more than one manager (e.g. "Base" AND "Ocean"), so this deliberately prefers one whose
## name contains `terrain_node_name` (case-insensitive) over just grabbing the first one
## found -- otherwise this could silently latch onto the LAND terrain and compute water
## height from dry-land elevation instead. Only settles for "any manager at all" if nothing
## name-matches, same spirit as TerrainChunkLoader._find_terrain_manager().
func _find_terrain_manager(root: Node) -> LowPolyTerrainManager:
	var any_found: LowPolyTerrainManager = null
	var stack: Array[Node] = [root] if root else []
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is LowPolyTerrainManager:
			if any_found == null:
				any_found = node as LowPolyTerrainManager
			if node.name.to_lower().contains(terrain_node_name.to_lower()):
				return node as LowPolyTerrainManager
		for child in node.get_children():
			stack.push_back(child)
	return any_found


## Reads the actual live wave uniforms off the Ocean manager's ShaderMaterial (the SAME
## Material resource instance every chunk's MeshInstance3D uses via `material_override` --
## see LowPolyTerrainChunk.initialize() -- not a per-chunk copy), and overwrites this node's
## exported wave_* placeholders with them. The exported values exist for when no manager is
## resolved, but keeping them in sync by hand is exactly the kind of thing that silently
## drifts (their defaults, e.g. wave_scale 0.05 vs the shader's 0.2, already didn't match),
## and a mismatch makes get_height() track the sculpted terrain but not the animated waves
## on top of it. Safe to call again later if the material is swapped at runtime.
func _sync_wave_params_from_shader() -> void:
	if ocean_terrain_manager == null:
		return
	var mat := ocean_terrain_manager.custom_material
	if mat == null or not (mat is ShaderMaterial):
		push_warning("FluidArea3D '%s': Ocean manager's custom_material isn't a ShaderMaterial -- " % name \
			+ "keeping the exported wave_* values, which may not match what's actually rendered.")
		return
	var shader_mat := mat as ShaderMaterial
	_wave_material = shader_mat
	for param_name in ["wave_direction", "wave_speed", "wave_scale", "wave_height", "low_poly_stepping"]:
		var value = shader_mat.get_shader_parameter(param_name)
		if value == null:
			continue
		match param_name:
			"wave_direction":
				wave_direction = value
			"wave_speed":
				wave_speed = value
			"wave_scale":
				wave_scale = value
			"wave_height":
				wave_height = value
			"low_poly_stepping":
				low_poly_stepping = value
	print("FluidArea3D '%s': synced wave params from shader -- direction=%s speed=%s scale=%s height=%s stepping=%s" \
		% [name, wave_direction, wave_speed, wave_scale, wave_height, low_poly_stepping])


func get_height(pos: Vector3) -> float:
	# The real sculpted water surface, sampled from the Ocean terrain's height matrix rather
	# than assumed flat. get_height_at_world_position() clamps to the border outside the
	# terrain, so a resolved manager never falls back to the (much higher) collision box top.
	if ocean_terrain_manager != null:
		return ocean_terrain_manager.get_height_at_world_position(pos) + _mesh_wave(pos)
	return surface_height + _low_poly_wave(Vector2(pos.x, pos.z), time)


## Wave offset of the surface AS RENDERED. The water shader displaces mesh vertices only, so
## between vertices the visible surface is a linear blend of the vertex waves. Evaluating the
## exact wave at the query point instead (the old behaviour) disagrees with the mesh by up to
## tens of centimetres. Only valid while the Ocean keeps every grid vertex
## (decimate_flat_areas = false); otherwise falls back to the direct evaluation.
func _mesh_wave(pos: Vector3) -> float:
	var m := ocean_terrain_manager
	if m == null or m.decimate_flat_areas:
		return _low_poly_wave(Vector2(pos.x, pos.z), time)
	var step: float = m.cell_size
	var local := m.to_local(pos)
	var fx: float = local.x / step
	var fz: float = -local.z / step
	var gx: float = floorf(fx)
	var gz: float = floorf(fz)
	var tx: float = fx - gx
	var tz: float = fz - gz
	var w00 := _vertex_wave(m, gx, gz)
	var w10 := _vertex_wave(m, gx + 1.0, gz)
	var w01 := _vertex_wave(m, gx, gz + 1.0)
	var w11 := _vertex_wave(m, gx + 1.0, gz + 1.0)
	return lerpf(lerpf(w00, w10, tx), lerpf(w01, w11, tx), tz)


## Wave at one grid vertex of the manager, evaluated where the shader evaluates it.
func _vertex_wave(m: LowPolyTerrainManager, gx: float, gz: float) -> float:
	var wp := m.to_global(Vector3(gx * m.cell_size, 0.0, -gz * m.cell_size))
	return _low_poly_wave(Vector2(wp.x, wp.z), time)

# --- Ported from water.gdshader's low_poly_wave()/hash()/value_noise() --
# (addons/lowpolyterrain/shader/water.gdshader)

func _fract(x: float) -> float:
	return x - floor(x)

func _hash(p: Vector2) -> float:
	var wrapped := Vector2(fposmod(p.x, NOISE_PERIOD), fposmod(p.y, NOISE_PERIOD))
	return _fract(sin(wrapped.dot(Vector2(127.1, 311.7))) * 43758.5453123)

func _value_noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - f * 2.0) # smoothstep, matches shader
	return lerp(
		lerp(_hash(i), _hash(i + Vector2(1.0, 0.0)), f.x),
		lerp(_hash(i + Vector2(0.0, 1.0)), _hash(i + Vector2(1.0, 1.0)), f.x),
		f.y
	)

func _low_poly_wave(uv: Vector2, time_val: float) -> float:
	var grid_uv := (uv * low_poly_stepping).floor() / low_poly_stepping

	var move := Vector2(
		fposmod(wave_direction.x * time_val * wave_speed * 0.1, TAU),
		fposmod(wave_direction.y * time_val * wave_speed * 0.1, TAU)
	)
	var w1 := sin(grid_uv.x * 4.0 * wave_scale + move.x) * cos(grid_uv.y * 4.0 * wave_scale + move.y)

	var drift := Vector2(
		fposmod(wave_direction.x * time_val * wave_speed * 0.05, NOISE_PERIOD),
		fposmod(wave_direction.y * time_val * wave_speed * 0.05, NOISE_PERIOD)
	)
	var w2 := _value_noise(grid_uv * wave_scale * 2.0 + drift) * 2.0 - 1.0

	var detail_amount := 0.15 * wave_scale * 0.5
	return (w1 + w2 * detail_amount) * wave_height
