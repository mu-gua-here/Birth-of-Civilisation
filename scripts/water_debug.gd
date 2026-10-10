extends Node3D
class_name WaterDebug

## Debug overlay showing where the GAME thinks the fluid is (not where the shader draws it).
## Everything here is read from FluidArea3D.get_height() -- the exact function buoyancy and the
## underwater-camera check use -- so if a marker floats above/below the visible water, the
## render and the physics disagree.
##
## Toggle with F6 (debug builds only). Add as a child of Main; it finds everything else itself.
##
## Draws (all on top of the scene, no depth test):
##   cyan grid      the sampled surface around the player, one point per `grid_spacing`
##   yellow box     the OceanFluid Area3D trigger volume (NOT the water surface -- just where
##                  bodies get registered as "in fluid")
##   per-carrier    red = floater is in fluid, green = not; a line from each floater to the
##                  surface height under it, and a label with the numbers
##   HUD (top left) camera vs surface, fluid area state, water source in use

@export var enabled_on_start := false
@export var grid_half_cells := 20
@export var grid_spacing := 2.0
@export var update_hz := 20.0

const COLOR_GRID := Color(0.2, 0.9, 1.0, 0.9)
const COLOR_BOX := Color(1.0, 0.85, 0.1, 0.9)
const COLOR_EFFECTIVE := Color(1.0, 0.3, 0.9, 0.8)
const COLOR_IN := Color(1.0, 0.25, 0.25, 1.0)
const COLOR_OUT := Color(0.3, 1.0, 0.3, 1.0)

var _fluid: FluidArea3D = null
var _carriers: Array[Carrier] = []
var _rescan_timer := 0.0
var _update_timer := 0.0

var _mesh_instance: MeshInstance3D
var _material: StandardMaterial3D
var _labels: Dictionary = {} # Carrier -> Label3D
var _hud_layer: CanvasLayer
var _hud: Label


func _ready() -> void:
	process_priority = 200 # after everything that moves, so we draw this frame's positions
	if not OS.is_debug_build():
		set_process(false)
		return

	top_level = true
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.no_depth_test = true
	_material.vertex_color_use_as_albedo = true
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.render_priority = 100

	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.material_override = _material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh_instance.extra_cull_margin = 16384.0
	add_child(_mesh_instance)

	_hud_layer = CanvasLayer.new()
	_hud_layer.layer = 100
	_hud = Label.new()
	_hud.position = Vector2(12, 12)
	_hud.add_theme_color_override("font_color", Color.WHITE)
	_hud.add_theme_color_override("font_outline_color", Color.BLACK)
	_hud.add_theme_constant_override("outline_size", 6)
	_hud_layer.add_child(_hud)
	add_child(_hud_layer)

	_set_active(enabled_on_start)


func _unhandled_input(event: InputEvent) -> void:
	if OS.is_debug_build() and event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F6:
		_set_active(not _mesh_instance.visible)
		get_viewport().set_input_as_handled()


func _set_active(on: bool) -> void:
	_mesh_instance.visible = on
	_hud_layer.visible = on
	for label in _labels.values():
		label.visible = on
	set_process(on)
	if on:
		_rescan_timer = 0.0
		_update_timer = 0.0


func _process(delta: float) -> void:
	_rescan_timer -= delta
	if _rescan_timer <= 0.0:
		_rescan_timer = 1.0
		_rescan()
	if _fluid == null:
		_hud.text = "WaterDebug: no FluidArea3D found in the scene"
		_mesh_instance.mesh = null
		return

	_update_timer -= delta
	if _update_timer > 0.0:
		return
	_update_timer = 1.0 / update_hz
	_redraw()


func _rescan() -> void:
	var root := get_tree().current_scene
	if root == null:
		return
	_fluid = null
	_carriers.clear()
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is FluidArea3D and _fluid == null:
			_fluid = node
		elif node is Carrier:
			_carriers.append(node)
		for child in node.get_children():
			stack.push_back(child)
	# Drop labels for carriers that no longer exist
	for carrier in _labels.keys():
		if not is_instance_valid(carrier) or not _carriers.has(carrier):
			if is_instance_valid(_labels[carrier]):
				_labels[carrier].queue_free()
			_labels.erase(carrier)


func _redraw() -> void:
	var verts := PackedVector3Array()
	var colors := PackedColorArray()
	var camera := get_viewport().get_camera_3d()
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var focus: Vector3 = player.global_position if player else (camera.global_position if camera else Vector3.ZERO)

	# 1. Sampled surface grid, snapped to the spacing so it doesn't swim as the player moves
	var cx := snappedf(focus.x, grid_spacing)
	var cz := snappedf(focus.z, grid_spacing)
	var n := grid_half_cells * 2 + 1
	var heights := PackedFloat32Array()
	heights.resize(n * n)
	for j in n:
		for i in n:
			var x := cx + (i - grid_half_cells) * grid_spacing
			var z := cz + (j - grid_half_cells) * grid_spacing
			heights[j * n + i] = _fluid.get_surface_height(Vector3(x, 0.0, z))
	for j in n:
		for i in n:
			var x := cx + (i - grid_half_cells) * grid_spacing
			var z := cz + (j - grid_half_cells) * grid_spacing
			var p := Vector3(x, heights[j * n + i], z)
			if i + 1 < n:
				_line(verts, colors, p, Vector3(x + grid_spacing, heights[j * n + i + 1], z), COLOR_GRID)
			if j + 1 < n:
				_line(verts, colors, p, Vector3(x, heights[(j + 1) * n + i], z + grid_spacing), COLOR_GRID)

	# 2. Effective (wading) surface: the visible one minus physics_offset, drawn coarser.
	# This is the height player/citizen buoyancy actually uses.
	var offset: float = _fluid.physics_offset
	if absf(offset) > 0.001:
		for j in range(0, n, 2):
			for i in range(0, n - 2, 2):
				var x := cx + (i - grid_half_cells) * grid_spacing
				var z := cz + (j - grid_half_cells) * grid_spacing
				_line(verts, colors,
					Vector3(x, heights[j * n + i] - offset, z),
					Vector3(x + grid_spacing * 2.0, heights[j * n + i + 2] - offset, z), COLOR_EFFECTIVE)

	# 3. Trigger volume outline
	_add_area_box(verts, colors)

	# 4. Per-carrier floaters
	for carrier in _carriers:
		if not is_instance_valid(carrier):
			continue
		_draw_carrier(carrier, verts, colors)

	# 5. HUD
	_update_hud(camera, focus)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	if verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_mesh_instance.mesh = mesh


func _draw_carrier(carrier: Carrier, verts: PackedVector3Array, colors: PackedColorArray) -> void:
	var interactor := carrier.fluid_interactor
	var xf := carrier.global_transform
	var radius_scale: float = xf.basis.get_scale().y
	var lines: Array[String] = []
	for floater in interactor.get_floaters():
		var wp: Vector3 = xf * floater.position
		var surface := _fluid.get_height(wp)
		var col := COLOR_IN if floater.is_in_fluid() else COLOR_OUT
		var r: float = maxf(floater.radius * radius_scale, 0.05)
		# Cross at the floater centre, plus a line to the surface directly above/below it
		_line(verts, colors, wp - Vector3(r, 0, 0), wp + Vector3(r, 0, 0), col)
		_line(verts, colors, wp - Vector3(0, r, 0), wp + Vector3(0, r, 0), col)
		_line(verts, colors, wp - Vector3(0, 0, r), wp + Vector3(0, 0, r), col)
		_line(verts, colors, wp, Vector3(wp.x, surface, wp.z), col)
		lines.append("floater y=%.2f  surface=%.2f  diff=%+.2f" % [wp.y, surface, wp.y - r - surface])

	var label: Label3D = _labels.get(carrier)
	if label == null or not is_instance_valid(label):
		label = Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.pixel_size = 0.0007
		label.outline_size = 8
		label.render_priority = 101
		add_child(label)
		_labels[carrier] = label
	label.visible = true
	label.global_position = xf.origin + Vector3(0, 1.2, 0)
	var area_state := "area=%s" % ("none" if interactor.fluid_area == null else "set")
	label.text = "%s\n%s  in_fluid=%s\nforce_y=%.1f\n%s" % [
		carrier.name, area_state, carrier.is_in_fluid(), interactor.float_force.y, "\n".join(lines)]


func _update_hud(camera: Camera3D, focus: Vector3) -> void:
	var text := "WATER DEBUG (F6)\n"
	var surface_at_focus := _fluid.get_surface_height(focus)
	# describe_source() only exists on the new FluidArea3D; the legacy one just reads the Ocean terrain
	var source := "legacy Ocean terrain manager"
	if _fluid.has_method("describe_source"):
		source = _fluid.call("describe_source")
	elif _fluid.get("ocean_terrain_manager") == null:
		source = "legacy: manager NOT resolved -> flat box height"
	text += "water source: %s\n" % source
	text += "surface at player XZ: %.3f   (player y=%.3f)\n" % [surface_at_focus, focus.y]
	if camera:
		var cam := camera.global_position
		var cs := _fluid.get_surface_height(cam)
		text += "camera y=%.3f  surface=%.3f  -> %s\n" % [cam.y, cs, "UNDERWATER" if cam.y <= cs else "above water"]
	text += "carriers tracked: %d\n" % _carriers.size()
	text += "grid: cyan=visible surface  magenta=effective (wading) surface, offset %.2f\n" % _fluid.physics_offset
	text += "yellow=trigger box  red/green=floater in/out"
	_hud.text = text


func _add_area_box(verts: PackedVector3Array, colors: PackedColorArray) -> void:
	for owner_id in _fluid.get_shape_owners():
		var cs = _fluid.shape_owner_get_owner(owner_id)
		if not (cs is CollisionShape3D and cs.shape is BoxShape3D):
			continue
		var half: Vector3 = (cs.shape as BoxShape3D).size * 0.5
		var xf: Transform3D = cs.global_transform
		var c: Array[Vector3] = []
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					c.append(xf * Vector3(half.x * sx, half.y * sy, half.z * sz))
		# corner index = sx*4 + sy*2 + sz (with -1->0, 1->1); connect corners differing in one bit
		for a in 8:
			for bit in [1, 2, 4]:
				var b: int = a ^ bit
				if b > a:
					_line(verts, colors, c[a], c[b], COLOR_BOX)
		break


func _line(verts: PackedVector3Array, colors: PackedColorArray, a: Vector3, b: Vector3, col: Color) -> void:
	verts.append(a)
	verts.append(b)
	colors.append(col)
	colors.append(col)
