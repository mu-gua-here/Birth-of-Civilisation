extends Area3D
class_name FluidArea3D

## Trigger volume that registers bodies as "in fluid" and answers get_height(pos) for them.
## The surface height comes from WaterSurface.height_at() -- the same function that drives the
## rendered waves -- so buoyancy, the underwater-camera check and the visible water agree.

@export var density: float = 1.0
@export var simulate_turbulence := true

@export var water_surface : WaterSurface
## How far below the VISIBLE surface the effective water starts for things that use get_height()
## (player, citizens). A body only feels the water once it's roughly half submerged, so you
## wade through shallows instead of skating on them. Boats ignore this and sit on the visible
## surface (get_surface_height).
@export var physics_offset := 0.5
## How far below sea level the trigger volume extends.
@export var depth := 80.0
## Horizontal size of the trigger volume (square). Match the playable world.
@export var extent := 500.0
## Extra room above the highest possible wave so a body riding a crest never leaves the volume.
@export var headroom := 2.0


func _ready() -> void:
	if water_surface == null:
		water_surface = _find_water_surface(get_tree().current_scene)
	if water_surface == null:
		push_warning("FluidArea3D '%s': no WaterSurface found -- get_height() will return 0." % name)
	else:
		_fit_volume_to_surface()

	body_entered.connect(body_enter)
	body_exited.connect(body_exit)


func body_enter(body: Node3D) -> void:
	if body is PhysicsBody3D and body.has_method("fluid_area_enter"):
		body.fluid_area_enter(self)


func body_exit(body: Node3D) -> void:
	if body is PhysicsBody3D and body.has_method("fluid_area_exit"):
		body.fluid_area_exit(self)


## Effective water height for bodies that should wade (visible surface minus physics_offset).
## This is what FluidInteractor3D calls.
func get_height(pos: Vector3) -> float:
	return get_surface_height(pos) - physics_offset


## The visible surface (exactly what the shader draws). Use for the underwater camera check
## and for floating objects that should ride on the waves.
func get_surface_height(pos: Vector3) -> float:
	if water_surface == null:
		return 0.0
	return water_surface.height_at(pos.x, pos.z)


func describe_source() -> String:
	if water_surface == null:
		return "NONE (returning 0)"
	return "WaterSurface '%s' sea_level=%.2f max_wave=%.2f" % [
		water_surface.name, water_surface.sea_level, water_surface.max_amplitude()]


## The old setup left the box top at an arbitrary height (+5 in main.tscn) unrelated to the
## water, so a body on a tall crest could fall outside the volume and silently lose buoyancy.
## Derive the box from the surface instead.
func _fit_volume_to_surface() -> void:
	for owner_id in get_shape_owners():
		var cs = shape_owner_get_owner(owner_id)
		if cs is CollisionShape3D and cs.shape is BoxShape3D:
			var top := water_surface.sea_level + water_surface.max_amplitude() + headroom
			var bottom := water_surface.sea_level - depth
			var box := BoxShape3D.new()
			box.size = Vector3(extent, top - bottom, extent)
			cs.shape = box
			# Area is at the origin of the scene; place the box in world space
			global_position = Vector3.ZERO
			cs.position = Vector3(0.0, (top + bottom) * 0.5, 0.0)
			return
	push_warning("FluidArea3D '%s': no BoxShape3D child to fit." % name)


func _find_water_surface(root: Node) -> WaterSurface:
	if root == null:
		return null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is WaterSurface:
			return node
		for child in node.get_children():
			stack.push_back(child)
	return null
