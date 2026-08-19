extends Node
class_name TerrainChunkLoader

## Distance-based load/unload for LowPolyTerrain chunks.
##
## Extends the manual ACTIVATE_CHUNK / DEACTIVATE_CHUNK editor brush (see
## LowPolyTerrainManager.set_chunk_status_in_radius) into a runtime system: chunks near
## `target` are kept active (mesh + collision built), chunks far away are deactivated
## (mesh freed, collision released). This is NOT procedural generation -- the terrain
## itself is still fully hand-authored in the editor. This only decides, at runtime,
## which of those hand-authored chunks are currently worth paying for.
##
## Two independent radii create hysteresis so a chunk sitting right on a boundary
## doesn't flicker on/off every sweep:
##   load_radius   -- inside this distance, a chunk is activated
##   unload_radius -- outside this distance, an active chunk is deactivated
## unload_radius should be noticeably larger than load_radius (defaults: 1.5x).
##
## Cheap by construction: the full grid is only re-swept when `target` crosses into a
## new chunk cell (mirrors the pattern LowPolyTerrainManager itself uses for collision
## culling), and each individual flip is a single localized chunk rebuild, not a world
## rebuild.

## The terrain to manage. Must be a LowPolyTerrainManager (or NavigationRegion3D/etc.
## parent path pointing at one) -- assign in the inspector or leave empty to auto-find
## the first LowPolyTerrainManager under the scene root.
@export var terrain: LowPolyTerrainManager

## Node whose position drives loading. Leave empty to use the first node in the
## "player" group (matches how player.gd registers itself).
@export var target: Node3D

## Chunks within this many METERS of target are activated.
@export var load_radius: float = 60.0

## Chunks farther than this many METERS from target are deactivated.
## Keep this comfortably larger than load_radius or chunks will thrash near the edge.
@export var unload_radius: float = 90.0

## Seconds between sweeps at minimum, on top of the chunk-boundary-crossing check.
## Mostly a safety net; the boundary check already skips almost all frames for free.
@export var check_interval: float = 0.25

## If true, chunks are only ever activated, never deactivated, once the loader starts
## managing them (existing manually-deactivated chunks are left alone). Useful while
## you're still hand-placing world dressing and don't want the loader fighting you.
@export var deactivate_enabled: bool = true

var _timer: float = 0.0
var _last_cell: Vector2i = Vector2i(-999999, -999999) # sentinel so the first sweep always runs


func _ready() -> void:
	if terrain == null:
		terrain = _find_terrain_manager(get_tree().current_scene)
	if target == null:
		target = get_tree().get_first_node_in_group("player")

	if terrain == null:
		push_warning("TerrainChunkLoader: no LowPolyTerrainManager assigned or found. Disabling.")
	else:
		print("TerrainChunkLoader: Using \"%s\" as LowPolyTerrainManager" % terrain.name)
	if target == null:
		push_warning("TerrainChunkLoader: no target assigned and no node in group 'player'. Disabling.")

	set_physics_process(terrain != null and target != null)


func _physics_process(delta: float) -> void:
	_timer += delta
	if _timer < check_interval:
		return
	_timer = 0.0

	var meters_per_chunk: float = float(terrain.chunk_size) * terrain.cell_size
	if is_zero_approx(meters_per_chunk):
		return

	var local_pos: Vector3 = terrain.to_local(target.global_position)
	var cell := Vector2i(
		floori(local_pos.x / meters_per_chunk),
		floori(-local_pos.z / meters_per_chunk)
	)
	if cell == _last_cell:
		return # target hasn't crossed a chunk boundary; the active set can't have changed
	_last_cell = cell

	_sweep(local_pos, meters_per_chunk)


## Walks every chunk once and flips the ones that just crossed load_radius/unload_radius.
## O(world_chunks.x * world_chunks.y), but only runs on a chunk-boundary crossing rather
## than every physics frame -- fine for a hand-authored world of realistic size. If your
## terrain grows into the hundreds of chunks per side, swap this for a windowed scan
## around `cell` instead of the full grid.
func _sweep(local_pos: Vector3, meters_per_chunk: float) -> void:
	var load_radius_sq: float = load_radius * load_radius
	var unload_radius_sq: float = unload_radius * unload_radius

	for cz in range(terrain.world_chunks.y):
		for cx in range(terrain.world_chunks.x):
			var center_x: float = (float(cx) + 0.5) * meters_per_chunk
			var center_z: float = -(float(cz) + 0.5) * meters_per_chunk
			var dx: float = local_pos.x - center_x
			var dz: float = local_pos.z - center_z
			var dist_sq: float = dx * dx + dz * dz

			var is_active: bool = terrain.is_chunk_active(cx, cz)

			if not is_active and dist_sq <= load_radius_sq:
				_set_chunk_active(cx, cz, meters_per_chunk, true)
			elif deactivate_enabled and is_active and dist_sq > unload_radius_sq:
				_set_chunk_active(cx, cz, meters_per_chunk, false)


## Flips exactly one chunk via the manager's public brush API. set_chunk_status_in_radius()
## activates/deactivates every chunk within `brush_radius * cell_size` of a LOCAL-space
## point, so brush_radius is pinned to 1 vertex (radius_meters == cell_size) for the call --
## far smaller than half a chunk width -- then restored, so this never touches neighbours
## and never permanently changes the inspector's brush settings.
func _set_chunk_active(cx: int, cz: int, meters_per_chunk: float, active: bool) -> void:
	var center_local := Vector3(
		(float(cx) + 0.5) * meters_per_chunk,
		0.0,
		-(float(cz) + 0.5) * meters_per_chunk
	)
	var saved_radius: int = terrain.brush_radius
	terrain.brush_radius = 1
	terrain.set_chunk_status_in_radius(center_local, active)
	terrain.brush_radius = saved_radius


## Depth-first search for the first LowPolyTerrainManager under `root`. Used only when
## `terrain` isn't wired up in the inspector.
func _find_terrain_manager(root: Node) -> LowPolyTerrainManager:
	if root == null:
		return null
	if root is LowPolyTerrainManager:
		return root as LowPolyTerrainManager
	for child in root.get_children():
		var found: LowPolyTerrainManager = _find_terrain_manager(child)
		if found:
			return found
	return null
