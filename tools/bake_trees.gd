@tool
extends EditorScript

# One-time bake tool: run from Script Editor (File > Run, or Ctrl+Shift+X)
# with main.tscn open as the active scene.
#
# BACK UP / COMMIT main.tscn before running. This mutates the open scene
# in-memory; you still need Ctrl+S afterward to persist it to disk.
#
# What it does:
# 1. Scans Main's direct children for tree instances (name starts with
#    "tree", matching your "tree-high2 (114)" style naming from Asset Placer).
# 2. Groups them by source PackedScene path (tree.glb / tree-high.glb / etc).
# 3. Builds one MultiMesh per group from the first instance's MeshInstance3D.
# 4. Adds one MultiMeshInstance3D per group to Main, deletes the original
#    ~1000 heavy nodes.
# 5. Writes transform + wood_amount + chopped state for every tree to
#    res://data/tree_instance_data.tres (a TreeInstanceDataSet resource).

const TREE_NAME_PREFIX := "tree"
const OUTPUT_DATA_PATH := "res://data/tree_instance_data.tres"
const DEFAULT_WOOD_YIELD := 5

func _run() -> void:
	var scene_root := get_scene()
	if scene_root == null:
		push_error("No scene is currently open in the editor.")
		return

	var groups: Dictionary = {}
	var to_remove: Array[Node] = []
	var all_tree_data: Array[TreeInstanceData] = []

	for child in scene_root.get_children():
		if not (child is Node3D):
			continue
		if not child.name.begins_with(TREE_NAME_PREFIX):
			continue

		var variant_path: String = child.scene_file_path
		if variant_path == "":
			if child.has_meta("asset_placer_res_id"):
				variant_path = str(child.get_meta("asset_placer_res_id"))
			else:
				push_warning("Skipping %s — no scene_file_path or asset_placer_res_id" % child.name)
				continue

		var mesh_instance := _find_mesh_instance(child)
		if mesh_instance == null:
			push_warning("Skipping %s — no MeshInstance3D found inside" % child.name)
			continue

		if not groups.has(variant_path):
			groups[variant_path] = {
				"mesh": mesh_instance.mesh,
				"transforms": [] as Array[Transform3D],
			}
		groups[variant_path]["transforms"].append(child.transform)

		var data := TreeInstanceData.new()
		data.transform = child.transform
		data.variant_path = variant_path
		data.wood_amount = DEFAULT_WOOD_YIELD
		data.chopped = false
		all_tree_data.append(data)

		to_remove.append(child)

	if groups.is_empty():
		push_warning("No tree nodes matched prefix '%s' under %s" % [TREE_NAME_PREFIX, scene_root.name])
		return

	var group_index := 0
	for variant_path in groups.keys():
		var group = groups[variant_path]
		var transforms: Array = group["transforms"]

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = group["mesh"]
		mm.instance_count = transforms.size()
		for i in range(transforms.size()):
			mm.set_instance_transform(i, transforms[i])

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.name = "TreesMultiMesh_%d" % group_index
		scene_root.add_child(mmi)
		mmi.owner = scene_root
		group_index += 1

		print("Baked %d instances into %s (source: %s)" % [transforms.size(), mmi.name, variant_path])

	for node in to_remove:
		scene_root.remove_child(node)
		node.queue_free()

	var dir := DirAccess.open("res://")
	if not dir.dir_exists("data"):
		dir.make_dir("data")

	var container := TreeInstanceDataSet.new()
	container.trees = all_tree_data
	var err := ResourceSaver.save(container, OUTPUT_DATA_PATH)
	if err != OK:
		push_error("Failed to save tree data: %s" % err)
	else:
		print("Saved %d tree records to %s" % [all_tree_data.size(), OUTPUT_DATA_PATH])

	print("Done. Ctrl+S the scene now to persist the MultiMesh changes.")


func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found := _find_mesh_instance(child)
		if found:
			return found
	return null
