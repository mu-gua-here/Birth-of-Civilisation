extends RigidBody3D
class_name FloatableBody3D

signal entered_to_fluid(Vector3)
signal exited_to_fluid(Vector3)

@export var use_collision_shapes := true
## Marker3D children whose name starts with "Floater" become buoyancy points.
## If any exist, they are used instead of generating floaters from collision shapes.
@export var use_floater_markers := true
## Total displaced volume used with markers (tune with mass; larger = floats higher).
@export var floater_volume := 1.0
## Radius of each marker floater (larger = smoother, more gradual lift).
@export var floater_radius := 0.15
@export var fluid_damp := 4.0
@onready var fluid_interactor := FluidInteractor3D.new()


func _ready():
	if use_floater_markers:
		var inv := global_transform.affine_inverse()
		for child in find_children("Floater*", "Marker3D", true, false):
			fluid_interactor.add_floater(inv * child.global_position, floater_radius)
		if not fluid_interactor.floaters.is_empty():
			fluid_interactor.volume = floater_volume
			return
	if use_collision_shapes:
		for owner_id in get_shape_owners():
			var collision = shape_owner_get_owner(owner_id)
			if collision is CollisionShape3D:
				fluid_interactor.add_collision_shape(collision)


func _physics_process(delta: float) -> void:
	fluid_interactor.process(global_transform, mass, gravity_scale)
	
	for floater in fluid_interactor.get_floaters():
		if floater.is_just_entered_to_fluid():
			entered_to_fluid.emit(floater.position)
		if floater.is_just_exited_from_fluid():
			exited_to_fluid.emit(floater.position)

	if not fluid_interactor.float_force.is_zero_approx():
		# Bouyancy
		apply_force(fluid_interactor.float_force * delta, fluid_interactor.float_position)
		# Damping
		linear_damp = fluid_damp
		angular_damp = fluid_damp
	else:
		linear_damp = 0.0
		angular_damp = 0.0

# Call from FluidArea2D
func fluid_area_enter(area: FluidArea3D) -> void:
	fluid_interactor.fluid_area_enter(area)

# Call from FluidArea3D
func fluid_area_exit(area: FluidArea3D) -> void:
	fluid_interactor.fluid_area_exit(area)
