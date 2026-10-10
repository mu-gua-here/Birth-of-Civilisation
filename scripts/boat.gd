extends RigidBody3D
class_name Boat

## Boat buoyancy with one force PER FLOATER, applied at that floater's position.
##
## The addon's FloatableBody3D collapses all floaters into a single force at their weighted
## centre, which gives almost no restoring torque and no wave-driven rotation. Here every
## floater samples the visible water surface (FluidArea3D.get_surface_height -> the same
## function that shapes the rendered mesh), so a floater on a crest lifts its corner and one in
## a trough drops it: waves pitch and roll the hull, and the same springs right it again.
##
## Child Marker3D nodes whose name starts with "Floater" are the buoyancy points.

@export var floater_radius := 0.15
## Total lift when every floater is fully submerged, as a multiple of the boat's weight.
## 2.0 settles with the floaters half under (their centres at the surface).
@export var buoyancy_ratio := 2.0
## Damping of heave/pitch/roll as a fraction of critical. Higher = calmer, less bobbing.
@export_range(0.0, 2.0) var damping_ratio := 0.8
## Horizontal drag while in the water (per second, scaled by mass).
@export var water_drag := 1.5

var _fluid: FluidArea3D = null
var _floaters: Array[Vector3] = [] # local to the body


func _ready() -> void:
	can_sleep = false # a sleeping body would ignore waves until something bumped it
	var inv := global_transform.affine_inverse()
	for child in find_children("Floater*", "Marker3D", true, false):
		_floaters.append(inv * child.global_position)
	if _floaters.is_empty():
		push_warning("Boat '%s': no Marker3D children named Floater* -- it will not float." % name)


func _physics_process(_delta: float) -> void:
	if _fluid == null or _floaters.is_empty():
		return

	var gravity := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)) * gravity_scale
	var n := _floaters.size()
	var full_lift := mass * gravity * buoyancy_ratio / n # per floater, fully submerged
	var stiffness := full_lift / (2.0 * floater_radius) # N per metre of submersion
	var damping := damping_ratio * 2.0 * sqrt(stiffness * n * mass) / n

	var xf := global_transform
	for local_pos in _floaters:
		var world_pos := xf * local_pos
		var lever := world_pos - xf.origin
		var surface := _fluid.get_surface_height(world_pos)
		# 0 = floater's bottom just touching the surface, 1 = fully under
		var submersion := clampf((surface - (world_pos.y - floater_radius)) / (2.0 * floater_radius), 0.0, 1.0)
		if submersion <= 0.0:
			continue

		var point_velocity := linear_velocity + angular_velocity.cross(lever)
		var lift := maxf(full_lift * submersion - damping * point_velocity.y * submersion, 0.0)
		var drag := -Vector3(point_velocity.x, 0.0, point_velocity.z) * mass * water_drag / n * submersion
		apply_force(Vector3.UP * lift + drag, lever)


## World positions of the floaters, for debug drawing.
func get_floater_world_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	for local_pos in _floaters:
		out.append(global_transform * local_pos)
	return out


# Called by FluidArea3D.body_enter/body_exit via duck typing.
func fluid_area_enter(area: FluidArea3D) -> void:
	_fluid = area


func fluid_area_exit(area: FluidArea3D) -> void:
	if _fluid == area:
		_fluid = null
