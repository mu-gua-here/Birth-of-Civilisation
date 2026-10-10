extends Node
class_name TerrainChunkLoader

## Radius-based existence manager for LowPolyTerrain chunks.
##
## Frustum culling is Godot's job (it already culls every MeshInstance3D and every raw
## RenderingServer instance in C++). This only decides which chunks EXIST around `target`.

@export var terrain: LowPolyTerrainManager
## Fallbacks used to find `terrain` when it isn't assigned directly (group, then node name,
## then first LowPolyTerrainManager under the scene root).
@export var terrain_group: String = ""
@export var terrain_node_name: String = ""
## Node whose position drives loading. Empty = first node in group "player".
@export var target: Node3D
## Optional node with request_nav_bake(), called after chunks change.
@export var builder: Node

## Chunks within this many meters of target are active.
@export var load_radius: float = 120.0
## Chunks beyond this many meters are deactivated. Keep it larger than load_radius.
@export var unload_radius: float = 160.0
@export var check_interval: float = 0.15
@export var deactivate_enabled: bool = true
## Max chunk LOADS per sweep (0 = unlimited). A load rebuilds mesh + collision on the main
## thread (~10 ms per chunk in GDScript), so loads are metered. Unloads are cheap (free a
## mesh and a collider) so they are NOT limited -- limiting them kept hundreds of far chunks
## alive and rendered for over a minute after startup.
@export var max_loads_per_sweep: int = 0

## Before the terrain's own _ready() runs, mark chunks farther than load_radius from the
## target as inactive, so startup only builds the chunks around the spawn point instead of
## the entire world (the sweep streams the rest in). Runtime-only: the saved terrain data is
## never modified.
@export var trim_at_startup: bool = true

## Extra bounds padding (meters) added on top of the material's `wave_height`, if it has one.
## Vertex-displacing water shaders move geometry outside the mesh's undisplaced AABB, and
## Godot culls by that AABB, so without padding a chunk pops out at the screen edge while its
## waves are still visible.
@export var water_cull_margin_buffer: float = 0.5

## Prints one line per flip plus an ASCII map around the target: '#' active with mesh,
## 'X' active but NO mesh (build/backend problem), '.' inactive, '@' target's chunk.
@export var debug_log_changes: bool = false

const FULL_SCAN_EVERY := 20  # sweeps; unload pass over the whole world for far-away leftovers

var _timer: float = 0.0
var _sweeps: int = 0


## Runs for every node in the scene BEFORE any _ready(), which is the only moment we can
## shrink the set of chunks the terrain manager builds in its own _ready().
func _enter_tree() -> void:
	if not trim_at_startup:
		return
	var t := terrain
	if t == null and terrain_group != "":
		t = get_tree().get_first_node_in_group(terrain_group) as LowPolyTerrainManager
	if t == null and terrain_node_name != "":
		t = get_tree().root.find_child(terrain_node_name, true, false) as LowPolyTerrainManager
	var tg := target
	if tg == null:
		tg = get_tree().get_first_node_in_group("player") as Node3D
	if t == null or tg == null:
		print("TerrainChunkLoader: startup trim skipped (terrain or target not resolvable yet; assign both in the inspector to enable it).")
		return
	var m: float = float(t.chunk_size) * t.cell_size
	if is_zero_approx(m):
		return
	# Not in the tree yet, so to_local()/global_position are unavailable: compose the
	# transforms by hand.
	var p: Vector3 = _chain_xform(t).affine_inverse() * _chain_xform(tg).origin
	var data: PackedByteArray = t.chunk_activity_data
	var r2 := load_radius * load_radius
	var trimmed := 0
	for cz in range(t.world_chunks.y):
		for cx in range(t.world_chunks.x):
			var i: int = cz * t.world_chunks.x + cx
			if i >= data.size() or data[i] != 1:
				continue
			var dx: float = p.x - (float(cx) + 0.5) * m
			var dz: float = p.z + (float(cz) + 0.5) * m
			if dx * dx + dz * dz > r2:
				data[i] = 0
				trimmed += 1
	t.chunk_activity_data = data
	print("TerrainChunkLoader: startup trim on \"%s\" -- %d chunks left to stream in later" % [t.name, trimmed])


static func _chain_xform(n: Node) -> Transform3D:
	var x := Transform3D.IDENTITY
	while n is Node3D:
		x = (n as Node3D).transform * x
		n = n.get_parent()
	return x


func _ready() -> void:
	if terrain == null and terrain_group != "":
		terrain = get_tree().get_first_node_in_group(terrain_group) as LowPolyTerrainManager
	if terrain == null and terrain_node_name != "":
		terrain = get_tree().current_scene.find_child(terrain_node_name, true, false) as LowPolyTerrainManager
	if terrain == null:
		terrain = _find_terrain_manager(get_tree().current_scene)
	if target == null:
		target = get_tree().get_first_node_in_group("player")
	if builder == null:
		builder = get_tree().get_first_node_in_group("builder")

	if terrain == null or target == null:
		push_warning("TerrainChunkLoader: needs a LowPolyTerrainManager and a target. Disabling.")
		set_physics_process(false)
		return
	print("TerrainChunkLoader %s: managing \"%s\" at %s (backend=%s, chunk=%.1fm, load=%.0fm, unload=%.0fm)" % [get_path(), terrain.name, terrain.get_path(),
		"SERVERS" if terrain.terrain_backend == LowPolyTerrainManager.TerrainBackend.SERVERS else "MESH_NODES",
		float(terrain.chunk_size) * terrain.cell_size, load_radius, unload_radius])
	# Chunks that were already active before this loader started.
	for cz in range(terrain.world_chunks.y):
		for cx in range(terrain.world_chunks.x):
			if terrain.is_chunk_active(cx, cz):
				_pad_bounds(Vector2i(cx, cz))


func _physics_process(delta: float) -> void:
	_timer += delta
	if _timer < check_interval:
		return
	_timer = 0.0
	_sweep()


func _sweep() -> void:
	var m: float = float(terrain.chunk_size) * terrain.cell_size
	if is_zero_approx(m):
		return
	var p: Vector3 = terrain.to_local(target.global_position)
	var center := Vector2i(floori(p.x / m), floori(-p.z / m))

	# Only look at chunks that can possibly be within unload range; occasionally do the whole
	# world so chunks left over after a teleport still get unloaded.
	_sweeps += 1
	var lo := Vector2i.ZERO
	var hi := terrain.world_chunks - Vector2i.ONE
	if _sweeps % FULL_SCAN_EVERY != 0:
		var reach := int(ceil(unload_radius / m)) + 1
		lo = Vector2i(maxi(center.x - reach, 0), maxi(center.y - reach, 0))
		hi = Vector2i(mini(center.x + reach, hi.x), mini(center.y + reach, hi.y))

	var load_sq := load_radius * load_radius
	var unload_sq := unload_radius * unload_radius
	var pending: Array = []  # [dist_sq, coord, activate]
	for cz in range(lo.y, hi.y + 1):
		for cx in range(lo.x, hi.x + 1):
			var dx: float = p.x - (float(cx) + 0.5) * m
			var dz: float = p.z + (float(cz) + 0.5) * m
			var d2 := dx * dx + dz * dz
			var active := terrain.is_chunk_active(cx, cz)
			if d2 <= load_sq:
				if not active:
					pending.append([d2, Vector2i(cx, cz), true])
			elif deactivate_enabled and active and d2 > unload_sq:
				pending.append([d2, Vector2i(cx, cz), false])
	if pending.is_empty():
		return

	pending.sort_custom(func(a, b): return a[0] < b[0])
	var loads := 0
	for entry in pending:
		if entry[2]:
			if max_loads_per_sweep > 0 and loads >= max_loads_per_sweep:
				continue
			loads += 1
		_flip(entry[1], m, entry[2])

	if builder and builder.has_method("request_nav_bake"):
		builder.request_nav_bake()
	if debug_log_changes:
		_print_map(center)


## Flips one chunk through the manager's public brush API. brush_radius is pinned to 1 vertex
## (far smaller than a chunk) so only the chunk containing `center_local` is touched.
func _flip(coord: Vector2i, m: float, activate: bool) -> void:
	var center_local := Vector3((float(coord.x) + 0.5) * m, 0.0, -(float(coord.y) + 0.5) * m)
	var saved: int = terrain.brush_radius
	terrain.brush_radius = 1
	terrain.set_chunk_status_in_radius(center_local, activate)
	terrain.brush_radius = saved
	if activate:
		_pad_bounds(coord)
	if debug_log_changes:
		print("[%s] %s %s -> active=%s mesh=%s" % [terrain.name, "LOAD" if activate else "UNLOAD",
			coord, terrain.is_chunk_active(coord.x, coord.y), terrain.get_chunk_mesh(coord) != null])


## Grows the chunk mesh's bounds by the material's wave_height (+ buffer) so culling can't drop
## a chunk whose displaced surface is still on screen. Works for both backends because it goes
## through the public get_chunk_mesh(); no shader identity check and no MeshInstance3D needed.
func _pad_bounds(coord: Vector2i) -> void:
	var pad := _wave_pad()
	if pad <= 0.0:
		return
	var mesh: ArrayMesh = terrain.get_chunk_mesh(coord)
	if mesh == null or mesh.custom_aabb.size != Vector3.ZERO:
		return  # nothing built yet, or already padded
	mesh.custom_aabb = mesh.get_aabb().grow(pad)


func _wave_pad() -> float:
	var mat := terrain.custom_material as ShaderMaterial
	if mat == null or mat.shader == null:
		return 0.0
	var h = mat.get_shader_parameter("wave_height")
	if h == null:
		h = RenderingServer.shader_get_parameter_default(mat.shader.get_rid(), &"wave_height")
	if h == null:
		return 0.0  # not a displacing water shader
	return float(h) + water_cull_margin_buffer


func _print_map(center: Vector2i) -> void:
	var lines: PackedStringArray = []
	for cz in range(center.y - 6, center.y + 7):
		var row := ""
		for cx in range(center.x - 6, center.x + 7):
			if cx < 0 or cz < 0 or cx >= terrain.world_chunks.x or cz >= terrain.world_chunks.y:
				row += " "
			elif Vector2i(cx, cz) == center:
				row += "@"
			elif not terrain.is_chunk_active(cx, cz):
				row += "."
			else:
				row += "#" if terrain.get_chunk_mesh(Vector2i(cx, cz)) != null else "X"
		lines.append(row)
	var active_count := 0
	for i in terrain.chunk_activity_data.size():
		if terrain.chunk_activity_data[i] == 1:
			active_count += 1
	print("[%s] player chunk=%s, active chunks=%d/%d" % [terrain.name, center, active_count, terrain.chunk_activity_data.size()])
	print("[%s] chunk map:\n%s" % [terrain.name, "\n".join(lines)])


func _find_terrain_manager(root: Node) -> LowPolyTerrainManager:
	if root == null:
		return null
	if root is LowPolyTerrainManager:
		return root
	for child in root.get_children():
		var found := _find_terrain_manager(child)
		if found:
			return found
	return null
