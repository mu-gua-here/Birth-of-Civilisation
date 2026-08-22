extends Node
class_name TerrainChunkLoader

## Frustum-based load/unload for LowPolyTerrain chunks.
##
## Extends the manual ACTIVATE_CHUNK / DEACTIVATE_CHUNK editor brush (see
## LowPolyTerrainManager.set_chunk_status_in_radius) into a runtime system: chunks the
## CAMERA can actually see are kept active (mesh + collision built), chunks outside its
## view are deactivated (mesh freed, collision released). This is NOT procedural
## generation -- the terrain itself is still fully hand-authored in the editor. This
## only decides, at runtime, which of those hand-authored chunks are currently worth
## paying for.
##
## A plain radius around the player doesn't match what's actually on screen: with a
## 3rd-person camera that can rotate and zoom, "near the player" and "visible right now"
## are different sets, so a radius either wastes draw calls behind the camera or pops
## chunks in at the screen edge. Instead this tests each chunk's world-space AABB
## against Camera3D.get_frustum() directly.
##
## `core_radius` is a small always-on safety net around `target`, independent of the
## frustum: citizens and physics need collision under the player/camera target even in
## the (rare) frame where the camera is pointed elsewhere. It is intentionally much
## smaller than the old load_radius default -- it's a gameplay floor, not the main
## loading mechanism anymore.
##
## Two independent margins create hysteresis so a chunk sitting right on the frustum
## edge doesn't flicker on/off every sweep:
##   frustum_load_margin   -- chunk AABBs are grown by this much before the load test
##   frustum_unload_margin -- chunk AABBs are grown by this much (larger) before the
##                             unload test; an active chunk only unloads once it fails
##                             even this generous test
## view_distance additionally caps how far out the frustum test is allowed to reach, so
## a wide FOV / large far-plane camera doesn't load the whole map.
##
## Re-swept whenever the target crosses a chunk boundary OR the camera moves/rotates
## past a small threshold -- unlike a pure radius, the frustum can change with the
## camera alone, even while the target stands still.

## The terrain to manage. Must be a LowPolyTerrainManager (or NavigationRegion3D/etc.
## parent path pointing at one) -- assign in the inspector or leave empty to auto-find
## the first LowPolyTerrainManager under the scene root.
@export var terrain: LowPolyTerrainManager

## Node whose position drives the always-on core_radius safety net. Leave empty to use
## the first node in the "player" group (matches how player.gd registers itself).
@export var target: Node3D

## The camera whose frustum decides visibility. Leave empty to auto-find via the first
## node in the "view" group, falling back to the active viewport camera.
@export var camera: Camera3D

## Builder node whose request_nav_bake() gets called whenever chunks actually finish
## activating/deactivating. Leave empty to auto-find via the "builder" group. Chunk
## streaming changes what terrain collision exists, which is exactly the geometry
## NavigationRegion3D bakes from (see Builder._bake_nav()) -- without this, a single
## bake done at game start goes stale the moment the player walks somewhere new, and
## citizens either can't path onto newly-loaded ground or keep trying to path across
## ground that already unloaded.
@export var builder: Node

## Chunks within this many METERS of target are always kept active regardless of the
## frustum -- a floor for gameplay/collision (citizens, physics) under the target even
## if the camera happens to be looking elsewhere.
@export var core_radius: float = 25.0

## Hard cap in METERS on how far out the frustum test is allowed to load chunks, even if
## they're technically inside the frustum (keeps a wide FOV/far-plane camera from
## loading the whole map).
@export var view_distance: float = 160.0

## Chunk AABBs are grown by this many METERS before the load test. Gives a small buffer
## so chunks finish building just before they scroll into view instead of popping in.
@export var frustum_load_margin: float = 12.0

## Chunk AABBs are grown by this many METERS before the unload test. Keep this
## comfortably larger than frustum_load_margin or chunks will thrash at the frustum edge.
@export var frustum_unload_margin: float = 35.0

## Half-height in METERS of the box used to approximate each chunk's vertical extent for
## the frustum test (terrain height data isn't queried directly -- this just needs to be
## generous enough that tall terrain/structures in a chunk are never wrongly culled).
@export var chunk_height_extent: float = 120.0

## Seconds between sweeps at minimum, on top of the boundary/camera-movement check.
## Mostly a safety net; that check already skips almost all frames for free.
@export var check_interval: float = 0.15

## Degrees added to the camera's actual FOV (both horizontally and vertically, since
## Camera3D.fov drives both via aspect) purely for the visibility TEST -- the rendered
## FOV never changes. Without this, a chunk only counts as "visible" once it's fully
## inside the exact, literal view cone, so nothing near the screen edge is pre-loaded;
## a fast turn then finds a big batch of chunks that are ALL suddenly newly-visible at
## once, which is what causes the load spike/hitch. Padding the test angle makes chunks
## go active a bit before they scroll on-screen, spreading that work out over the turn
## instead of dumping it all into one sweep the instant they cross the true frustum edge.
@export_range(0.0, 60.0) var frustum_fov_padding_degrees: float = 20.0

## Max number of chunk activate/deactivate calls actually applied per physics tick.
## _sweep() can decide many chunks need to flip in one go (e.g. a fast snap-turn); each
## flip calls into the terrain addon to build/free real mesh + collision, which is the
## expensive part and the actual source of the rotation-hitch. Rather than applying every
## flip in the same frame, they're queued and drained at this rate, closest chunks first,
## so a big turn costs a few frames of gradual pop-in instead of one big frame hitch.
@export var max_chunk_ops_per_tick: int = 6

## If true, chunks outside the frustum+core_radius are deactivated once the loader
## starts managing them (existing manually-deactivated chunks are left alone). Useful
## while you're still hand-placing world dressing and don't want the loader fighting you.
@export var deactivate_enabled: bool = true

## Camera movement (meters) past which a sweep is forced even without a chunk-boundary
## crossing -- covers the camera panning/zooming while the target stands still.
const CAMERA_MOVE_EPSILON := 1.0
## Camera rotation (as a forward-vector dot-product delta) past which a sweep is forced.
const CAMERA_TURN_DOT_EPSILON := 0.02

var _timer: float = 0.0
var _last_cell: Vector2i = Vector2i(-999999, -999999) # sentinel so the first sweep always runs
var _last_cam_pos: Vector3 = Vector3.INF
var _last_cam_fwd: Vector3 = Vector3.ZERO

# Desired-state queue drained a few chunks at a time (see max_chunk_ops_per_tick). Keyed
# by chunk coord so a chunk re-evaluated before its previous op is applied just has its
# desired state overwritten rather than queuing duplicate work.
var _pending_ops: Dictionary = {} # Vector2i(cx, cz) -> bool desired_active
var _last_meters_per_chunk: float = 0.0

## Fixes water-mesh edge clipping -- NOT a frustum bug in this loader (that part is
## working correctly, whole-chunk activate/deactivate). water.gdshader's vertex()
## raises the surface by up to wave_height, but Godot's own per-MeshInstance3D GPU
## frustum culling tests the UNDISPLACED mesh bounding box -- so a chunk's water
## surface can pop out the instant that static box edge leaves the frustum, even
## though the raised waves would still be visible on screen. The shader's own header
## comment documents the fix: set GeometryInstance3D.extra_cull_margin on the
## MeshInstance3D. This loader is the natural place to apply it since it's already the
## thing deciding when chunk meshes come into existence -- newly-activated chunks are
## scanned for water-shader MeshInstance3Ds and patched once each.
const WATER_SHADER: Shader = preload("res://addons/lowpolyterrain/shader/water.gdshader")
## Extra slack in METERS added on top of the shader's own wave_height, to cover the
## detail-noise term (see water.gdshader's low_poly_wave()) which can push slightly
## higher than wave_height alone would suggest.
@export var water_cull_margin_buffer: float = 0.5
var _water_cull_fixed: Dictionary = {} # MeshInstance3D instance_id (int) -> true, so each is only patched once ever


func _ready() -> void:
	if terrain == null:
		terrain = _find_terrain_manager(get_tree().current_scene)
	if target == null:
		target = get_tree().get_first_node_in_group("player")
	if camera == null:
		camera = _find_camera()
	if builder == null:
		builder = get_tree().get_first_node_in_group("builder")

	if terrain == null:
		push_warning("TerrainChunkLoader: no LowPolyTerrainManager assigned or found. Disabling.")
	else:
		print("TerrainChunkLoader: Using \"%s\" as LowPolyTerrainManager" % terrain.name)
	if target == null:
		push_warning("TerrainChunkLoader: no target assigned and no node in group 'player'. Disabling.")
	if camera == null:
		push_warning("TerrainChunkLoader: no camera assigned/found. Falling back to core_radius only.")

	set_physics_process(terrain != null and target != null)
	# Catch any chunks already active before this loader started managing them (e.g.
	# manually activated in the editor).
	if terrain != null:
		_fix_water_cull_margins()


func _find_camera() -> Camera3D:
	var view := get_tree().get_first_node_in_group("view")
	if view:
		for child in view.get_children():
			if child is Camera3D:
				return child as Camera3D
	return get_viewport().get_camera_3d()


func _physics_process(delta: float) -> void:
	# Drain a few queued chunk flips every physics tick, independent of the sweep
	# throttle below -- this is what actually spreads a big turn's worth of newly-
	# visible chunks out over several frames instead of applying them all at once.
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

	var cell_changed := cell != _last_cell
	var cam_changed := _camera_changed_significantly()
	if not cell_changed and not cam_changed:
		return # nothing that could affect the active set has changed
	_last_cell = cell

	_sweep(local_pos, meters_per_chunk)


## True if the camera has moved or turned enough since the last sweep to matter. Always
## true on the first call (via the Vector3.INF sentinel) and whenever there's no camera
## (so core_radius-only mode still re-sweeps on its own schedule via check_interval).
func _camera_changed_significantly() -> bool:
	if camera == null:
		return true
	var cam_pos := camera.global_position
	var cam_fwd := -camera.global_transform.basis.z
	if _last_cam_pos == Vector3.INF:
		_last_cam_pos = cam_pos
		_last_cam_fwd = cam_fwd
		return true
	var moved := cam_pos.distance_to(_last_cam_pos) >= CAMERA_MOVE_EPSILON
	var turned := _last_cam_fwd.dot(cam_fwd) <= (1.0 - CAMERA_TURN_DOT_EPSILON)
	if moved or turned:
		_last_cam_pos = cam_pos
		_last_cam_fwd = cam_fwd
		return true
	return false


## Walks every chunk once and flips the ones whose active state should change: active
## either because they're within core_radius of `target`, or because their (margin-
## grown) world-space AABB intersects the camera's view frustum within view_distance.
## O(world_chunks.x * world_chunks.y), but only runs on a chunk-boundary crossing or a
## meaningful camera move/turn rather than every physics frame -- fine for a
## hand-authored world of realistic size. If your terrain grows into the hundreds of
## chunks per side, swap this for a windowed scan around `cell` instead of the full grid.
func _sweep(local_pos: Vector3, meters_per_chunk: float) -> void:
	var core_radius_sq: float = core_radius * core_radius
	var reach_sq: float = (view_distance + frustum_unload_margin) * (view_distance + frustum_unload_margin)

	for cz in range(terrain.world_chunks.y):
		for cx in range(terrain.world_chunks.x):
			var center_x: float = (float(cx) + 0.5) * meters_per_chunk
			var center_z: float = -(float(cz) + 0.5) * meters_per_chunk
			var dx: float = local_pos.x - center_x
			var dz: float = local_pos.z - center_z
			var dist_sq: float = dx * dx + dz * dz

			var is_active: bool = terrain.is_chunk_active(cx, cz)
			var within_core: bool = dist_sq <= core_radius_sq

			if within_core:
				if not is_active:
					_queue_chunk_op(cx, cz, true)
				continue

			# Outside the core safety net -- visibility is decided purely by the frustum.
			if camera != null and dist_sq <= reach_sq:
				var chunk_aabb := _chunk_world_aabb(cx, cz, meters_per_chunk)
				var margin: float = frustum_unload_margin if is_active else frustum_load_margin
				var aabb := chunk_aabb.grow(margin)
				var visible: bool = _aabb_in_frustum(aabb, frustum_fov_padding_degrees)

				if visible and not is_active:
					_queue_chunk_op(cx, cz, true)
				elif deactivate_enabled and is_active and not visible:
					_queue_chunk_op(cx, cz, false)
			elif deactivate_enabled and is_active:
				# No camera, or chunk is beyond the hard view_distance cap -- unload it.
				_queue_chunk_op(cx, cz, false)

## Tests whether `aabb` is visible to `camera` by checking its 8 corners (plus its
## center, in case the camera sits inside a very large/near AABB with no corner in
## view) against Camera3D.is_position_in_frustum(). This deliberately avoids
## Camera3D.get_frustum()'s manual Plane math -- that array's normal/d sign convention
## isn't documented anywhere and is trivial to get backwards, and doing so silently
## makes every AABB test fail closed (which is exactly what was happening: nothing
## outside core_radius ever lit up, regardless of camera angle). is_position_in_frustum()
## is the engine's own per-point test, so there's no convention left to get wrong.
func _aabb_in_frustum(aabb: AABB, fov_padding_degrees: float = 0.0) -> bool:
	var minp := aabb.position
	var maxp := aabb.position + aabb.size

	# Temporarily widen the camera's FOV for this test only (same pattern as the
	# brush_radius save/restore in _set_chunk_active) -- gives the visibility check a
	# buffer beyond the literal render frustum without touching what's actually drawn.
	var restore_fov := camera.fov
	var padded := fov_padding_degrees > 0.0 and camera.projection == Camera3D.PROJECTION_PERSPECTIVE
	if padded:
		camera.fov = clampf(restore_fov + fov_padding_degrees, 1.0, 179.0)

	var visible := false
	for i in range(8):
		var corner := Vector3(
			minp.x if (i & 1) == 0 else maxp.x,
			minp.y if (i & 2) == 0 else maxp.y,
			minp.z if (i & 4) == 0 else maxp.z
		)
		if camera.is_position_in_frustum(corner):
			visible = true
			break
	if not visible:
		visible = camera.is_position_in_frustum(aabb.get_center())

	if padded:
		camera.fov = restore_fov

	return visible

## Records that chunk (cx, cz) should end up `active` -- does not touch the terrain
## itself. Overwrites any previous pending state for the same chunk (e.g. a chunk that
## flickered in and out of the frustum across two sweeps before its queue slot came up
## just gets its latest desired state; no duplicate/stale work).
func _queue_chunk_op(cx: int, cz: int, active: bool) -> void:
	_pending_ops[Vector2i(cx, cz)] = active

## Applies up to max_chunk_ops_per_tick queued chunk flips, closest chunks (to `target`)
## first. This is the actual throttle that turns "apply 40 chunk flips this frame" into
## "apply 6 flips a frame for the next several frames" -- spreading the terrain addon's
## mesh/collision (re)generation cost out instead of paying for all of it in one hitch.
func _drain_pending_ops() -> void:
	if _pending_ops.is_empty() or is_zero_approx(_last_meters_per_chunk) or target == null:
		return

	var local_pos: Vector3 = terrain.to_local(target.global_position)
	var meters_per_chunk := _last_meters_per_chunk

	var keys := _pending_ops.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return _chunk_dist_sq(a, local_pos, meters_per_chunk) < _chunk_dist_sq(b, local_pos, meters_per_chunk)
	)

	var applied := 0
	for key in keys:
		if applied >= max_chunk_ops_per_tick:
			break
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

func _chunk_dist_sq(cell: Vector2i, local_pos: Vector3, meters_per_chunk: float) -> float:
	var center_x: float = (float(cell.x) + 0.5) * meters_per_chunk
	var center_z: float = -(float(cell.y) + 0.5) * meters_per_chunk
	var dx: float = local_pos.x - center_x
	var dz: float = local_pos.z - center_z
	return dx * dx + dz * dz

## World-space AABB for chunk (cx, cz), padded vertically by chunk_height_extent since
## terrain height data isn't queried directly -- this only needs to be generous, not exact.
func _chunk_world_aabb(cx: int, cz: int, meters_per_chunk: float) -> AABB:
	var local_origin := Vector3(
		float(cx) * meters_per_chunk,
		-chunk_height_extent,
		-(float(cz) + 1.0) * meters_per_chunk
	)
	var size := Vector3(meters_per_chunk, chunk_height_extent * 2.0, meters_per_chunk)
	return terrain.global_transform * AABB(local_origin, size)


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
