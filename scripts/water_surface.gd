@tool
extends Node3D
class_name WaterSurface

## The one source of truth for the ocean. Owns a single set of wave parameters, pushes them to
## the shader, and answers height_at(x, z) from the same math -- including the same
## linear-between-vertices interpolation the GPU applies to the mesh, so what you see is what
## buoyancy and the underwater check sample.
##
## The visible surface is a camera-following grid whose vertices sit on a WORLD lattice
## (multiples of cell_size), so waves never swim when the grid re-snaps. Plain sines only,
## no hash noise, no floor() stepping: the low-poly look is coarse cells + flat normals.

const WAVE_COUNT := 4 # must match wave_a[4] in the shader
const GRAVITY := 9.81
const SHADER_PATH := "res://shaders/water_surface.gdshader"
const GRID_NODE_NAME := "WaterGridMesh"

@export var sea_level := 0.0

@export_group("Grid")
## Grid covers grid_cells * cell_size metres, centred on the camera.
@export var grid_cells := 128:
	set(v):
		grid_cells = v
		_dirty = true
@export var cell_size := 2.0:
	set(v):
		cell_size = maxf(v, 0.1)
		_dirty = true
## Optional. Defaults to the active Camera3D (the editor camera when in the editor).
@export var follow_target: Node3D
## One grid covering the whole world, no camera following. Needed because Godot's debug
## freecam can't be read from script, so the normal grid would stay behind with the game
## camera. Costly on web -- debug only. Toggle at runtime with F7 (debug builds).
@export var fixed_world_grid := false:
	set(v):
		fixed_world_grid = v
		_dirty = true
@export var world_half_extent := 260.0:
	set(v):
		world_half_extent = v
		_dirty = true

@export_group("Waves")
## Arrays are indexed together and must each have exactly WAVE_COUNT (4) entries.
@export var directions_deg := PackedFloat32Array([0.0, 40.0, -35.0, 80.0]):
	set(v):
		directions_deg = v
		_dirty = true
## Metres crest to crest. Keep each >= 4 * cell_size or the grid can't represent it.
@export var wavelengths := PackedFloat32Array([32.0, 40.0, 36.0, 48.0]):
	set(v):
		wavelengths = v
		_dirty = true
## Metres (half of crest-to-trough).
@export var amplitudes := PackedFloat32Array([0.5, 0.5, 0.16, 0.08]):
	set(v):
		amplitudes = v
		_dirty = true
## Time scale on the deep-water dispersion speed (1.0 = physically plausible).
@export var speed := 0.6:
	set(v):
		speed = v
		_dirty = true
@export var animate_in_editor := false

@export_group("Look")
## Optional ShaderMaterial using water_surface.gdshader, so colours can be tuned in the
## inspector. If empty, a default one is created. Only wave_a, wave_phase, fade_start and
## fade_end are written by this script.
@export var material: ShaderMaterial:
	set(v):
		material = v
		_dirty = true

var _dirty := true
var _time := 0.0 # THE shared clock: advanced once per frame, read by both render and physics
var _mesh_instance: MeshInstance3D
var _default_material: ShaderMaterial
var _active_material: ShaderMaterial
var _half := 0
var _ks := PackedFloat32Array()
var _omegas := PackedFloat32Array()
var _dirs: Array[Vector2] = []
var _phases := PackedFloat32Array()


func _ready() -> void:
	# Run late so the camera has already moved this frame when we snap to it
	process_priority = 100


func _exit_tree() -> void:
	# Tool scripts can be re-entered in the editor; don't leave an orphaned grid behind
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.queue_free()
	_mesh_instance = null
	_dirty = true


func _unhandled_input(event: InputEvent) -> void:
	if Engine.is_editor_hint() or not OS.is_debug_build():
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		fixed_world_grid = not fixed_world_grid
		print("[water] fixed world grid = ", fixed_world_grid)


func _process(delta: float) -> void:
	if _dirty:
		_setup()
	if not Engine.is_editor_hint() or animate_in_editor:
		_time += delta
	_update_phases()
	_push_waves()
	_follow_camera()


## Surface height (world Y) at world (x, z): sea_level plus the wave, interpolated between
## lattice vertices with the SAME triangulation as the mesh (diagonal from the (i,j) corner to
## (i+1,j+1)), so it equals what the rasteriser draws -- no staircase, no per-point sine.
func height_at(x: float, z: float) -> float:
	if _ks.size() != WAVE_COUNT:
		return sea_level
	var gx := x / cell_size
	var gz := z / cell_size
	var ix := floorf(gx)
	var iz := floorf(gz)
	var fx := gx - ix
	var fz := gz - iz
	var x0 := ix * cell_size
	var z0 := iz * cell_size
	var a := _wave_at(x0, z0)
	var d := _wave_at(x0 + cell_size, z0 + cell_size)
	var h: float
	if fx >= fz:
		var b := _wave_at(x0 + cell_size, z0)
		h = a + (b - a) * fx + (d - b) * fz
	else:
		var c := _wave_at(x0, z0 + cell_size)
		h = a + (c - a) * fz + (d - c) * fx
	return sea_level + h


func max_amplitude() -> float:
	var total := 0.0
	for amp in amplitudes:
		total += absf(amp)
	return total


## Wave offset at one exact point -- the vertex function. Only meaningful at lattice vertices;
## use height_at() for everything else.
func _wave_at(x: float, z: float) -> float:
	var h := 0.0
	for i in WAVE_COUNT:
		h += amplitudes[i] * sin(_ks[i] * (_dirs[i].x * x + _dirs[i].y * z) + _phases[i])
	return h


## (Re)builds everything derived from the exported parameters. Runs on the first frame and
## whenever an export changes, in the game and in the editor.
func _setup() -> void:
	_dirty = false
	if not _validate_waves():
		return
	_precompute()

	if fixed_world_grid:
		_half = ceili(world_half_extent / cell_size)
	else:
		_half = maxi(1, (grid_cells + 1) >> 1)

	if material != null:
		_active_material = material
	else:
		if _default_material == null:
			_default_material = ShaderMaterial.new()
			_default_material.shader = load(SHADER_PATH)
		_active_material = _default_material

	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		var existing := get_node_or_null(GRID_NODE_NAME)
		if existing != null:
			existing.free()
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = GRID_NODE_NAME
		_mesh_instance.top_level = true # so it ignores this node's transform entirely
		_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_mesh_instance, false, Node.INTERNAL_MODE_FRONT) # internal: hidden from the scene tree dock, never saved
	_mesh_instance.mesh = _build_grid_mesh()
	_mesh_instance.material_override = _active_material
	_mesh_instance.extra_cull_margin = max_amplitude() + 1.0

	if fixed_world_grid:
		_active_material.set_shader_parameter("fade_start", 1.0e6)
		_active_material.set_shader_parameter("fade_end", 1.0e6 + 1.0)
	else:
		var fade_end := (_half - 2) * cell_size
		_active_material.set_shader_parameter("fade_end", maxf(fade_end, 1.0))
		_active_material.set_shader_parameter("fade_start", maxf(fade_end * 0.6, 0.5))


func _validate_waves() -> bool:
	for arr_name in ["directions_deg", "wavelengths", "amplitudes"]:
		if (get(arr_name) as PackedFloat32Array).size() != WAVE_COUNT:
			push_error("WaterSurface: %s needs exactly %d entries" % [arr_name, WAVE_COUNT])
			return false
	for wl in wavelengths:
		if wl <= 0.0:
			push_error("WaterSurface: wavelengths must be positive")
			return false
		if wl < cell_size * 4.0:
			push_warning("WaterSurface: wavelength %.1f is under 4 cells (%.1f m); the grid will alias it." % [wl, cell_size * 4.0])
	return true


func _precompute() -> void:
	_ks.resize(WAVE_COUNT)
	_omegas.resize(WAVE_COUNT)
	_phases.resize(WAVE_COUNT)
	_dirs.clear()
	for i in WAVE_COUNT:
		var k := TAU / wavelengths[i]
		_ks[i] = k
		_omegas[i] = sqrt(GRAVITY * k) * speed
		var a := deg_to_rad(directions_deg[i])
		_dirs.append(Vector2(cos(a), sin(a)))
	_update_phases()


func _update_phases() -> void:
	if _omegas.size() != WAVE_COUNT:
		return
	# Wrapped in double precision on the CPU so the shader never sees a large time value
	for i in WAVE_COUNT:
		_phases[i] = fposmod(_omegas[i] * _time, TAU)


func _push_waves() -> void:
	if _active_material == null or _ks.size() != WAVE_COUNT:
		return
	var wave_a := PackedVector4Array()
	for i in WAVE_COUNT:
		wave_a.append(Vector4(_dirs[i].x, _dirs[i].y, _ks[i], amplitudes[i]))
	_active_material.set_shader_parameter("wave_a", wave_a)
	_active_material.set_shader_parameter("wave_phase", Vector4(_phases[0], _phases[1], _phases[2], _phases[3]))


func _get_camera() -> Node3D:
	if follow_target != null:
		return follow_target
	if Engine.is_editor_hint():
		# EditorInterface isn't a compile-time symbol in export templates, so look it up by name
		var editor_interface = Engine.get_singleton("EditorInterface")
		if editor_interface == null:
			return null
		var vp = editor_interface.get_editor_viewport_3d(0)
		return vp.get_camera_3d() if vp != null else null
	return get_viewport().get_camera_3d()


func _follow_camera() -> void:
	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		return
	if fixed_world_grid:
		_mesh_instance.global_position = Vector3(0.0, sea_level, 0.0)
		return
	var anchor := _get_camera()
	if anchor == null:
		return
	var p := anchor.global_position
	# Snap to the lattice so vertices stay on world multiples of cell_size
	_mesh_instance.global_position = Vector3(snappedf(p.x, cell_size), sea_level, snappedf(p.z, cell_size))


func _build_grid_mesh() -> ArrayMesh:
	var cells := _half * 2
	var n := cells + 1
	var verts := PackedVector3Array()
	verts.resize(n * n)
	for row in n:
		for col in n:
			verts[row * n + col] = Vector3((col - _half) * cell_size, 0.0, (row - _half) * cell_size)

	# Per quad: a=(col,row) b=(col+1,row) c=(col,row+1) d=(col+1,row+1), diagonal a-d.
	# Triangles (a,b,d) and (a,d,c) -- clockwise seen from above, i.e. front-facing up.
	# height_at() relies on exactly this split.
	var indices := PackedInt32Array()
	indices.resize(cells * cells * 6)
	var w := 0
	for row in cells:
		for col in cells:
			var a := row * n + col
			var b := a + 1
			var c := a + n
			var d := c + 1
			indices[w] = a
			indices[w + 1] = b
			indices[w + 2] = d
			indices[w + 3] = a
			indices[w + 4] = d
			indices[w + 5] = c
			w += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var ext := _half * cell_size
	var m := max_amplitude() + 1.0
	mesh.custom_aabb = AABB(Vector3(-ext, -m, -ext), Vector3(ext * 2.0, m * 2.0, ext * 2.0))
	return mesh
