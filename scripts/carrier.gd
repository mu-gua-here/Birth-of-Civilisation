extends CharacterBody3D
class_name Carrier

## Shared base for anything that can gather resources -- Player and Citizen
## both extend this instead of duplicating gathering-pipeline glue.

const NORMAL_VERTICAL_SKIP := 0.7 # skip pushing if abs(normal.y) exceeds this -- see class comment
const PUSH_TRANSFER := 1.4  # how much of our incoming speed passes into the prop as an impulse (scaled by the prop's own mass)
const PUSH_SLOWDOWN := 0.5  # fraction of our own incoming speed we lose while shoving something

var builder: Node = null

## Buoyancy (addons/floatable_body) -- CharacterBody3D isn't a RigidBody3D,
## so we can't use FloatableBody3D directly. Instead we drive the same
## FluidInteractor3D helper by hand: register floaters from our collision
## shape(s), call process() every physics frame, and fold float_force into
## `velocity` ourselves (see _apply_buoyancy()). mass is fixed at 1.0 since
## Carrier has no physical mass property of its own.
const FLUID_MASS := 1.0
@export var fluid_damp := 4.0

## Scales the raw Archimedes force from FluidInteractor3D. At 1.0 the
## carrier is fully buoyant and settles AT the surface (floats). Below 1.0
## buoyancy no longer fully cancels gravity, so the carrier sinks -- slowly,
## because fluid_damp still caps how fast velocity can build up, rather
## than free-falling at normal gravity speed. Tuned for "sink gradually
## toward the bottom" rather than "bob at the surface".
@export var fluid_buoyancy_scale := 0.45
@onready var fluid_interactor := FluidInteractor3D.new()

# Call this from _ready() in the subclass (after add_to_group etc.) instead
# of duplicating the setup.
func _carrier_ready() -> void:
	builder = Globals.builder
	# Trees live on their own physics layer (Builder.TREE_COLLISION_LAYER),
	# separate from the terrain's normal layer, so the static navmesh bake
	# never has to see them (see Builder._spawn_tree_obstacle()). That means
	# we have to explicitly opt in to colliding with that layer here, or
	# standing trees would stop physically blocking movement entirely.
	set_collision_mask_value(2, true)
	
	for owner_id in get_shape_owners():
		var collision = shape_owner_get_owner(owner_id)
		if collision is CollisionShape3D:
			fluid_interactor.add_collision_shape(collision)

# Call once per physics frame, BEFORE gravity/movement is applied to
# `velocity` -- adds buoyant float force and damps velocity while submerged.

func _apply_buoyancy(delta: float) -> void:
	fluid_interactor.process(global_transform, FLUID_MASS)
	# Gated on fluid_buoyancy_scale too, not just float_force -- float_force is raw
	# Archimedes physics and is non-zero any time we're submerged at all, regardless of
	# fluid_buoyancy_scale. Without this second check, setting the scale to 0 to test "no
	# buoyancy" still ran the damping line below every frame, which fights gravity on its
	# own and made the scale look like it was doing nothing.
	if not fluid_interactor.float_force.is_zero_approx() and fluid_buoyancy_scale > 0.0:
		velocity += fluid_interactor.float_force * fluid_buoyancy_scale * delta * delta / FLUID_MASS
		velocity += -velocity * fluid_damp * delta

func is_in_fluid() -> bool:
	for floater in fluid_interactor.get_floaters():
		if floater.is_in_fluid():
			return true
	return false

# Called by FluidArea3D.body_enter/body_exit via duck typing.
func fluid_area_enter(area: FluidArea3D) -> void:
	fluid_interactor.fluid_area_enter(area)

func fluid_area_exit(area: FluidArea3D) -> void:
	fluid_interactor.fluid_area_exit(area)

# Shared physical push logic for resource props -- reads this frame's actual
# collisions (see class comment). Call this AFTER move_and_slide().
func _push_colliding_resource_props() -> void:
	for i in get_slide_collision_count():
		var collision := get_slide_collision(i)
		var collider = collision.get_collider()
		if not (collider is RigidBody3D and collider.is_in_group("resource_prop")):
			continue
		if collider.collected:
			continue
		
		var normal := collision.get_normal()
		if absf(normal.y) > NORMAL_VERTICAL_SKIP:
			continue # curved top of the log, not a real "wall" contact -- see class comment
		
		var push_dir := -normal
		push_dir.y = 0.0
		if push_dir.length() < 0.01:
			continue
		push_dir = push_dir.normalized()
		
		# How fast we're actually moving INTO the prop, not just our overall
		# speed -- e.g. grazing past it at an angle shouldn't shove it hard.
		var incoming_speed: float = velocity.dot(push_dir)
		if incoming_speed <= 0.0:
			continue
		
		collider.apply_central_impulse(push_dir * incoming_speed * collider.mass * PUSH_TRANSFER)
		velocity -= push_dir * incoming_speed * PUSH_SLOWDOWN
