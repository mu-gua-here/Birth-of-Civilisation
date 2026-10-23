extends RigidBody3D

## A single physical unit of a gathered resource (one log, one fruit, etc).
## Builder.spawn_resource_prop() creates these one at a time as a gatherable
## structure (tree, bush) reaches fractional chop/pick progress -- see
## Builder.add_chop_progress() / _spawn_incremental_resource_props().
##
## Nothing auto-carries these -- the player/citizens have to physically
## PUSH them via real contact (see Carrier._push_colliding_bodies())
## wherever they're needed (the shared stockpile point for now, but later a
## construction site or anywhere else -- they stay fully mobile forever, no
## freezing/parking in one spot). Once a prop passes within COLLECT_RADIUS
## of SPAWN_POINT it's counted into the stockpile exactly once (`collected`
## guards against double-counting if it's shoved back through later), but it
## keeps existing as a normal, still-pushable physics object afterward.

const COLLECT_RADIUS := 1.5
const SPAWN_POINT := Vector3(0, 0, 0)
# A prop can only be collected once it's actually settled -- otherwise a log
# that's still falling or mid-flight from a push, but happens to pass over
# the spawn point's X/Z, gets counted while still airborne.
const SETTLE_SPEED_THRESHOLD := 0.4

var collected: bool = false

func _ready() -> void:
	# Needed so get_colliding_bodies() works -- lets us shove Carriers (see PhysicsPush.solve_rigid_contacts()).
	contact_monitor = true
	max_contacts_reported = 8

func _physics_process(_delta: float) -> void:
	PhysicsPush.solve_rigid_contacts(self)
	if collected:
		return
	var flat_pos := global_position
	flat_pos.y = 0.0
	if flat_pos.distance_to(SPAWN_POINT) <= COLLECT_RADIUS and linear_velocity.length() < SETTLE_SPEED_THRESHOLD:
		_collect()

func _collect() -> void:
	collected = true
	var owning_builder = get_meta("builder", null)
	var resource_type: String = get_meta("resource_type", "")
	var amount: int = get_meta("amount", 0)
	if owning_builder != null and resource_type != "" and amount > 0:
		owning_builder.deposit_resources({resource_type: amount})
	# Deliberately NOT frozen -- stays a live, pushable RigidBody3D so it can
	# still be shoved to a hut/construction site or anywhere else later.
