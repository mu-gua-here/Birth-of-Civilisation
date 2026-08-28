extends Node
class_name TerrainChunkLoader

## Radius-based existence manager for LowPolyTerrain chunks.
##
## This does NOT decide what's visible on screen -- Godot already frustum-culls every
## MeshInstance3D and every raw RenderingServer instance (which is what the addon's
## SERVERS backend uses) automatically, in engine C++, at effectively zero cost. There is
## nothing for GDScript to add there.
##
## What this manages instead is whether a chunk's geometry and collision EXIST AT ALL --
## a hand-authored world of any real size means far more chunks than you want resident in
## memory and the physics BVH forever, so chunks far from `target` are deactivated (mesh
## freed, collision released) and chunks nearby are kept active. This is NOT procedural
## generation -- the terrain itself is still fully hand-authored in the editor; this only
## decides, at runtime, which of those hand-authored chunks are currently worth paying for.
##
## Two radii create hysteresis so a chunk sitting right at the boundary doesn't flicker
## on/off every sweep: `load_radius` brings a chunk in, `unload_radius` (larger) is what
## it must fall outside of before it's dropped again.
##
## Re-swept only when `target` crosses a chunk boundary -- there is no camera dependency
## left at all, so camera movement/rotation alone no longer triggers anything.

## The terrain to manage. Must be a LowPolyTerrainManager. Assign directly in the
## inspector when possible. If left empty, falls back to `terrain_group` (below), then
## to auto-finding the first LowPolyTerrainManager under the scene root.
@export var terrain: LowPolyTerrainManager

## Group name used to find `terrain` when it isn't assigned directly. Set this instead
## of a NodePath when the terrain lives inside an instanced sub-scene (e.g. terrain.res)
## whose internal nodes aren't reachable from the parent scene without enabling
## "Editable Children" -- add the LowPolyTerrainManager node (e.g. "Base" or "Ocean")
## to a group of this name from *within* terrain.res itself (open it as its own scene),
## and it'll resolve here automatically, surviving renames/moves and working for any
## future terrain managers tagged the same way.
##
## In practice the editor's Groups-tab assignment has repeatedly failed to persist across
## saves of terrain.res, so `terrain_node_name` below is the more reliable option -- kept
## for cases where a name genuinely can't be relied on (e.g. two same-named managers).
@export var terrain_group: String = ""

## Node NAME (not path) used to find `terrain` when it isn't assigned directly and
## `terrain_group` didn't resolve anything. Found via a recursive find_child() from the
## scene root, so it works regardless of how deeply nested the node is inside an
## instanced sub-scene (e.g. "Base" or "Ocean" inside terrain.res) -- no Editable
## Children, no group bookkeeping to lose across saves. This is the recommended way to
## wire this up; terrain_group above is legacy/secondary.
@export var terrain_node_name: String = ""

## Node whose position drives chunk loading. Leave empty to use the first node in the
## "player" group (matches how player.gd registers itself).
@export var target: Node3D

## Builder node whose request_nav_bake() gets called whenever chunks actually finish
## activating/deactivating. Leave empty to auto-find via the "builder" group. Chunk
## streaming changes what terrain collision exists, which is exactly the geometry
## NavigationRegion3D bakes from (see Builder._bake_nav()) -- without this, a single
## bake done at game start goes stale the moment the player walks somewhere new, and
## citizens either can't path onto newly-loaded ground or keep trying to path across
## ground that already unloaded.
@export var builder: Node

## Chunks within this many METERS of target are kept active.
@export var load_radius: float = 120.0

## Chunks must fall outside this many METERS of target before being deactivated. Keep
## this comfortably larger than load_radius, or chunks will thrash at the boundary.
@export var unload_radius: float = 160.0

## Seconds between sweeps at minimum, on top of the chunk-boundary check.
@export var check_interval: float = 0.15

## Max number of chunk activate/deactivate calls actually applied per physics tick.
## A sweep can decide many chunks need to flip at once (e.g. teleporting/fast travel);
## each flip calls into the terrain addon to build/free real mesh + collision, which is
## the expensive part. Rather than applying every flip in the same frame, they're queued
## and drained at this rate, closest chunks first, so a big jump costs a few frames of
## gradual pop-in instead of one big frame hitch.
@export var max_chunk_ops_per_tick: int = 6

## If true, chunks outside unload_radius are deactivated once the loader starts managing
## them (existing manually-deactivated chunks are left alone). Useful while you're still
## hand-placing world dressing and don't want the loader fighting you.
@export var deactivate_enabled: bool = true

var _timer: float = 0.0
var _last_cell: Vector2i = Vector2i(-999999, -999999) # sentinel so the first sweep always runs

# Desired-state queue drained a few chunks at a time (see max_chunk_ops_per_tick). Keyed
# by chunk coord so a chunk re-evaluated before its previous op is applied just has its
# desired state overwritten rather than queuing duplicate work.
var _pending_ops: Dictionary = {} # Vector2i(cx, cz) -> bool desired_active
var _last_meters_per_chunk: float = 0.0

## Fixes water-mesh edge clipping -- water.gdshader's vertex() raises the surface by up
## to wave_height, but Godot's own per-instance GPU frustum culling tests the UNDISPLACED
## mesh bounding box -- so a chunk's water surface can pop out the instant that static
## box edge leaves the frustum, even though the raised waves would still be visible on
## screen. The shader's own header comment documents the fix: set
## GeometryInstance3D.extra_cull_margin on the instance. This loader is the natural place
## to apply it since it's already the thing deciding when chunk meshes come into
## existence -- newly-activated chunks are scanned for water-shader MeshInstance3Ds and
## patched once each. Unrelated to chunk existence itself; kept because nothing else in
## the project currently does this.
const WATER_SHADER: Shader = preload("res://addons/lowpolyterrain/shader/water.gdshader")
## Extra slack in METERS added on top of the shader's own wave_height, to cover the
## detail-noise term (see water.gdshader's low_poly_wave()) which can push slightly
## higher than wave_height alone would suggest.
@export var water_cull_margin_buffer: float = 0.5
var _water_cull_fixed: Dictionary = {} # MeshInstance3D instance_id (int) -> true, so each is only patched once ever


func _ready() -> void:
	if terrain == null and terrain_group != "":
		var found := get_tree().get_first_node_in_group(terrain_group)
		if found is LowPolyTerrainManager:
			terrain = found
		elif found != null:
			push_warning("TerrainChunkLoader: node in group '%s' is not a LowPolyTerrainManager (got %s), ignoring" % [terrain_group, found.get_class()])
	if terrain == null and terrain_node_name != "":
		var by_name := get_tree().current_scene.find_child(terrain_node_name, true, false)
		if by_name is LowPolyTerrainManager:
			terrain = by_name
		elif by_name != null:
			push_warning("TerrainChunkLoader: node named '%s' is not a LowPolyTerrainManager (got %s), ignoring" % [terrain_node_name, by_name.get_class()])
	if terrain == null:
		terrain = _find_terrain_manager(get_tree().current_scene)
	if target == null:
		target = get_tree().get_first_node_in_group("player")
	if builder == null:
		builder = get_tree().get_first_node_in_group("builder")

	if terrain == null:
		push_warning("TerrainChunkLoader: no LowPolyTerrainManager assigned or found. Disabling.")
	else:
		print("TerrainChunkLoader: Using \"%s\" as LowPolyTerrainManager" % terrain.name)
	if target == null:
		push_warning("TerrainChunkLoader: no target assigned and no node in group 'player'. Disabling.")

	set_physics_process(terrain != null and target != null)
	# Catch any chunks already active before this loader started managing them (e.g.
	# manually activated in the editor).
	if terrain != null:
		_fix_water_cull_margins()


func _physics_process(delta: float) -> void:
	# Drain a few queued chunk flips every physics tick, independent of the sweep
	# throttle below -- this is what actually spreads a big jump's worth of newly-
	# in-range chunks out over several frames instead of applying them all at once.
	_drain_pending_ops()

	_timer += delta
	if _timer < check_interval:
		return
	_timer = 0.0

	var meters_per_chunk: float = float(terrain.chunk_size) * terrain.cell_size
	if is_zero_approx(meters_per_chunk):
		return
	_last_meters_per_chunk = meters_per_chunk

	var local_pos: Vector3 = terrain.to_local(target.global_position)
	var cell := Vector2i(
		floori(local_pos.x / meters_per_chunk),
		floori(-local_pos.z / meters_per_chunk)
	)

	if cell == _last_cell:
		return # nothing that could affect the active set has changed
	_last_cell = cell

	_sweep(local_pos, meters_per_chunk)


## Walks every chunk once and flips the ones whose active state should change: active if
## within load_radius of `target`, inactive once beyond unload_radius. O(world_chunks.x *
## world_chunks.y), but only runs on a chunk-boundary crossing rather than every physics
## frame -- fine for a hand-authored world of realistic size. If your terrain grows into
## the hundreds of chunks per side, swap this for a windowed scan around `cell` instead.
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

			if dist_sq <= load_radius_sq:
				if not is_active:
					_queue_chunk_op(cx, cz, true)
			elif deactivate_enabled and is_active and dist_sq > unload_radius_sq:
				_queue_chunk_op(cx, cz, false)


## Records that chunk (cx, cz) should end up `active` -- does not touch the terrain
## itself. Overwrites any previous pending state for the same chunk.
func _queue_chunk_op(cx: int, cz: int, active: bool) -> void:
	_pending_ops[Vector2i(cx, cz)] = active

## Applies up to max_chunk_ops_per_tick queued chunk flips, closest chunks (to `target`)
## first. This is the actual throttle that turns "apply 40 chunk flips this frame" into
## "apply 6 flips a frame for the next several frames" -- spreading the terrain addon's
## mesh/collision (re)generation cost out instead of paying for all of it in one hitch.
##
## Deliberately NOT a full Array.sort_custom() over every pending key: that sorts the WHOLE
## backlog just to use the closest few, and GDScript pays a real per-comparison lambda-call
## cost for it -- if the backlog ever grows faster than max_chunk_ops_per_tick can drain it,
## sort_custom() re-sorting all of it from scratch EVERY tick becomes the actual bottleneck,
## not the terrain rebuilds themselves. _closest_pending() below does a single O(n) pass
## keeping only the smallest `max_chunk_ops_per_tick` entries, which is all this loop needs.
func _drain_pending_ops() -> void:
	if _pending_ops.is_empty() or is_zero_approx(_last_meters_per_chunk) or target == null:
		return

	var local_pos: Vector3 = terrain.to_local(target.global_position)
	var meters_per_chunk := _last_meters_per_chunk

	var closest := _closest_pending(local_pos, meters_per_chunk, max_chunk_ops_per_tick)

	var applied := 0
	for key in closest:
		var desired: bool = _pending_ops[key]
		_pending_ops.erase(key)
		if terrain.is_chunk_active(key.x, key.y) != desired:
			_set_chunk_active(key.x, key.y, meters_per_chunk, desired)
			applied += 1
		# else: already in the desired state (e.g. queued then re-confirmed by a later
		# sweep before it got a turn) -- drop it for free without spending a budget slot.

	if applied > 0:
		# New chunk meshes (including their water surface, if any) may have just been
		# built -- see _fix_water_cull_margins() above for why this has to run here.
		_fix_water_cull_margins()
		# Terrain collision just changed shape (chunks (de)activated), so the baked navmesh
		# is now stale -- ask Builder to rebake. Builder debounces this internally (see
		# NAV_BAKE_DELAY), so it's cheap to call every time a batch of chunk ops lands
		# rather than only once the player stops moving.
		if builder and builder.has_method("request_nav_bake"):
			builder.request_nav_bake()


## Single O(n) pass over _pending_ops.keys() that keeps only the `count` entries closest to
## local_pos, without sorting the rest of a potentially large backlog. Maintains a small
## insertion-sorted buffer of at most `count` (coord, dist_sq) pairs -- cheap because `count`
## is tiny (max_chunk_ops_per_tick, typically single digits), so this is O(n * count) with
## plain comparisons instead of O(n log n) with a per-comparison GDScript lambda call.
func _closest_pending(local_pos: Vector3, meters_per_chunk: float, count: int) -> Array[Vector2i]:
	var best_keys: Array[Vector2i] = []
	var best_dists: Array[float] = []

	for key: Vector2i in _pending_ops:
		var d := _chunk_dist_sq(key, local_pos, meters_per_chunk)
		if best_keys.size() < count:
			# Still filling the buffer -- insert in sorted position (closest first).
			var insert_at := best_keys.size()
			while insert_at > 0 and best_dists[insert_at - 1] > d:
				insert_at -= 1
			best_keys.insert(insert_at, key)
			best_dists.insert(insert_at, d)
		elif d < best_dists[best_dists.size() - 1]:
			# Buffer full -- only bother inserting if this beats the current worst kept entry.
			var insert_at := best_keys.size() - 1
			while insert_at > 0 and best_dists[insert_at - 1] > d:
				insert_at -= 1
			best_keys.insert(insert_at, key)
			best_dists.insert(insert_at, d)
			best_keys.resize(count)
			best_dists.resize(count)

	return best_keys

func _chunk_dist_sq(cell: Vector2i, local_pos: Vector3, meters_per_chunk: float) -> float:
	var center_x: float = (float(cell.x) + 0.5) * meters_per_chunk
	var center_z: float = -(float(cell.y) + 0.5) * meters_per_chunk
	var dx: float = local_pos.x - center_x
	var dz: float = local_pos.z - center_z
	return dx * dx + dz * dz


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


## See the WATER_SHADER doc comment up top. Walks the whole terrain subtree looking for
## MeshInstance3Ds using water.gdshader and patches extra_cull_margin on each one found,
## skipping any already patched (tracked by instance ID) so repeated calls stay cheap --
## only genuinely new mesh instances cost anything.
func _fix_water_cull_margins() -> void:
	_scan_for_water_meshes(terrain)

func _scan_for_water_meshes(node: Node) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		var id := mesh_instance.get_instance_id()
		if not _water_cull_fixed.has(id):
			var mat := _get_water_shader_material(mesh_instance)
			if mat:
				var wave_height = mat.get_shader_parameter("wave_height")
				if wave_height == null:
					wave_height = 0.1 # shader's own uniform default, see water.gdshader
				mesh_instance.extra_cull_margin = max(
					mesh_instance.extra_cull_margin,
					float(wave_height) + water_cull_margin_buffer
				)
				_water_cull_fixed[id] = true
	for child in node.get_children():
		_scan_for_water_meshes(child)

## Returns the ShaderMaterial using water.gdshader on `mi`, checking material_override
## first then each surface's override/base material -- covers however the terrain addon
## actually assigns it, without needing to know its internal chunk-building code.
func _get_water_shader_material(mi: MeshInstance3D) -> ShaderMaterial:
	if mi.material_override is ShaderMaterial and (mi.material_override as ShaderMaterial).shader == WATER_SHADER:
		return mi.material_override as ShaderMaterial
	if mi.mesh:
		for i in range(mi.mesh.get_surface_count()):
			var surf_mat := mi.get_surface_override_material(i)
			if surf_mat == null:
				surf_mat = mi.mesh.surface_get_material(i)
			if surf_mat is ShaderMaterial and (surf_mat as ShaderMaterial).shader == WATER_SHADER:
				return surf_mat as ShaderMaterial
	return null
