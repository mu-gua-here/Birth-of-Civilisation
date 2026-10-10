extends Node3D
class_name Builder

## Responsible for the construction and demolition of objects

@export var structures: Array[Structure] = []

var map: DataMap

# Cached LowPolyTerrainManager, resolved lazily on first use (the scene tree may not
# be fully ready the instant _ready() runs). Used to snap freeform placement/preview
# to actual ground height -- see _get_terrain_height().
var _terrain_manager: Node = null
var _terrain_lookup_done := false

var index: int = 0 # Index of structure being built

@export var selector: Node3D # The 'cursor'
@export var selector_container: Node3D # Node that holds a preview of the structure
@export var view_camera: Camera3D # Used for raycasting mouse
@export var citizen_scene: PackedScene
@export var nav_region: NavigationRegion3D

# Half-width (meters, from world origin) the navmesh bake should cover
@export var worldSize: float = 500.0

# Off by default: navmeshes are baked before runtime
@export var auto_rebake_navmesh: bool = false

var citizens = []

# id (String) -> {"node": Node3D, "body": Node3D, "obstacle": NavigationObstacle3D,
#                 "structure_index": int, "position": Vector3, "rotation_y": float}
var placed_structures: Dictionary = {}

var buildings: Dictionary = {} # id (String) -> BuildingInstance, for placed HOUSE/SHOP/WORKPLACE structures

var construction_sites: Dictionary = {} # id (String) -> ConstructionSite, for structures still being built
var construction_visuals: Dictionary = {} # id (String) -> { "ghost": Node3D, "bar": ProgressIndicator3D }

const TREE_COLLISION_LAYER := 2 # deliberately NOT layer 1 -- see nav_region.geometry_collision_mask in _bake_nav()
const TREE_OBSTACLE_RADIUS := 0.5
const TREE_OBSTACLE_HEIGHT := 5.0

const ProgressIndicatorScene := preload("res://scenes/progress_indicator_3d.tscn")
const ConstructionTileScene := preload("res://models/primitive/construction.scn")
const LogScene := preload("res://models/primitive/log.scn")
const ResourcePropScript := preload("res://scripts/resource_prop.gd")

const GAME_FONT := preload("res://fonts/lilita_one_regular.ttf")

const SFX_PLACE := "sounds/placement-a.ogg, sounds/placement-b.ogg, sounds/placement-c.ogg, sounds/placement-d.ogg"
const SFX_REMOVE := "sounds/removal-a.ogg, sounds/removal-b.ogg, sounds/removal-c.ogg, sounds/removal-d.ogg"

# Dedicated meshes for a resource type's physics prop, when one exists.
var _resource_prop_scenes: Dictionary = {
	"wood": LogScene,
}

# Mass for a placeholder resource prop's RigidBody3D
const RESOURCE_PROP_MASS := 0.25

const GHOST_BAR_HEIGHT := 1.5 # local Y offset above a construction ghost's origin
const GATHER_BAR_HEIGHT := 0.8 # local Y offset above a gathered tree's origin
const PROGRESS_BAR_VISIBLE_DISTANCE := 8.0

var gather_visuals: Dictionary = {} # id (String) -> ProgressIndicator3D, for trees actively being chopped
var gather_progress: Dictionary = {} # id (String) -> 0.0-1.0 persisted chop progress

var plane: Plane # Used for raycasting mouse

var interact_mode: bool = false  # Toggle between building and movement modes

# Freeform placement tuning
const NO_ID := ""
const PLACEMENT_MIN_CLEARANCE := 1.0 # min distance from any existing placed structure to allow a new one
const DEMOLISH_REACH := 2.0 # max distance from raycast hit to a placed structure for demolish to find it

# Pathfinding perf vars
var _nav_bake_pending := false
var _nav_bake_timer := 0.0
const NAV_BAKE_DELAY := 0.3  # seconds to wait for more changes before baking

# UI
var hotbar_page: int = 0  # which page of 10 structure slots the player is on

var resource_ui_layer: CanvasLayer = null
var build_hint_label: Label = null # transient warnings (e.g. "not enough wood")
var build_hint_timer: float = 0.0
const BUILD_HINT_DURATION := 3.0 # seconds a build hint stays visible

var _id_counter := 0

func _ready():

	add_to_group("builder")
	Globals.register_builder(self)

	map = DataMap.new()
	plane = Plane(Vector3.UP, Vector3.ZERO)

	update_structure()
	_build_hint_ui()

	# Start in movement mode (no build cursor)
	selector_container.visible = false
	selector.visible = false

	# Deferred: spawning citizens and the initial nav bake trigger are both one-time
	# setup costs that used to land in this same _ready() frame alongside every OTHER
	# node's own _ready()-time setup (both TerrainChunkLoaders' first catch-up sweep,
	# TerrainOccluderSetup's mesh build) -- Godot calls every node's _ready() within the
	# same frame during scene entry, so all of that was stacking into one frame-1 spike.
	# Awaiting a frame first spreads this node's share of that cost onto frame 2 instead.
	await get_tree().process_frame
	spawn_citizens(5)

	# Without this, the navmesh stays empty (see _bake_nav()) until the player places or
	# removes their first building -- citizens would just wander in place, unable to path
	# anywhere, from the moment they spawn. Only actually fires if auto_rebake_navmesh is
	# on (see _request_nav_bake()) -- otherwise this is a no-op and your editor-baked
	# navmesh is left alone.
	_request_nav_bake()

func _generate_id() -> String:
	_id_counter += 1
	return "s_%d_%d" % [Time.get_ticks_usec(), _id_counter]

# Returns [shape, transform] for a structure scene: its own CollisionShape3D if
# it has one, otherwise a convex hull built from its meshes.
func get_collision_shape_from_scene(scene: PackedScene) -> Array:
	var inst := scene.instantiate()
	add_child(inst)

	# First: look for an explicitly named collision node as placed in editor
	var cs := inst.find_child("CollisionShape3D", true, false)
	if cs != null and cs is CollisionShape3D:
		var shape = (cs as CollisionShape3D).shape
		var xform = inst.global_transform.affine_inverse() * (cs as CollisionShape3D).global_transform
		inst.queue_free()
		return [shape, xform]

	var faces := PackedVector3Array()
	for child in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var relative_xform = inst.global_transform.affine_inverse() * mi.global_transform
		for v in mi.mesh.get_faces():
			faces.append(relative_xform * v)

	inst.queue_free()

	if faces.is_empty():
		return [BoxShape3D.new(), Transform3D()] # no mesh geometry found -- shouldn't normally happen

	var convex := ConvexPolygonShape3D.new()
	convex.points = faces
	return [convex, Transform3D()]

# Generic runtime-collision helper: wraps get_collision_shape_from_scene()'s
# fallback AABB-box baking into a ready-to-place StaticBody3D. Works for ANY
# PackedScene lacking its own CollisionShape3D
func _build_trimesh_collision_body(scene: PackedScene) -> StaticBody3D:
	var result = get_collision_shape_from_scene(scene)
	var shape = result[0]
	var xform = result[1]

	var body := StaticBody3D.new()
	var collider := CollisionShape3D.new()
	collider.shape = shape
	collider.transform = xform
	body.add_child(collider)
	return body

func _bake_nav():
	if nav_region == null or nav_region.navigation_mesh == null:
		return

	nav_region.navigation_mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	# Layer 1: ground layer
	nav_region.navigation_mesh.geometry_collision_mask = 1

	var half_extent = worldSize + 1.0  # small margin past the playable area
	if half_extent <= 1.0:
		half_extent = _estimate_world_half_extent() + 1.0
	nav_region.navigation_mesh.filter_baking_aabb = AABB(
		Vector3(-half_extent, -2.0, -half_extent),
		Vector3(half_extent * 2.0, 4.0, half_extent * 2.0)
	)

	# on_thread=true bakes off the main thread and only touches the navmesh once done,
	# so a rebake triggered by chunk streaming doesn't stall gameplay for a frame.
	nav_region.bake_navigation_mesh(true)

func _estimate_world_half_extent() -> float:
	if nav_region == null:
		return 250.0
	var terrain := _find_terrain_manager(nav_region)
	if terrain == null or not ("world_chunks" in terrain):
		return 250.0
	var meters_per_chunk: float = float(terrain.chunk_size) * terrain.cell_size
	return max(terrain.world_chunks.x, terrain.world_chunks.y) * meters_per_chunk * 0.5

func _find_terrain_manager(root: Node) -> Node:
	if root is LowPolyTerrainManager:
		return root
	for child in root.get_children():
		var found := _find_terrain_manager(child)
		if found:
			return found
	return null

# Resolves and caches the scene's LowPolyTerrainManager the first time it's needed,
# searching from the current scene root rather than nav_region (which isn't always
# wired up) -- same pattern as TerrainChunkLoader._find_terrain_manager().
func _get_terrain_manager() -> Node:
	if not _terrain_lookup_done:
		_terrain_lookup_done = true
		_terrain_manager = _find_terrain_manager(get_tree().current_scene)
	return _terrain_manager

# Snaps a flat y=0-plane raycast hit onto the real terrain surface. Building used to
# place everything on a flat plane (see action_build's old comment); now that the
# world has real LowPolyTerrain geometry, structures/the selector need to follow
# actual ground height instead of floating at y=0 or burying into hills.
func _get_terrain_height(pos: Vector3) -> float:
	var terrain := _get_terrain_manager()
	if terrain == null:
		return pos.y
	if terrain.has_method("is_inside_terrain") and not terrain.is_inside_terrain(pos.x, pos.z):
		return pos.y # outside the authored terrain -- leave whatever height the plane gave us
	if terrain.has_method("get_height_at_world_position"):
		return terrain.get_height_at_world_position(pos)
	return pos.y

# Public entry point so anything else that changes the walkable world -- placing/removing
# a structure, or a terrain chunk streaming in/out (see TerrainChunkLoader) -- can ask for
# a rebake without duplicating the debounce logic below.
func request_nav_bake() -> void:
	_request_nav_bake()

func _request_nav_bake():
	# Single choke point for every automatic rebake trigger (initial _ready() call,
	# structure placement/removal, map load, terrain chunk streaming). All of them just
	# call this/request_nav_bake() unconditionally -- gating here means nobody else needs
	# to remember the toggle exists. Off by default: see auto_rebake_navmesh's doc comment.
	# Your editor-baked navmesh (with hand-tuned agent settings that correctly exclude the
	# riverbank) is left completely alone unless this is switched on.
	if not auto_rebake_navmesh:
		return
	_nav_bake_pending = true
	_nav_bake_timer = NAV_BAKE_DELAY

func _process(delta):

	# Controls
	action_interact_mode() # Toggle between building and movement modes
	action_rotate() # Rotates selection 90 degrees
	action_structure_toggle() # Toggles between structures

	action_save() # Saving
	action_load() # Loading

	# Freeform placement position based on mouse -- raycasts against the y=0
	# plane to get X/Z, then _get_terrain_height() below re-snaps Y onto the
	# real LowPolyTerrain surface via get_height_at_world_position()/
	# is_inside_terrain(), so placement follows actual ground height instead
	# of a flat plane.
	var world_position = plane.intersects_ray(
		view_camera.project_ray_origin(get_viewport().get_mouse_position()),
		view_camera.project_ray_normal(get_viewport().get_mouse_position()))

	if world_position == null:
		return

	world_position.y = _get_terrain_height(world_position)

	# Only show selector and process building in building mode
	if interact_mode:
		selector.position = lerp(selector.position, world_position, min(delta * 40, 1.0))
		action_build(world_position)
		action_demolish(world_position)

	if _nav_bake_pending:
		_nav_bake_timer -= delta
		if _nav_bake_timer <= 0.0:
			_nav_bake_pending = false
			_bake_nav()

	_process_construction(delta)
	_update_progress_bar_visibility()

	if build_hint_timer > 0.0:
		build_hint_timer -= delta
		if build_hint_timer <= 0.0:
			if build_hint_label != null:
				build_hint_label.visible = false

# --- Freeform structure spawning ------------------------------------------

# Instantiates structure.model at a free world position/rotation, gives it
# real collision (or a tree-style blocker+obstacle if gatherable), registers
# it in placed_structures, and returns its new id.
func _spawn_structure_instance(structure_index: int, pos: Vector3, rotation_y: float) -> String:
	if structure_index < 0 or structure_index >= structures.size():
		return NO_ID

	var structure := structures[structure_index]
	var id := _generate_id()

	var model_inst: Node3D = structure.model.instantiate()
	add_child(model_inst)
	model_inst.position = pos
	model_inst.rotation.y = rotation_y

	var entry := {
		"node": model_inst,
		"body": null,
		"obstacle": null,
		"structure_index": structure_index,
		"position": pos,
		"rotation_y": rotation_y,
	}

	if structure.gatherable:
		# No floor collision needed -- the LowPolyTerrain mesh owns the ground.
		# Just a physical blocker + live nav avoidance, same trick as the old
		# per-cell tree obstacle system, keyed by id/position instead.
		var sh_result = get_collision_shape_from_scene(structure.model)
		var body := StaticBody3D.new()
		body.collision_layer = TREE_COLLISION_LAYER
		body.collision_mask = 0
		var collider := CollisionShape3D.new()
		collider.shape = sh_result[0]
		collider.transform = sh_result[1]
		body.add_child(collider)
		add_child(body)
		body.position = pos
		body.rotation.y = rotation_y

		var obstacle := NavigationObstacle3D.new()
		obstacle.radius = TREE_OBSTACLE_RADIUS
		obstacle.height = TREE_OBSTACLE_HEIGHT
		obstacle.avoidance_enabled = true
		add_child(obstacle)
		obstacle.position = pos

		entry["body"] = body
		entry["obstacle"] = obstacle
	else:
		# Real static collision -- blocks movement AND gets baked into the
		# navmesh (layer 1, see _bake_nav()).
		var body := _build_trimesh_collision_body(structure.model)
		add_child(body)
		body.position = pos
		body.rotation.y = rotation_y
		entry["body"] = body

		var is_housing = structure.type == Structure.Type.HOUSE or structure.type == Structure.Type.SHOP
		var is_workplace = structure.type == Structure.Type.WORKPLACE
		if is_housing or is_workplace:
			var instance := BuildingInstance.new()
			instance.id = id
			instance.structure_index = structure_index
			buildings[id] = instance

		_request_nav_bake()

	placed_structures[id] = entry
	return id

# Removes a placed structure entirely (node, collision, obstacle, and any
# BuildingInstance tracking it).
func remove_structure_instance(id: String) -> void:
	if not placed_structures.has(id):
		return
	var entry = placed_structures[id]
	var structure_index: int = entry["structure_index"]
	var was_building := structure_index >= 0 and structure_index < structures.size() and not structures[structure_index].gatherable

	if entry["node"]:
		entry["node"].queue_free()
	if entry["body"]:
		entry["body"].queue_free()
	if entry["obstacle"]:
		entry["obstacle"].queue_free()

	placed_structures.erase(id)
	buildings.erase(id)

	if was_building:
		_request_nav_bake()

func get_structure_index(id: String) -> int:
	if not placed_structures.has(id):
		return -1
	return placed_structures[id]["structure_index"]

func get_structure_position(id: String) -> Vector3:
	if not placed_structures.has(id):
		return Vector3.INF
	return placed_structures[id]["position"]

# Nearest placed structure to world_pos within max_dist, or NO_ID. Used by
# demolish and by click-to-assign (CitizenSelector).
func get_structure_at_point(world_pos: Vector3, max_dist: float) -> String:
	var nearest_id := NO_ID
	var nearest_dist := max_dist * max_dist
	for id in placed_structures.keys():
		var dist = world_pos.distance_squared_to(placed_structures[id]["position"])
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = id
	return nearest_id

# Build (place) a structure

func action_build(world_position: Vector3):
	if Input.is_action_just_pressed("build"):

		if structures.is_empty():
			return # nothing selectable -- see update_structure()'s guard

		var place_pos := Vector3(round(world_position.x), world_position.y, round(world_position.z))

		# Clearance check -- freeform has no "tile" to compare against, so
		# just refuse if something's already too close.
		var blocking_id := get_structure_at_point(place_pos, PLACEMENT_MIN_CLEARANCE)
		if blocking_id != NO_ID:
			_flash_build_hint("Too close to something else.")
			return
		if _construction_site_near(place_pos, PLACEMENT_MIN_CLEARANCE) != NO_ID:
			_flash_build_hint("A site is already under construction there.")
			return

		_warn_if_insufficient_resources(structures[index])
		_start_construction(place_pos, selector.rotation.y, index)

		Audio.play(SFX_PLACE, -20)

func _construction_site_near(pos: Vector3, max_dist: float) -> String:
	for id in construction_sites.keys():
		if construction_sites[id].position.distance_to(pos) <= max_dist:
			return id
	return NO_ID

# Flashes a heads-up if the stockpile can't currently cover the full build cost
func _warn_if_insufficient_resources(structure: Structure) -> void:
	var missing: Array[String] = []
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var available: int = map.stockpile.get(resource_type, 0)
		if available < needed:
			missing.append("%s (%d/%d)" % [String(resource_type).capitalize(), available, needed])
	if not missing.is_empty():
		_flash_build_hint("Not enough resources yet -- site will wait for: " + ", ".join(missing))

# Demolish (remove) a structure

func action_demolish(world_position: Vector3):
	if Input.is_action_just_pressed("demolish"):
		var site_id := _construction_site_near(world_position, DEMOLISH_REACH)
		if site_id != NO_ID:
			construction_sites.erase(site_id)
			_clear_construction_visual(site_id)
			Audio.play(SFX_REMOVE, -20)
			return

		var id := get_structure_at_point(world_position, DEMOLISH_REACH)
		if id != NO_ID:
			remove_structure_instance(id)
			Audio.play(SFX_REMOVE, -20)

# Toggle between building mode and movement mode

func action_interact_mode():
	if InputMap.has_action("interact_mode") and Input.is_action_just_pressed("interact_mode"):
		interact_mode = !interact_mode
		selector_container.visible = interact_mode
		selector.visible = interact_mode
		if Audio:
			Audio.play("sounds/toggle.ogg", -30)

# Rotates the 'cursor' 90 degrees

func action_rotate():
	if Input.is_action_just_pressed("rotate"):
		selector.rotate_y(deg_to_rad(90))

		Audio.play("sounds/rotate.ogg", -30)

# Toggle between structures to build

func action_structure_toggle():
	# Direct hotbar select: keys 1-9, 0 map to slots 0-9 of the current page
	var page_count = ceili(float(structures.size()) / 10.0)
	var previous_index := index
	for i in range(10):
		if Input.is_action_just_pressed("selection_%d" % i):
			var target = hotbar_page * 10 + i
			if target < structures.size():
				index = target
				Audio.play("sounds/toggle.ogg", -30)

	# Page through the hotbar when there are more than 10 structures
	if Input.is_action_just_pressed("hotbar_page_next"):
		hotbar_page = wrap(hotbar_page + 1, 0, page_count)
		Audio.play("sounds/toggle.ogg", -30)

	if Input.is_action_just_pressed("hotbar_page_prev"):
		hotbar_page = wrap(hotbar_page - 1, 0, page_count)
		Audio.play("sounds/toggle.ogg", -30)

	# Only rebuild the preview when the selection actually changed
	if index != previous_index:
		update_structure()

# Update the structure visual in the 'cursor'

func update_structure():
	# Guard against an empty/corrupt structures array (e.g. a scene resource with a
	# broken ext_resource dependency silently dropping entries) -- previously this
	# indexed straight into structures[index] and crashed with an out-of-bounds
	# error the moment _ready() called this with nothing to preview.
	if structures.is_empty():
		push_warning("Builder: structures array is empty -- nothing to build/preview. Check for broken resource references on the Builder node.")
		return
	index = clampi(index, 0, structures.size() - 1)

	# Clear previous structure preview in selector
	for n in selector_container.get_children():
		selector_container.remove_child(n)
		n.queue_free()

	# Create new structure preview in selector
	var _model = structures[index].model.instantiate()
	selector_container.add_child(_model)
	_model.position.y += 0.25

# --- Resource stockpile UI -------------------------------------------------

func _build_hint_ui() -> void:
	resource_ui_layer = CanvasLayer.new()
	add_child(resource_ui_layer)

	build_hint_label = Label.new()
	_apply_game_font(build_hint_label, 24)
	build_hint_label.add_theme_color_override("font_color", Color(0.95, 0.55, 0.35))
	build_hint_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	build_hint_label.add_theme_constant_override("shadow_offset_x", 2)
	build_hint_label.add_theme_constant_override("shadow_offset_y", 2)
	build_hint_label.position = Vector2(20, 140)
	build_hint_label.visible = false
	resource_ui_layer.add_child(build_hint_label)

func _apply_game_font(label: Label, size: int) -> void:
	label.add_theme_font_override("font", GAME_FONT)
	label.add_theme_font_size_override("font_size", size)

func _flash_build_hint(text: String) -> void:
	if build_hint_label != null:
		build_hint_label.text = text
		build_hint_label.visible = true
	build_hint_timer = BUILD_HINT_DURATION

# --- Saving/load -----------------------------------------------------------
# Ids are NOT persisted -- they're regenerated fresh on load/respawn, since
# nothing outside a single session references a saved id.

func action_save():
	if Input.is_action_just_pressed("save"):
		print("Saving map...")

		map.structures.clear()
		for id in placed_structures.keys():
			var entry = placed_structures[id]

			var data_structure := DataStructure.new()
			data_structure.position = entry["position"]
			data_structure.rotation_y = entry["rotation_y"]
			data_structure.structure = entry["structure_index"]

			map.structures.append(data_structure)

		ResourceSaver.save(map, "user://map.res")

		print("Map saved.")

func action_load():
	if Input.is_action_just_pressed("load"):
		print("Loading map...")

		_load_from(ResourceLoader.load("user://map.res"))

		print("Map loaded.")

func _load_from(loaded_map: DataMap) -> void:
	_clear_all_placed_structures()

	map = loaded_map
	if not map:
		map = DataMap.new()

	for data_structure in map.structures:
		_spawn_structure_instance(data_structure.structure, data_structure.position, data_structure.rotation_y)

	if nav_region != null:
		_request_nav_bake()

func _clear_all_placed_structures() -> void:
	for id in placed_structures.keys().duplicate():
		remove_structure_instance(id)

func spawn_citizens(count: int):
	for i in count:
		var c = citizen_scene.instantiate()
		add_child(c)
		# Spawn around player
		c.global_position = Globals.get_player_position() + Vector3(randi_range(-10, 10), 0, randi_range(-10, 10))
		citizens.append(c)

# --- Building occupancy (housing / jobs) ---------------------------------

# --- Resource gathering ----------------------------------

# Finds the nearest gatherable structure (e.g. a tree) to a world position.
func get_nearest_gatherable(pos: Vector3) -> String:
	var nearest_id := NO_ID
	var nearest_dist := INF

	for id in placed_structures.keys():
		var entry = placed_structures[id]
		var structure_index: int = entry["structure_index"]
		if structure_index < 0 or structure_index >= structures.size():
			continue
		if not structures[structure_index].gatherable:
			continue

		var dist = pos.distance_squared_to(entry["position"])
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = id

	return nearest_id

# Removes a fully-gathered structure (per design: chopping is permanent,
# player must replant).
func gather_resource_at(id: String) -> void:
	if not placed_structures.has(id):
		return
	var structure_index: int = placed_structures[id]["structure_index"]
	if structure_index < 0 or structure_index >= structures.size():
		return
	if not structures[structure_index].gatherable:
		return

	clear_chop_progress(id)
	remove_structure_instance(id)

func deposit_resources(resources: Dictionary) -> void:
	if resources.is_empty():
		return
	for key in resources.keys():
		map.stockpile[key] = map.stockpile.get(key, 0) + resources[key]

func spawn_resource_prop(world_pos: Vector3, resource_type: String, amount: int = 1) -> void:
	if resource_type == "" or amount <= 0:
		return

	var prop: Node
	if _resource_prop_scenes.has(resource_type):
		prop = _resource_prop_scenes[resource_type].instantiate()
		if not prop is RigidBody3D:
			push_error("spawn_resource_prop: %s's root isn't a RigidBody3D -- can't use it as a physics prop" % _resource_prop_scenes[resource_type].resource_path)
			prop.queue_free()
			return
	else:
		var placeholder := RigidBody3D.new()
		placeholder.mass = RESOURCE_PROP_MASS
		var mesh_instance := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		sphere.radius = 0.15
		sphere.height = 0.3
		mesh_instance.mesh = sphere
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.85, 0.25, 0.2) if resource_type == "food" else Color(0.7, 0.7, 0.7)
		mesh_instance.set_surface_override_material(0, mat)
		placeholder.add_child(mesh_instance)
		var collider := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(0.3, 0.3, 0.3)
		collider.shape = shape
		placeholder.add_child(collider)
		prop = placeholder

	prop.set_script(ResourcePropScript)
	prop.add_to_group("resource_prop")
	prop.set_meta("resource_type", resource_type)
	prop.set_meta("amount", amount)
	prop.set_meta("builder", self)

	add_child(prop)
	prop.global_position = world_pos + Vector3(randf_range(-0.4, 0.4), 0.6, randf_range(-0.4, 0.4))
	prop.rotation = Vector3(randf_range(0, TAU), randf_range(0, TAU), randf_range(0, TAU))

# --- Construction pipeline ------------------------------------------

func _start_construction(pos: Vector3, rotation_y: float, structure_index: int) -> void:
	var site := ConstructionSite.new()
	site.id = _generate_id()
	site.position = pos
	site.rotation_y = rotation_y
	site.structure_index = structure_index
	construction_sites[site.id] = site

	_spawn_construction_visual(site.id, pos, structures[structure_index], rotation_y)

func _process_construction(delta: float) -> void:
	if construction_sites.is_empty():
		return

	var completed_ids: Array[String] = []

	for id in construction_sites.keys():
		var site: ConstructionSite = construction_sites[id]
		var structure := structures[site.structure_index]

		_commit_resources(site, structure)

		var fully_committed := _resources_fully_committed(site, structure)
		if construction_visuals.has(id):
			var bar: ProgressIndicator3D = construction_visuals[id]["bar"]
			if fully_committed:
				bar.set_bar_color(Color(0.6, 0.6, 0.65)) # neutral grey-blue -- resourced
			else:
				bar.set_bar_color(Color(0.85, 0.35, 0.25)) # stalled -- missing resources

		if not fully_committed:
			continue # waiting on the stockpile -- builders stand by, no progress yet

		if site.assigned_builders.is_empty():
			continue # no labor assigned yet -- nothing progresses on its own

		var builders_in_range := _count_builders_in_range(site)
		if builders_in_range <= 0:
			continue # assigned, but nobody has physically arrived yet

		var labor := float(builders_in_range) * delta
		site.progress = clamp(site.progress + labor / max(structure.build_time, 0.01), 0.0, 1.0)

		if construction_visuals.has(id):
			construction_visuals[id]["bar"].set_progress(site.progress)

		if site.is_complete():
			completed_ids.append(id)

	for id in completed_ids:
		_complete_construction(id)

const BUILD_LABOR_REACH := 1.5 # how close a citizen builder must stand to contribute labor
const PLAYER_WORK_REACH := 15.0 # player gathers/builds from camera distance, so a much longer reach
const PLAYER_BUILDER_ID := "player_builder" # id the player registers under in ConstructionSite.assigned_builders (can't collide with 6-digit citizen ids)

func _count_builders_in_range(site: ConstructionSite) -> int:
	var count := 0
	for builder_id in site.assigned_builders:
		var node: Node3D = null
		if builder_id == PLAYER_BUILDER_ID:
			node = Globals.player
		else:
			for c in citizens:
				if is_instance_valid(c) and c.data != null and c.data.id == builder_id:
					node = c
					break
		if node == null or not is_instance_valid(node):
			continue
		var reach := PLAYER_WORK_REACH if builder_id == PLAYER_BUILDER_ID else BUILD_LABOR_REACH
		if node.global_position.distance_to(site.position) <= reach:
			count += 1
	return count

func _commit_resources(site: ConstructionSite, structure: Structure) -> void:
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var already: int = site.resources_committed.get(resource_type, 0)
		if already >= needed:
			continue

		var available: int = map.stockpile.get(resource_type, 0)
		var to_draw: int = min(needed - already, available)
		if to_draw <= 0:
			continue

		map.stockpile[resource_type] = available - to_draw
		site.resources_committed[resource_type] = already + to_draw

func _resources_fully_committed(site: ConstructionSite, structure: Structure) -> bool:
	for resource_type in structure.build_cost.keys():
		var needed: int = structure.build_cost[resource_type]
		var committed: int = site.resources_committed.get(resource_type, 0)
		if committed < needed:
			return false
	return true

func _complete_construction(id: String) -> void:
	var site: ConstructionSite = construction_sites[id]
	construction_sites.erase(id)

	_clear_construction_visual(id)
	_spawn_structure_instance(site.structure_index, site.position, site.rotation_y)

	Audio.play(SFX_PLACE, -20)

# Finds the nearest active construction site to a world position
func get_nearest_construction_site(pos: Vector3) -> String:
	var nearest_id := NO_ID
	var nearest_dist := INF

	for id in construction_sites.keys():
		var dist = pos.distance_squared_to(construction_sites[id].position)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = id

	return nearest_id

func assign_builder_to_site(citizen_id: String, site_id: String) -> bool:
	if not construction_sites.has(site_id):
		return false
	release_builder(citizen_id)
	var site: ConstructionSite = construction_sites[site_id]
	if not citizen_id in site.assigned_builders:
		site.assigned_builders.append(citizen_id)
	return true

func release_builder(citizen_id: String) -> void:
	for site in construction_sites.values():
		site.assigned_builders.erase(citizen_id)

# Called from citizen.gd's _exit_tree() when a citizen is freed. Previously this had no
# home on Builder at all -- citizen.gd was calling builder.release_citizen(data.id) behind
# an `if builder.has_method(...)` guard that silently no-op'd forever, so freed citizens
# never left `citizens`, never got dropped from any site's assigned_builders, and never
# vacated housing -- a slow leak of stale entries that just happened to mostly go
# unnoticed because is_instance_valid() checks elsewhere quietly skip them.
func release_citizen(citizen_id: String) -> void:
	release_builder(citizen_id)
	for instance in buildings.values():
		instance.residents.erase(citizen_id)
	for i in range(citizens.size() - 1, -1, -1):
		var c = citizens[i]
		if not is_instance_valid(c) or (c.data != null and c.data.id == citizen_id):
			citizens.remove_at(i)

# --- Construction & gather progress visuals --------------------------------

func _spawn_construction_visual(id: String, pos: Vector3, structure: Structure, rotation_y: float) -> void:
	var ghost := structure.model.instantiate()
	ghost.position = pos
	ghost.rotation.y = rotation_y
	add_child(ghost)
	_apply_ghost_material(ghost)

	var construction := ConstructionTileScene.instantiate()
	construction.position = pos
	construction.rotation.y = rotation_y
	add_child(construction)

	var tile_body := _build_trimesh_collision_body(ConstructionTileScene)
	tile_body.position = pos
	tile_body.rotation.y = rotation_y
	add_child(tile_body)

	var bar: ProgressIndicator3D = ProgressIndicatorScene.instantiate()
	add_child(bar)
	bar.position = pos + Vector3(0, GHOST_BAR_HEIGHT, 0)
	bar.bar_color = Color(0.6, 0.6, 0.65)
	bar.set_progress(0.0)

	construction_visuals[id] = {"ghost": ghost, "construction": construction, "tile_body": tile_body, "bar": bar}

func _apply_ghost_material(node: Node) -> void:
	var ghost_material := StandardMaterial3D.new()
	ghost_material.albedo_color = Color(0.5, 0.5, 0.5, 0.45)
	ghost_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ghost_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_apply_material_recursive(node, ghost_material)

func _apply_material_recursive(node: Node, material: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		var mesh_instance := node as MeshInstance3D
		for surface in mesh_instance.mesh.get_surface_count():
			mesh_instance.set_surface_override_material(surface, material)
	if node is CollisionShape3D or node is CollisionObject3D:
		node.queue_free()
		return
	for child in node.get_children():
		_apply_material_recursive(child, material)

func _clear_construction_visual(id: String) -> void:
	if not construction_visuals.has(id):
		return
	var visual = construction_visuals[id]
	visual["ghost"].queue_free()
	visual["construction"].queue_free()
	visual["tile_body"].queue_free()
	visual["bar"].queue_free()
	construction_visuals.erase(id)

func update_gather_progress(id: String, progress01: float) -> void:
	if not gather_visuals.has(id):
		var bar: ProgressIndicator3D = ProgressIndicatorScene.instantiate()
		add_child(bar)
		var pos = get_structure_position(id)
		bar.position = pos + Vector3(0, GATHER_BAR_HEIGHT, 0)
		bar.bar_color = Color(0.8, 0.4, 0.1) # matches citizen HungerBar orange
		gather_visuals[id] = bar
	gather_visuals[id].set_progress(progress01)

func clear_gather_progress(id: String) -> void:
	if not gather_visuals.has(id):
		return
	gather_visuals[id].queue_free()
	gather_visuals.erase(id)

# --- Chop progress (persisted) ---------------------------------------------

func add_chop_progress(id: String, amount: float) -> Dictionary:
	if not placed_structures.has(id):
		return {"completed": false, "energy_bonus": 0.0}
	var structure_index: int = placed_structures[id]["structure_index"]
	if structure_index < 0 or structure_index >= structures.size():
		return {"completed": false, "energy_bonus": 0.0}
	var structure = structures[structure_index]
	if not structure.gatherable:
		return {"completed": false, "energy_bonus": 0.0}

	var previous_progress: float = gather_progress.get(id, 0.0)
	var progress = clamp(previous_progress + amount, 0.0, 1.0)
	gather_progress[id] = progress
	update_gather_progress(id, progress)

	_spawn_incremental_resource_props(id, structure, previous_progress, progress)

	if progress >= 1.0:
		var energy_bonus := 0.0
		if randf() < structure.food_chance:
			energy_bonus = structure.food_energy_bonus
		gather_resource_at(id)
		return {"completed": true, "energy_bonus": energy_bonus}
	return {"completed": false, "energy_bonus": 0.0}

func _spawn_incremental_resource_props(id: String, structure: Structure, prev_progress: float, new_progress: float) -> void:
	if structure.resource_type == "" or structure.resource_yield <= 0:
		return
	var world_pos = get_structure_position(id)
	var prev_units = floori(prev_progress * structure.resource_yield)
	var new_units = floori(new_progress * structure.resource_yield)
	for i in range(new_units - prev_units):
		spawn_resource_prop(world_pos, structure.resource_type, 1)

func clear_chop_progress(id: String) -> void:
	gather_progress.erase(id)
	clear_gather_progress(id)

# Distance-gates every active progress bar against the player each frame
func _update_progress_bar_visibility() -> void:
	if not Globals.player:
		return
	var player_pos = Globals.player.global_position

	for visual in construction_visuals.values():
		var bar: ProgressIndicator3D = visual["bar"]
		var in_range = bar.global_position.distance_to(player_pos) < PROGRESS_BAR_VISIBLE_DISTANCE
		bar.set_visible_in_range(in_range)

	for bar in gather_visuals.values():
		var in_range = bar.global_position.distance_to(player_pos) < PROGRESS_BAR_VISIBLE_DISTANCE
		bar.set_visible_in_range(in_range)
