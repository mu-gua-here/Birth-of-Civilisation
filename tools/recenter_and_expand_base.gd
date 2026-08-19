@tool
extends EditorScript

# --------------------------------------------------------------------------------
# One-off tool: expands the "Base" LowPolyTerrainManager to a new grid size and
# re-centers the currently sculpted data in the middle of the new grid, instead
# of leaving it pinned to the origin corner (which is what "Apply Dimension
# Changes" does on its own).
#
# HOW TO RUN:
#   1. Open this file in Godot's Script Editor (double-click it in the FileSystem dock).
#   2. Make sure the scene containing your "Base" terrain node is open in the editor
#      (it needs to be part of the currently edited scene tree).
#   3. File > Run (or Ctrl+Shift+X).
#   4. Check the Output panel for the printed confirmation.
#
# This is safe to inspect before running: it only reads/writes the exported data on
# the Base node in memory. Nothing is written to disk until you save the scene
# afterwards -- so if the result looks wrong, just close the scene WITHOUT saving
# and nothing is lost.
# --------------------------------------------------------------------------------

# Adjust this if "Base" isn't found automatically. Path is relative to the
# currently edited scene's root.
const NODE_PATH := "Base"

# Target grid configuration.
const NEW_WORLD_CHUNKS := Vector2i(50, 50)
const NEW_CHUNK_SIZE := 10
const NEW_CELL_SIZE := 1.0


func _run() -> void:
	var scene_root: Node = EditorInterface.get_edited_scene_root()
	if scene_root == null:
		push_error("No scene is currently open in the editor. Open the scene containing 'Base' first.")
		return

	var terrain: Node = scene_root.get_node_or_null(NODE_PATH)
	if terrain == null:
		# Fallback: search the whole tree for a node named "Base".
		terrain = _find_by_name(scene_root, "Base")
	if terrain == null:
		push_error("Could not find a node named 'Base' in the current scene. " \
			+ "Edit NODE_PATH at the top of this script to the correct path.")
		return

	if not terrain.has_method("_apply_dimension_snapshot"):
		push_error("Node '%s' does not look like a LowPolyTerrainManager " % terrain.name \
			+ "(missing _apply_dimension_snapshot). Wrong node?")
		return

	# --- Read the CURRENT state directly off the node ---
	var old_world_chunks: Vector2i = terrain.world_chunks
	var old_chunk_size: int = terrain.chunk_size
	var old_cell_size: float = terrain.cell_size
	var old_heights: PackedFloat32Array = terrain.global_height_data.duplicate()
	var old_activity: PackedByteArray = terrain.chunk_activity_data.duplicate()
	var old_paint: PackedByteArray = terrain.global_paint_data.duplicate()

	var old_total_x: int = old_world_chunks.x * old_chunk_size + 1
	var old_total_z: int = old_world_chunks.y * old_chunk_size + 1

	print("Current Base grid: %s chunks, chunk_size=%d, cell_size=%.2f (%dx%d vertices)"
		% [old_world_chunks, old_chunk_size, old_cell_size, old_total_x, old_total_z])

	if old_heights.size() != old_total_x * old_total_z:
		push_warning("global_height_data size (%d) does not match expected %dx%d (%d). " \
			% [old_heights.size(), old_total_x, old_total_z, old_total_x * old_total_z] \
			+ "Proceeding anyway, but double check the result.")

	# --- Compute the new grid ---
	var new_total_x: int = NEW_WORLD_CHUNKS.x * NEW_CHUNK_SIZE + 1
	var new_total_z: int = NEW_WORLD_CHUNKS.y * NEW_CHUNK_SIZE + 1

	# Chunk-aligned offset so existing chunk seams stay intact. Using floor() means an
	# odd leftover chunk (e.g. (40-15)/2 = 12.5) goes to the +X/+Z side rather than
	# splitting a chunk in half.
	var offset_chunks_x: int = int(floor(float(NEW_WORLD_CHUNKS.x - old_world_chunks.x) / 2.0))
	var offset_chunks_z: int = int(floor(float(NEW_WORLD_CHUNKS.y - old_world_chunks.y) / 2.0))

	if offset_chunks_x < 0 or offset_chunks_z < 0:
		push_error("New grid (%s) is smaller than the current one (%s) on at least one axis. " \
			% [NEW_WORLD_CHUNKS, old_world_chunks] \
			+ "This script only handles growing the grid, to avoid silently discarding data.")
		return

	var offset_vertices_x: int = offset_chunks_x * NEW_CHUNK_SIZE
	var offset_vertices_z: int = offset_chunks_z * NEW_CHUNK_SIZE

	print("Centering with chunk offset (%d, %d) / vertex offset (%d, %d)"
		% [offset_chunks_x, offset_chunks_z, offset_vertices_x, offset_vertices_z])

	# --- Build new height array, old data copied into the middle ---
	var new_heights := PackedFloat32Array()
	new_heights.resize(new_total_x * new_total_z)
	new_heights.fill(0.0)

	for z in range(old_total_z):
		var src_row: int = z * old_total_x
		var dst_row: int = (z + offset_vertices_z) * new_total_x + offset_vertices_x
		for x in range(old_total_x):
			new_heights[dst_row + x] = old_heights[src_row + x]

	# --- Build new chunk activity array. New chunks default to ACTIVE (1), so the
	# expanded area actually renders and can be sculpted right away. ---
	var new_activity := PackedByteArray()
	new_activity.resize(NEW_WORLD_CHUNKS.x * NEW_WORLD_CHUNKS.y)
	new_activity.fill(1)

	for cz in range(old_world_chunks.y):
		var src_row: int = cz * old_world_chunks.x
		var dst_row: int = (cz + offset_chunks_z) * NEW_WORLD_CHUNKS.x + offset_chunks_x
		for cx in range(old_world_chunks.x):
			new_activity[dst_row + cx] = old_activity[src_row + cx]

	# --- Build new paint array (only if the old terrain had any paint data at all) ---
	var new_paint := PackedByteArray()
	if not old_paint.is_empty():
		new_paint.resize(new_total_x * new_total_z * 4)
		new_paint.fill(0)

		for z in range(old_total_z):
			var src_row: int = z * old_total_x * 4
			var dst_row: int = ((z + offset_vertices_z) * new_total_x + offset_vertices_x) * 4
			for i in range(old_total_x * 4):
				new_paint[dst_row + i] = old_paint[src_row + i]

	# --- Commit everything through the manager's own snapshot restorer, so it also
	# updates preview_* fields, recalculates bounds, and rebuilds the chunk meshes. ---
	terrain._apply_dimension_snapshot(
		NEW_WORLD_CHUNKS, NEW_CHUNK_SIZE, NEW_CELL_SIZE,
		new_heights, new_activity, new_paint
	)

	print("Done. Base is now %s chunks (%dx%d meters), old terrain re-centered inside it." \
		% [NEW_WORLD_CHUNKS, NEW_WORLD_CHUNKS.x * NEW_CHUNK_SIZE, NEW_WORLD_CHUNKS.y * NEW_CHUNK_SIZE])
	print("Remember: nothing is saved to disk yet. Check the viewport, then save the scene " \
		+ "(Ctrl+S) once you're happy with it.")


func _find_by_name(root: Node, target_name: String) -> Node:
	if root.name == target_name:
		return root
	for child in root.get_children():
		var found: Node = _find_by_name(child, target_name)
		if found != null:
			return found
	return null
