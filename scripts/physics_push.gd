class_name PhysicsPush

## Rigid-body impact solver. Static helpers only -- nothing is instanced.
##
## Rigid bodies (boulders, logs, boats) call solve_rigid_contacts(self) every physics frame.
## It hands one-time impacts to any CharacterBody3D that exposes receive_push(Vector3) (in practice
## every Carrier). Carriers push rigid bodies themselves in Carrier._push_colliding_bodies().
##
## Why this is a solver and not a physics body: a CharacterBody3D is kinematic, so the engine
## never transfers a rigid body's momentum to it. The body just stops dead against the carrier.
## The momentum transfer is computed here from both masses.
##
## An impact happens on the FIRST frame of contact only. The change is relative to the character's
## own pre-slide velocity, so a character walking into a stationary body is not pushed by its own
## walking speed every frame. Ongoing contact does nothing here.
##
## Requires the rigid body to have contact_monitor = true and max_contacts_reported > 0.

const DEFAULT_MASS := 50.0 # assumed for a pushable CharacterBody3D that has no `mass` property
# Impact strength: 1.0 = perfectly inelastic, above 1.0 adds bounce (1.4 ~ restitution 0.4).
const PUSH_TRANSFER := 1.4
const IMPACT_LIFT := 0.6 # upward launch speed as a fraction of the horizontal impact speed
# An impact that gives the carrier at least this much horizontal speed (m/s) also pops it into the air.
const LAUNCH_MIN_DV := 1.5
const SHOVE_MIN_SPEED := 0.5 # approach speed (m/s) below which a touch doesn't count as an impact


# Velocity of a point on a rigid body: linear + angular x lever.
static func point_velocity(body: RigidBody3D, world_point: Vector3) -> Vector3:
	return body.linear_velocity + body.angular_velocity.cross(world_point - body.global_position)


# Mass of any pushable body: RigidBody3D.mass, Carrier.mass, or DEFAULT_MASS as a fallback.
static func mass_of(body: Object) -> float:
	var m = body.get("mass")
	return float(m) if m != null and float(m) > 0.0 else DEFAULT_MASS


# Call once per physics frame from a rigid body.
static func solve_rigid_contacts(body: RigidBody3D) -> void:
	# The physics step has already resolved any hit (we're a wall to it), so body.linear_velocity is
	# post-impact. Use last frame's state for the pre-impact velocity.
	var prev_lin: Vector3 = body.get_meta("_shove_prev_lin", body.linear_velocity)
	var prev_ang: Vector3 = body.get_meta("_shove_prev_ang", body.angular_velocity)
	var prev_origin: Vector3 = body.get_meta("_shove_prev_origin", body.global_position)
	body.set_meta("_shove_prev_lin", body.linear_velocity)
	body.set_meta("_shove_prev_ang", body.angular_velocity)
	body.set_meta("_shove_prev_origin", body.global_position)
	var touching: Dictionary = body.get_meta("_shove_touching", {})
	var now := {}

	for other in body.get_colliding_bodies():
		if not (other is CharacterBody3D and other.has_method("receive_push")):
			continue
		var id: int = other.get_instance_id()
		now[id] = true

		# Only the first frame of contact is an impact. Ongoing contact is handled by the
		# character's own steering, so nothing accumulates here.
		if touching.has(id):
			continue
		# Standing on this body's deck is not being hit by it
		if other.has_method("is_standing_on") and other.is_standing_on(body):
			continue

		var dir: Vector3 = other.global_position - body.global_position
		dir.y = 0.0
		if dir.length() < 0.01:
			continue
		dir = dir.normalized()

		# How fast the body is moving INTO the character, relative to the character's intended
		# (pre-slide) motion along the contact direction.
		var body_point: Vector3 = prev_lin + prev_ang.cross(other.global_position - prev_origin)
		var carrier_v := Vector3.ZERO
		var cv = other.get("pre_slide_velocity")
		if cv is Vector3:
			carrier_v = cv
		var approach: float = (body_point - carrier_v).dot(dir)
		if approach <= SHOVE_MIN_SPEED:
			continue

		var share: float = body.mass / (body.mass + mass_of(other))
		var dv: Vector3 = dir * approach * share * PUSH_TRANSFER
		if dv.length() > LAUNCH_MIN_DV:
			dv.y = dv.length() * IMPACT_LIFT
		other.receive_push(dv)

	body.set_meta("_shove_touching", now)
