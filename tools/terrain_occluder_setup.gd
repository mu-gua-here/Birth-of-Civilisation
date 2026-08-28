extends Node
class_name TerrainOccluderSetup

## Builds one coarse OccluderInstance3D proxy from the land terrain's height data at
## startup, so ocean geometry hidden underneath hills/mountains gets skipped by Godot's
## own occlusion culling (a different mechanism from frustum culling -- it hides things
## BEHIND opaque geometry even when they're inside the frustum, which frustum culling
## alone can never do).
##
## Runtime-built rather than hand-placed in the editor: terrain.res is a binary
## PackedScene, so its internal node tree isn't reachable for hand-adding a node the way
## a .tscn is (see TerrainChunkLoader's terrain_group doc comment for the same problem).
## Building it fresh every launch from Base's own height data also means it never goes
## stale if the terrain gets re-sculpted -- there's nothing baked to fall out of sync.
##
## Deliberately coarse and deliberately LOWERED below the real surface (see
## occluder_lower_margin): an occluder that overshoots the real geometry it's meant to
## represent can hide something that should actually be visible, which reads as a much
## worse bug than an occluder that's slightly too conservative and just misses a few
## culling opportunities at silhouette edges. This only ever needs to be built once, so
## erring conservative costs nothing.

## Group name used to find the land LowPolyTerrainManager to build the occluder from.
## Matches TerrainChunkLoader's terrain_group pattern -- tag the "Base" node with this
## group from inside terrain.res (open it as its own scene) and this resolves it
## automatically, surviving renames/moves.
##
## In practice the editor's Groups-tab assignment has repeatedly failed to persist across
## saves of terrain.res, so `land_terrain_name` below is the more reliable option.
@export var land_terrain_group: String = "terrain_land"

## Node NAME (not path) used to find the land terrain when `land_terrain_group` doesn't
## resolve anything. Recursive find_child(), so no Editable Children or group
## bookkeeping needed -- this is the recommended way to wire this up.
@export var land_terrain_name: String = "Base"

## Every Nth height-grid vertex is sampled to build the occluder mesh. Occluders should
## be MUCH lower-poly than the render mesh -- they exist purely to reject draw calls
## behind them, not to look like anything. 8 means one occluder vertex per 8 terrain
## cells (e.g. an 8-meter grid at cell_size=1.0), which is generous for a silhouette
## proxy and keeps the resulting mesh tiny regardless of world size.
@export var downsample: int = 8

## METERS the occluder surface is lowered below the true sampled height, so it always
## sits safely inside the real landmass rather than exactly at (or above) its surface.
## Lower height data isn't sampled and averaged here on purpose -- a flat per-vertex
## lowering is enough to be safe without needing a min-filter pass over the fine grid.
@export var occluder_lower_margin: float = 3.0

## Set true to also add a translucent debug MeshInstance3D showing the occluder's actual
## shape, since OccluderInstance3D itself renders nothing visible.
@export var show_debug_mesh: bool = false


func _ready() -> void:
	# Deliberately NOT done inline here. Every other one-time setup cost in the scene
	# (both TerrainChunkLoaders' first catch-up sweep, Builder's spawn_citizens() and
	# initial nav bake trigger) also runs from its own _ready(), and Godot calls every
	# node's _ready() within the same frame during scene entry -- so without this they'd
	# all stack into one single wall-clock frame-1 spike. Awaiting a frame here pushes
	# this specific cost to frame 2 instead, spreading the total one-time setup cost
	# across frames rather than reducing it.
	await get_tree().process_frame
	var terrain := _find_terrain()
	if terrain == null:
		push_warning("TerrainOccluderSetup: no land LowPolyTerrainManager found (group '%s' and DFS fallback both failed). Skipping." % land_terrain_group)
		return

	var mesh := _build_occluder_mesh(terrain)
	if mesh == null:
		push_warning("TerrainOccluderSetup: could not build an occluder mesh from '%s' (no height data?). Skipping." % terrain.name)
		return

	var occ := ArrayOccluder3D.new()
	occ.vertices = mesh.get("vertices")
	occ.indices = mesh.get("indices")

	var occluder_instance := OccluderInstance3D.new()
	occluder_instance.occluder = occ
	terrain.add_child(occluder_instance)
	occluder_instance.owner = null # runtime-only, never meant to be saved into the scene

	if show_debug_mesh:
		_add_debug_mesh(terrain, mesh.get("vertices"), mesh.get("indices"))

	print("TerrainOccluderSetup: built occluder proxy for \"%s\" (%d vertices, %d triangles)"
		% [terrain.name, mesh.get("vertices").size(), mesh.get("indices").size() / 3])


func _find_terrain() -> LowPolyTerrainManager:
	if land_terrain_group != "":
		var found := get_tree().get_first_node_in_group(land_terrain_group)
		if found is LowPolyTerrainManager:
			return found
	if land_terrain_name != "":
		var by_name := get_tree().current_scene.find_child(land_terrain_name, true, false)
		if by_name is LowPolyTerrainManager:
			return by_name
	return _find_terrain_manager(get_tree().current_scene)

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


## Downsamples `terrain.global_height_data` onto a coarse grid and triangulates it into a
## flat vertex/index pair suitable for ArrayOccluder3D. Same flat-array indexing
## (z * total_x + x) as every other tool in this project that reads global_height_data
## directly -- see recenter_and_expand_base.gd for the reference layout.
func _build_occluder_mesh(terrain: LowPolyTerrainManager) -> Dictionary:
	var heights: PackedFloat32Array = terrain.global_height_data
	if heights.is_empty():
		return {}

	var total_x: int = terrain.world_chunks.x * terrain.chunk_size + 1
	var total_z: int = terrain.world_chunks.y * terrain.chunk_size + 1
	if heights.size() != total_x * total_z:
		push_warning("TerrainOccluderSetup: global_height_data size (%d) doesn't match expected %dx%d (%d) -- terrain may have been mid-edit. Proceeding anyway." \
			% [heights.size(), total_x, total_z, total_x * total_z])

	var step: int = maxi(downsample, 1)
	@warning_ignore("integer_division")
	var grid_w: int = (total_x - 1) / step + 1
	@warning_ignore("integer_division")
	var grid_h: int = (total_z - 1) / step + 1
	if grid_w < 2 or grid_h < 2:
		return {}

	var cell_size: float = terrain.cell_size

	var verts := PackedVector3Array()
	verts.resize(grid_w * grid_h)

	for gz in range(grid_h):
		var z: int = mini(gz * step, total_z - 1)
		for gx in range(grid_w):
			var x: int = mini(gx * step, total_x - 1)
			var h: float = heights[x + z * total_x] - occluder_lower_margin
			verts[gz * grid_w + gx] = Vector3(
				float(x) * cell_size,
				h,
				-float(z) * cell_size
			)

	var indices := PackedInt32Array()
	indices.resize((grid_w - 1) * (grid_h - 1) * 6)
	var cursor: int = 0
	for gz in range(grid_h - 1):
		for gx in range(grid_w - 1):
			var i0: int = gz * grid_w + gx
			var i1: int = i0 + 1
			var i2: int = i0 + grid_w
			var i3: int = i2 + 1
			# Two triangles per quad, wound to face up (matches the manager's own +Z-back /
			# CCW-from-above convention used throughout LowPolyTerrainMeshBuilder).
			indices[cursor] = i0; cursor += 1
			indices[cursor] = i2; cursor += 1
			indices[cursor] = i1; cursor += 1
			indices[cursor] = i1; cursor += 1
			indices[cursor] = i2; cursor += 1
			indices[cursor] = i3; cursor += 1

	return {"vertices": verts, "indices": indices}


func _add_debug_mesh(terrain: Node, verts: PackedVector3Array, indices: PackedInt32Array) -> void:
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.4, 0.0, 0.35)
	mat.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	terrain.add_child(mi)
	mi.owner = null
