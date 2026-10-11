extends Node3D
class_name CitizenSelector

## Click a citizen to see their full stats in a panel and select them for assignment
## With a citizen selected, click another object to assign them there manually

@export var view_camera: Camera3D
@export var max_select_distance: float = 100.0
@export var panel_offset: Vector2 = Vector2(40, -60)  # offset from citizen's screen pos to panel's top-left
@export var ring_color: Color = Color(1.0, 0.85, 0.2)
@export var click_assist_pixels: float = 40.0 # if the raycast misses, select the nearest citizen/player within this many screen pixels of the click instead -- citizens are small, constantly-moving targets

var selected_citizen: Node3D = null
var panel: PanelContainer
var name_label: Label
var id_label: Label
var stats_label: RichTextLabel
var bars_box: VBoxContainer
var hostile_label: Label
var _bar_rows: Dictionary = {} # stat name -> {row, bar, fill, value}
var assign_hint_label: Label
var ui_layer: CanvasLayer
var ring: MeshInstance3D
var builder: Node = null

const GAME_FONT := preload("res://fonts/lilita_one_regular.ttf")

func _ready() -> void:
	add_to_group("citizen_selector")
	_build_ui()
	_build_ring()
	# Try to auto-find the camera if not assigned, so this works even if you
	# forget to wire it up in the Inspector.
	if view_camera == null:
		var view_node = get_tree().get_first_node_in_group("view")
		if view_node and view_node.has_node("Camera"):
			view_camera = view_node.get_node("Camera")
	
	builder = Globals.builder

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Building mode owns left-click for placement/demolition (the "build"
		# input action is also bound to it) -- don't also try to select/assign
		# citizens while placing structures.
		if builder != null and builder.interact_mode:
			return
		_try_select_at(event.position)

func _try_select_at(screen_pos: Vector2) -> void:
	if view_camera == null:
		return
	
	var space_state = get_world_3d().direct_space_state
	var from = view_camera.project_ray_origin(screen_pos)
	var to = from + view_camera.project_ray_normal(screen_pos) * max_select_distance
	
	var query = PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_bodies = true
	var result = space_state.intersect_ray(query)
	
	if result and result.collider and (result.collider.is_in_group("citizen") or result.collider.is_in_group("player")):
		if selected_citizen == result.collider:
			_deselect()
		else:
			_select(result.collider)
		get_viewport().set_input_as_handled()
		return
	
	# Raycast missed (or hit something else in front of a moving citizen) --
	# fall back to the nearest citizen/player on screen within click_assist_pixels.
	var assist_target = _find_nearest_on_screen(screen_pos)
	if assist_target:
		if selected_citizen == assist_target:
			_deselect()
		else:
			_select(assist_target)
		get_viewport().set_input_as_handled()
		return
	
	# Not a citizen/player -- if we have a CITIZEN selected (not the player --
	# the player isn't assignable to anything), see if the click landed on a
	# building/tree/site cell. This is the manual assignment path (A.3).
	if selected_citizen and is_instance_valid(selected_citizen) and not selected_citizen.is_in_group("player") and result and result.has("position"):
		if _try_assign_at_world_position(result.position):
			get_viewport().set_input_as_handled()
			return
	
	_deselect()

## Nearest citizen/player to a screen position within click_assist_pixels, or null.
## Citizens behind the camera are skipped (unproject_position is meaningless there).
func _find_nearest_on_screen(screen_pos: Vector2) -> Node3D:
	if view_camera == null:
		return null
	
	var candidates: Array = get_tree().get_nodes_in_group("citizen")
	if Globals.player:
		candidates.append(Globals.player)
	
	var best: Node3D = null
	var best_dist := click_assist_pixels
	
	for c in candidates:
		if not is_instance_valid(c):
			continue
		var to_c = c.global_position - view_camera.global_position
		if view_camera.global_transform.basis.z.dot(to_c) > 0:
			continue # behind the camera
		var screen = view_camera.unproject_position(c.global_position)
		var dist = screen.distance_to(screen_pos)
		if dist < best_dist:
			best_dist = dist
			best = c
	
	return best

## Resolves a world-space hit position to a placed structure or construction site id
func _try_assign_at_world_position(world_pos: Vector3) -> bool:
	if builder == null:
		return false
	
	var assigned := false
	# Construction site: assign selected citizen as a builder
	var site_id = builder.get_nearest_construction_site(world_pos)
	if site_id != builder.NO_ID and builder.construction_sites[site_id].position.distance_to(world_pos) <= 1.5:
		assigned = PolicyEngine.execute(Action.new_assign_build_task(), selected_citizen, site_id)
		_flash_assign_hint(assigned)
		_refresh_panel()
		return true
	
	# Gatherable structure (tree): assign selected citizen to gather it
	var id = builder.get_structure_at_point(world_pos, 1.5)
	if id != builder.NO_ID:
		var structure_index = builder.get_structure_index(id)
		if structure_index >= 0 and structure_index < builder.structures.size() and builder.structures[structure_index].gatherable:
			assigned = PolicyEngine.execute(Action.new_assign_gather(), selected_citizen, id)
			_flash_assign_hint(assigned)
			_refresh_panel()
			return true
	
	# Building (house/workplace): assign housing or job.
	if id == builder.NO_ID or not builder.buildings.has(id):
		return false
	
	var instance: BuildingInstance = builder.buildings[id]
	var structure: Structure = builder.structures[instance.structure_index]
	
	assigned = false
	if structure.type == Structure.Type.HOUSE or structure.type == Structure.Type.SHOP:
		assigned = PolicyEngine.execute(Action.new_assign_housing(), selected_citizen, instance)
	elif structure.type == Structure.Type.WORKPLACE:
		assigned = PolicyEngine.execute(Action.new_assign_job(), selected_citizen, instance)
	else:
		return false
	
	_flash_assign_hint(assigned)
	_refresh_panel()
	return true

func _flash_assign_hint(success: bool) -> void:
	if assign_hint_label == null:
		return
	assign_hint_label.visible = true
	assign_hint_label.text = "Assigned!" if success else "No free slot there."
	assign_hint_label.modulate = Color(0.45, 0.9, 0.45) if success else Color(0.9, 0.45, 0.45)

func _select(citizen: Node3D) -> void:
	selected_citizen = citizen
	panel.visible = true
	ring.visible = true
	if assign_hint_label:
		assign_hint_label.visible = false
	_refresh_panel()

func _deselect() -> void:
	selected_citizen = null
	panel.visible = false
	ring.visible = false

func _process(_delta: float) -> void:
	if selected_citizen and is_instance_valid(selected_citizen):
		_refresh_panel()
		_update_ring_position()
		_update_panel_position()
	elif selected_citizen:
		# Citizen was freed (e.g. removed from the world) while selected
		_deselect()

func _update_ring_position() -> void:
	# Flat ring sitting just above the ground at the citizen's feet
	ring.global_position = selected_citizen.global_position + Vector3(0, 0.05, 0)

func _update_panel_position() -> void:
	if view_camera == null:
		return
	
	var screen_pos = view_camera.unproject_position(selected_citizen.global_position)
	
	# Don't show the panel if the citizen is behind the camera
	var cam_to_citizen = selected_citizen.global_position - view_camera.global_position
	if view_camera.global_transform.basis.z.dot(cam_to_citizen) > 0:
		panel.visible = false
		return
	panel.visible = true
	
	var target_pos = screen_pos + panel_offset
	
	# Clamp so the panel stays fully on-screen even if the citizen wanders near a viewport edge
	var panel_size = panel.size if panel.size.length_squared() > 1.0 else panel.custom_minimum_size
	var viewport_size = get_viewport().get_visible_rect().size
	target_pos.x = clamp(target_pos.x, 0, viewport_size.x - panel_size.x)
	target_pos.y = clamp(target_pos.y, 0, viewport_size.y - panel_size.y)
	
	panel.position = target_pos

func _refresh_panel() -> void:
	if selected_citizen.is_in_group("player"):
		_refresh_player_panel()
		return
	
	var d = selected_citizen.data
	if d == null:
		return
	
	name_label.text = d.citizen_name if d.citizen_name != "" else "Unnamed citizen"
	id_label.text = "Citizen ID: " + d.id if d.id != "" else "No ID"
	
	var job_text = d.job if d.job != "" else "Unemployed"

	stats_label.clear()
	stats_label.append_text("[b]Age:[/b] %d\n" % d.age)
	stats_label.append_text("[b]Job:[/b] %s" % job_text)

	_begin_bars()
	_set_bar("Happiness", d.happiness, 100.0)
	_set_bar("Health", d.health, 100.0)
	_set_bar("Energy", d.energy, 100.0)
	_end_bars()

	hostile_label.visible = selected_citizen.has_method("get") and "is_chasing_player" in selected_citizen and selected_citizen.is_chasing_player
	hostile_label.text = "Hostile -- chasing player!"

# The player isn't a citizen (no CitizenData, no job/age/happiness) -- just
# show the two stats that matter to them directly: health and energy.
func _refresh_player_panel() -> void:
	name_label.text = "You"
	id_label.text = ""

	stats_label.clear()

	_begin_bars()
	_set_bar("Health", selected_citizen.health, selected_citizen.max_health)
	_set_bar("Energy", selected_citizen.energy, 100.0)
	_end_bars()
	hostile_label.visible = false

# Stat bars are real ProgressBar controls, not text. The old version drew them out of the
# block characters U+2588/U+2591, which the game font has no glyphs for; desktop quietly
# falls back to a system font, but a web export has no system fonts to fall back on, so the
# bars rendered as empty boxes.
var _bars_used: Array[String] = []

func _begin_bars() -> void:
	_bars_used.clear()

func _end_bars() -> void:
	for stat in _bar_rows:
		_bar_rows[stat].row.visible = _bars_used.has(stat)

func _set_bar(stat: String, value: float, max_value: float) -> void:
	_bars_used.append(stat)
	var entry := _get_bar_row(stat)
	var bar: ProgressBar = entry.bar
	bar.max_value = maxf(max_value, 1.0)
	bar.value = clampf(value, 0.0, bar.max_value)
	var pct := int(round(bar.value / bar.max_value * 100.0))
	entry.value.text = "%d%%" % pct
	entry.fill.bg_color = Color(0.37, 0.83, 0.37) if pct > 60 else (Color(0.88, 0.78, 0.29) if pct > 30 else Color(0.88, 0.37, 0.37))

func _get_bar_row(stat: String) -> Dictionary:
	if _bar_rows.has(stat):
		return _bar_rows[stat]

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)

	var name_label_row := Label.new()
	name_label_row.text = stat + ":"
	name_label_row.add_theme_font_override("font", GAME_FONT)
	name_label_row.add_theme_font_size_override("font_size", 22)
	name_label_row.custom_minimum_size.x = 150
	row.add_child(name_label_row)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(240, 22)
	bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(1, 1, 1, 0.12)
	bg.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", bg)
	bar.add_theme_stylebox_override("fill", fill)
	row.add_child(bar)

	var value_label := Label.new()
	value_label.add_theme_font_override("font", GAME_FONT)
	value_label.add_theme_font_size_override("font_size", 22)
	value_label.custom_minimum_size.x = 70
	row.add_child(value_label)

	bars_box.add_child(row)
	var entry := {"row": row, "bar": bar, "fill": fill, "value": value_label}
	_bar_rows[stat] = entry
	return entry

func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	add_child(ui_layer)
	
	panel = PanelContainer.new()
	panel.visible = false
	# Free-floating: top-left anchored at (0,0,0,0) so `panel.position` directly
	# controls where it sits on screen -- this is what lets it follow the
	# citizen instead of staying pinned to a screen corner.
	panel.anchor_left = 0.0
	panel.anchor_right = 0.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.custom_minimum_size = Vector2(560, 368)  # 2x width, 2x height = 4x area vs. original 280x184
	ui_layer.add_child(panel)
	
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.07, 0.09, 0.92)
	style.border_color = ring_color
	style.set_border_width_all(3)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	
	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)
	
	name_label = Label.new()
	name_label.add_theme_font_override("font", GAME_FONT)
	name_label.add_theme_font_size_override("font_size", 32)
	vbox.add_child(name_label)
	
	id_label = Label.new()
	id_label.add_theme_font_override("font", GAME_FONT)
	id_label.add_theme_font_size_override("font_size", 22)
	vbox.add_child(id_label)
	
	var sep = HSeparator.new()
	vbox.add_child(sep)
	
	stats_label = RichTextLabel.new()
	stats_label.bbcode_enabled = true
	stats_label.fit_content = true
	stats_label.scroll_active = false
	stats_label.add_theme_font_override("normal_font", GAME_FONT)
	stats_label.add_theme_font_override("bold_font", GAME_FONT)
	stats_label.add_theme_font_size_override("normal_font_size", 22)
	stats_label.add_theme_font_size_override("bold_font_size", 22)
	stats_label.custom_minimum_size = Vector2(520, 0)
	vbox.add_child(stats_label)

	bars_box = VBoxContainer.new()
	bars_box.add_theme_constant_override("separation", 10)
	vbox.add_child(bars_box)

	hostile_label = Label.new()
	hostile_label.add_theme_font_override("font", GAME_FONT)
	hostile_label.add_theme_font_size_override("font_size", 22)
	hostile_label.add_theme_color_override("font_color", Color(1.0, 0.33, 0.33))
	hostile_label.visible = false
	vbox.add_child(hostile_label)
	
	assign_hint_label = Label.new()
	assign_hint_label.add_theme_font_override("font", GAME_FONT)
	assign_hint_label.add_theme_font_size_override("font_size", 20)
	assign_hint_label.visible = false
	vbox.add_child(assign_hint_label)

func _build_ring() -> void:
	# Flat circular outline on the ground beneath the selected citizen
	# Built from a TorusMesh flattened on Y so it reads as a ring
	var torus = TorusMesh.new()
	torus.inner_radius = 0.55
	torus.outer_radius = 0.7
	torus.rings = 24
	
	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = ring_color
	mat.emission_enabled = true
	mat.emission = ring_color
	mat.emission_energy_multiplier = 1.5
	torus.material = mat
	
	ring = MeshInstance3D.new()
	ring.mesh = torus
	ring.scale = Vector3(1.0, 0.15, 1.0)  # flatten the torus into a ground ring
	ring.visible = false
	add_child(ring)
