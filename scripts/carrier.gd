extends CharacterBody3D
class_name Carrier

## Shared base for anything that can gather resources -- Player and Citizen
## both extend this instead of duplicating gathering-pipeline glue.

const NORMAL_VERTICAL_SKIP := 0.7 # skip pushing if abs(normal.y) exceeds this -- see class comment
const PUSH_TRANSFER := 1.4  # how much of our incoming speed passes into the prop as an impulse (scaled by the prop's own mass)
const PUSH_SLOWDOWN := 0.5  # fraction of our own incoming speed we lose while shoving something

var builder: Node = null

## Sinking (no buoyancy) -- people don't float up on their own, so a carrier in the water is
## pulled down GRADUALLY rather than dropping like on land: a constant downward pull (sink_accel)
## fighting drag (fluid_damp), which eases in to a terminal sink speed of sink_accel / fluid_damp
## m/s. "In the water" = the water probe (centre of our collision shape) is below
## FluidArea3D.get_height(), i.e. roughly half submerged. See _apply_gravity().
@export var fluid_damp := 4.0

## Downward acceleration while in water (m/s^2). Terminal sink speed = sink_accel / fluid_damp
## (3.0 / 4.0 = 0.75 m/s). Raise for a faster sink, lower for a slower one.
@export var sink_accel := 3.0

## How far BELOW the visible water surface the body centre must be before it counts as in the
## water. 0.0 = centre at the surface, i.e. half the body can stay above water. Raise it to make
## carriers wade deeper before sinking.
@export var wade_depth := 0.0

## The FluidArea3D we're currently inside (null on land). Set by fluid_area_enter/exit.
var fluid_area: FluidArea3D = null
var _water_probe: CollisionShape3D = null

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
			_water_probe = collision
			break

# Call once per physics frame INSTEAD of applying get_gravity() yourself. On land this is plain
# gravity (skipped while on the floor). In water it is the gradual sink: constant pull down plus
# drag on the whole velocity, so you ease toward the bottom and horizontal motion is slowed.

func _apply_gravity(delta: float) -> void:
	if is_in_fluid():
		velocity.y -= sink_accel * delta
		velocity += -velocity * fluid_damp * delta
		return
	if not is_on_floor():
		velocity += get_gravity() * delta

# Where we test "am I in the water": the centre of our collision shape (falls back to our origin).
func water_probe_position() -> Vector3:
	return _water_probe.global_position if _water_probe != null else global_position

func is_in_fluid() -> bool:
	if fluid_area == null:
		return false
	var p := water_probe_position()
	return p.y <= fluid_area.get_surface_height(p) - wade_depth

# Called by FluidArea3D.body_enter/body_exit via duck typing.
func fluid_area_enter(area: FluidArea3D) -> void:
	fluid_area = area

func fluid_area_exit(area: FluidArea3D) -> void:
	if fluid_area == area:
		fluid_area = null

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
