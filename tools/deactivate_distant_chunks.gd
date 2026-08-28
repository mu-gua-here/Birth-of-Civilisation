@tool
extends EditorScript

# --------------------------------------------------------------------------------
# One-off tool: mass-deactivates every chunk beyond KEEP_RADIUS_METERS of SPAWN_WORLD_POS
# in BOTH the land ("Base") and ocean ("Ocean") LowPolyTerrainManagers, writing directly
# into chunk_activity_data.
#
# WHY THIS MATTERS: LowPolyTerrainManager._ready() -> rebuild_chunks_structure() builds a
# full Delaunay-triangulated mesh for EVERY chunk marked active in chunk_activity_data,
# unconditionally, before TerrainChunkLoader (or anything else at runtime) gets a chance
# to intervene. chunk_activity_data defaults to all-1s (every chunk "active") unless you
# deliberately painted chunks inactive with the DEACTIVATE_CHUNK brush -- so a fresh/full
# 50x50 grid means the manager eagerly builds the ENTIRE map on every single launch, for
# both terrains, regardless of what TerrainChunkLoader's load_radius says it actually
# wants resident. That is what was freezing the web build: ~5000 full chunk rebuilds
# (2500 chunks x 2 terrains) crammed into the first frame before the game can even show
# anything.
#
# This script fixes the ROOT of that: chunk_activity_data is supposed to be persisted
# authoring state (that's what the ACTIVATE_CHUNK/DEACTIVATE_CHUNK brush writes to), not
# left at its "everything on" default for a world this size. After running this, only
# chunks near spawn are active at scene-load time, so the manager's own startup rebuild
# has almost nothing to do -- TerrainChunkLoader activates the rest on approach exactly
# as it's designed to.
#
# HOW TO RUN:
#   1. Open this file in Godot's Script Editor (double-click it in the FileSystem dock).
#   2. Make sure the scene containing your "Base" and "Ocean" terrain nodes is open in
#      the editor (main.tscn -- they need to be part of the currently edited scene tree).
#   3. Adjust SPAWN_WORLD_POS and KEEP_RADIUS_METERS below if needed.
#   4. File > Run (or Ctrl+Shift+X).
#   5. Check the Output panel for the printed confirmation.
#
# Safe to inspect before running: only chunk_activity_data (and the resulting mesh/node
# state) is touched, in memory. Nothing is written to disk until you save the scene
# afterwards -- close without saving if the result looks wrong and nothing is lost.
# --------------------------------------------------------------------------------

# World-space spawn point chunks are kept active around. Matches Player's starting
# position in main.tscn (transform origin x=6.2, z=-66.118) -- update this if that moves.
const SPAWN_WORLD_POS := Vector3(6.2, 0.0, -66.118)

# Chunks whose center falls within this many METERS of SPAWN_WORLD_POS stay active;
# everything else gets deactivated. Set comfortably above TerrainChunkLoader's
# unload_radius (160.0 as of this writing) so the player never spawns near the active/
# inactive boundary and sees a pop-in seam immediately.
const KEEP_RADIUS_METERS := 150.0

# Group names TerrainChunkLoader/TerrainOccluderSetup already rely on -- reused here so
# this script finds the same nodes those do, however the scene tree happens to be
# structured. Falls back to searching by node name if the groups aren't set.
const LAND_GROUP := "terrain_land"
const OCEAN_GROUP := "terrain_ocean"


func _run() -> void:
	var scene_root: Node = EditorInterface.get_edited_scene_root()
	if scene_root == null:
		push_error("No scene is currently open in the editor. Open main.tscn first.")
		return

	var land := _find_terrain(scene_root, LAND_GROUP, "Base")
	var ocean := _find_terrain(scene_root, OCEAN_GROUP, "Ocean")

	if land == null and ocean == null:
		push_error("Could not find either terrain manager (checked groups '%s'/'%s' and names 'Base'/'Ocean'). Nothing to do."
			% [LAND_GROUP, OCEAN_GROUP])
		return

	if land != null:
		_deactivate_outside_radius(land)
	else:
		push_warning("Land terrain not found -- skipped.")

	if ocean != null:
		_deactivate_outside_radius(ocean)
	else:
		push_warning("Ocean terrain not found -- skipped.")

	print("Done. Remember: nothing is saved to disk yet. Check the viewport, then save " \
		+ "the scene (Ctrl+S) once you're happy with it.")


func _find_terrain(scene_root: Node, group: String, fallback_name: String) -> Node:
	for node in scene_root.get_tree().get_nodes_in_group(group):
		if node.has_method("_apply_dimension_snapshot"): # cheap LowPolyTerrainManager check
			return node
	var by_name := scene_root.find_child(fallback_name, true, false)
	if by_name != null and by_name.has_method("_apply_dimension_snapshot"):
		return by_name
	return null


func _deactivate_outside_radius(terrain: Node) -> void:
	var world_chunks: Vector2i = terrain.world_chunks
	var chunk_size: int = terrain.chunk_size
	var cell_size: float = terrain.cell_size
	var meters_per_chunk: float = float(chunk_size) * cell_size

	if is_zero_approx(meters_per_chunk):
		push_warning("'%s': chunk_size/cell_size look uninitialised, skipping." % terrain.name)
		return

	var activity: PackedByteArray = terrain.chunk_activity_data.duplicate()
	var expected_total: int = world_chunks.x * world_chunks.y
	if activity.size() != expected_total:
		activity.resize(expected_total)
		activity.fill(1)

	# Spawn position converted into this terrain's own local space, since Base and Ocean
	# may not share the same global transform (e.g. Ocean sitting lower for sea level).
	var local_spawn: Vector3 = terrain.to_local(SPAWN_WORLD_POS)
	var radius_sq: float = KEEP_RADIUS_METERS * KEEP_RADIUS_METERS

	var kept_active := 0
	var deactivated := 0

	for cz in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var center_x: float = (float(cx) + 0.5) * meters_per_chunk
			var center_z: float = -(float(cz) + 0.5) * meters_per_chunk
			var dx: float = local_spawn.x - center_x
			var dz: float = local_spawn.z - center_z
			var dist_sq: float = dx * dx + dz * dz

			var index: int = cz * world_chunks.x + cx
			if dist_sq <= radius_sq:
				activity[index] = 1
				kept_active += 1
			else:
				activity[index] = 0
				deactivated += 1

	terrain.chunk_activity_data = activity
	if terrain.has_method("rebuild_chunks_structure"):
		terrain.rebuild_chunks_structure()

	print("'%s': %d chunks kept active near spawn, %d deactivated (%d total, %.0fm radius)."
		% [terrain.name, kept_active, deactivated, expected_total, KEEP_RADIUS_METERS])
