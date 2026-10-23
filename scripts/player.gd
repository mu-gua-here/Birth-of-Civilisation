extends Carrier

var plane := Plane(Vector3.UP, Vector3.ZERO) # y=0 plane, used to turn mouse clicks into world positions

@export var view_node: Node3D

const NO_ID := Builder.NO_ID
# Walking/running top speed in m/s per unit of SPEED (kept from the old per-frame accumulation,
# where friction 0.8 settled at about 4x the per-frame input).
const WALK_SPEED_SCALE := 4.0

# Gathering / building (click-and-hold). A non-empty target id means the task is active.
var gather_target_id: String = NO_ID
var build_target_id: String = NO_ID

var spawn_point: Vector3

@export_category("Devmode")
@export var dev_mode := false
@export var DEV_SPEED: float = 2.5

# Player physical movement
@export_category("Physics")
@export var SPEED := 0.8
@export var RUN_SPEED := 1.2
@export var SWIM_SPEED := 0.5
@export var JUMP_HEIGHT := 5.0
@export var FRICTION := 0.8
@export var WATER_RESISTANCE := 0.99
@export var BOUNCE_HEIGHT := 4.0
var bounce_active := false

@export_category("Mechanics")
@export var fall_dmg_threshold := 10.0
@export var hunger_dmg := 0.2

# Player physiological settings. Assign to health/energy directly -- the setters
# clamp, emit health_changed and handle death.
@export_category("Physiology")
@export var max_health: float = 100.0
@export_range(0.0, 100.0) var health: float = 100.0:
	set(value):
		health = clampf(value, 0.0, max_health)
		health_changed.emit(health, max_health)
		if health <= 0.0:
			_on_death()

@export var heal_rate := 0.1
@export var heal_energy := 0.05

@export_range(0.0, 100.0) var energy: float = 80.0:
	set(value):
		energy = clampf(value, 0.0, 100.0)
@export var invuln_time: float = 0.5  # seconds of immunity after being hit
var invuln_timer: float = 0.0
@export var metabolism: float = 0.01
@export var move_energy := 0.1

# Knockback
var knockback: Vector3 = Vector3.ZERO
const KNOCKBACK_FRICTION = 6.0  # how fast knockback decays per second

signal health_changed(current: float, max: float)
signal died

func _ready():
	spawn_point = global_position
	add_to_group("player")
	if view_node == null:
		view_node = get_tree().get_first_node_in_group("view")
		if view_node == null:
			push_warning("Player: no view node found (expected a node in group \"view\").")
	Globals.register_player(self)
	_carrier_ready() # sets `builder` (see carrier.gd)

func _physics_process(delta: float) -> void:
	
	if not dev_mode:
		_apply_gravity(delta) # see carrier.gd -- gradual sink in water, normal gravity on land
	
	# Cached: is_in_fluid() samples the water height
	var in_fluid := is_in_fluid()
	
	# (gravity / sinking is applied at the top by _apply_gravity())
	
	# ENERGY MECHANICS
	
	# Tiredness slows movement and weakens jumps
	# Slow down player when insufficient energy
	var energy_mult := lerpf(0.25, 1.25, energy * 0.01)
	
	# Jump (solid ground only -- swimming is handled by the swim_up/swim_down axis below)
	var just_jumped := false
	if energy > 0.0:
		if Input.is_action_just_pressed("player_jump") and not in_fluid and (is_on_floor() or bounce_active):
			velocity.y = JUMP_HEIGHT * energy_mult
			energy -= JUMP_HEIGHT * 0.01
			bounce_active = false
			just_jumped = true
	
	# Movement input, rotated to follow the camera
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var up_down := Input.get_axis("descend", "ascend")
	var move_vec := Vector3(input_dir.x, up_down if in_fluid or dev_mode else 0.0, input_dir.y)
	var direction := move_vec.rotated(Vector3.UP, view_node.rotation.y if view_node else 0.0).normalized()
	
	# Run & walk speed
	var speed: float = RUN_SPEED if Input.is_action_pressed("run") else SPEED
	# Mult for dev_mode
	speed *= DEV_SPEED if dev_mode else SPEED
	
	# Horizontal movement steers toward the wanted velocity (see Carrier.steer_horizontal) instead of
	# piling onto velocity, so outside impacts can be steered against and decay normally.
	var wanted := Vector3(direction.x, 0.0, direction.z) * speed * energy_mult * WALK_SPEED_SCALE
	steer_horizontal(wanted, delta)
	if not direction.is_zero_approx():
		if dev_mode:
			velocity += direction * speed
		elif in_fluid:
			velocity.y += direction.y * SWIM_SPEED * energy_mult
			# Subtract energy when movement is done by player
			energy -= move_energy * delta
	
	# Small bounce animation while walking (skipped on the frame a jump already set velocity.y)
	if is_on_floor():
		if input_dir != Vector2.ZERO and not just_jumped:
			if not in_fluid or up_down >= 0.0:
				velocity.y += BOUNCE_HEIGHT - (2.0 * WATER_RESISTANCE if in_fluid else 0.0)
				bounce_active = true
	
	if dev_mode: velocity *= FRICTION
	
	# Start eating away at health once at critical levels
	if energy < 30.0:
		health -= hunger_dmg * delta
	
	# Knockback from attackers, decaying over time
	if knockback.length() > 0.01:
		velocity += knockback
		knockback = knockback.move_toward(Vector3.ZERO, KNOCKBACK_FRICTION * delta)
	
	if invuln_timer > 0.0:
		invuln_timer -= delta
	
	if position.y < -100.0:
		_on_death()
	
	_update_gathering(delta)
	_update_building_task(delta)
	
	_before_slide() # records pre-slide velocity for the push logic, see carrier.gd
	
	# Fall damage needs the speed before move_and_slide() zeroes it on landing
	var fall_speed := -velocity.y
	move_and_slide()
	if not dev_mode:
		if (is_on_floor() or in_fluid) and fall_speed > fall_dmg_threshold:
			# Twice as less damage when falling on water than on land
			var damage = 1.5 * (fall_speed - fall_dmg_threshold) * (2 - int(in_fluid))
			health -= damage
	
	_push_colliding_bodies() # move any moveable objects on player collision
	
	# Heal player if not at max health
	if health < 100.0 and health > 30.0:
		health += heal_rate * delta
		energy -= heal_energy * delta
	
	energy -= metabolism * delta

# Called by attackers (e.g. angry citizens). Ignored while invulnerable.
func take_damage(amount: float, source_position: Vector3 = global_position, knockback_force: float = 4.0) -> void:
	if invuln_timer > 0.0:
		return
	invuln_timer = invuln_time
	
	# Push the player directly away from whatever hit them
	var push_dir := global_position - source_position
	push_dir = push_dir.normalized() if push_dir.length() > 0.01 else Vector3.FORWARD
	knockback = push_dir * knockback_force
	velocity.y = max(velocity.y, 1.0)  # small upward pop on hit
	
	health -= amount # may trigger _on_death() via the setter

func _on_death() -> void:
	# Placeholder -- hook up a respawn/game-over screen later
	died.emit()
	position = spawn_point
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	health = max_health
	
func _unhandled_key_input(event: InputEvent) -> void:
	if event.keycode == KEY_F8 and not (event is InputEventKey and event.pressed and not event.echo):
		dev_mode = not dev_mode

func _unhandled_input(event: InputEvent) -> void:
	# Click-AND-HOLD to gather a resource OR help build a construction site --
	# same gesture, branches on what's under the cursor (see _try_start_work).
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_start_work(event.position)
		else:
			_stop_work()

func _try_start_work(screen_pos: Vector2) -> void:
	if builder == null or builder.interact_mode:
		return
	# A citizen is selected -- this click is for assigning them (see CitizenSelector)
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	if selector and selector.selected_citizen != null:
		return
	
	var hit := _raycast_target_in_reach(screen_pos)
	if hit.id == NO_ID:
		return
	
	# Construction site takes priority over gathering at the same spot.
	if hit.is_site:
		build_target_id = hit.id
		builder.assign_builder_to_site(Builder.PLAYER_BUILDER_ID, hit.id)
		get_viewport().set_input_as_handled()
		return
	
	var si: int = builder.get_structure_index(hit.id)
	if si >= 0 and builder.structures[si].gatherable:
		gather_target_id = hit.id
		get_viewport().set_input_as_handled()

func _stop_work() -> void:
	_stop_gathering()
	_stop_building_task()

func _stop_gathering() -> void:
	gather_target_id = NO_ID

func _stop_building_task() -> void:
	if build_target_id != NO_ID and builder != null:
		builder.release_builder(Builder.PLAYER_BUILDER_ID)
	build_target_id = NO_ID

# Called every physics frame while the mouse button is held.
func _update_gathering(delta: float) -> void:
	if gather_target_id == NO_ID:
		return
	if builder == null:
		_stop_gathering()
		return
	
	# Tree already destroyed (by us or someone else) -- stop.
	var structure_index: int = builder.get_structure_index(gather_target_id)
	if structure_index < 0 or not builder.structures[structure_index].gatherable:
		_stop_gathering()
		return
	
	# Wandered out of reach while holding -- stop rather than gathering at a distance.
	if _flat_distance_to(builder.get_structure_position(gather_target_id)) > Builder.PLAYER_WORK_REACH:
		_stop_gathering()
		return
	
	var structure: Structure = builder.structures[structure_index]
	energy -= structure.energy_required * delta
	
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / structure.gather_time)
	if result.get("completed", false):
		energy += result.get("energy_bonus", 0.0)
		_stop_gathering()

# Progress itself accrues in Builder._process_construction() purely because
# PLAYER_BUILDER_ID is in assigned_builders -- this only validates the hold is
# still legitimate and pays the energy cost.
func _update_building_task(delta: float) -> void:
	if build_target_id == NO_ID:
		return
	if builder == null or not builder.construction_sites.has(build_target_id):
		_stop_building_task() # site finished or demolished mid-hold
		return
	
	var site = builder.construction_sites[build_target_id]
	if _flat_distance_to(site.position) > Builder.PLAYER_WORK_REACH:
		_stop_building_task()
		return
	
	energy -= builder.structures[site.structure_index].build_energy_required * delta

func _flat_distance_to(pos: Vector3) -> float:
	return global_position.distance_to(Vector3(pos.x, global_position.y, pos.z))

# Raycasts from the camera onto the ground plane and returns whichever
# construction site or placed structure is within reach of the player there.
# {id: String, is_site: bool}; id == NO_ID if nothing qualifies.
func _raycast_target_in_reach(screen_pos: Vector2) -> Dictionary:
	var none := {"id": NO_ID, "is_site": false}
	if builder == null or view_node == null:
		return none
	var camera := view_node.get_node_or_null("Camera") as Camera3D
	if camera == null:
		return none
	
	var world_position = plane.intersects_ray(
		camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos))
	if world_position == null or _flat_distance_to(world_position) > Builder.PLAYER_WORK_REACH:
		return none
	
	var site_id: String = builder.get_nearest_construction_site(world_position)
	if site_id != NO_ID and builder.construction_sites[site_id].position.distance_to(world_position) <= Builder.PLAYER_WORK_REACH:
		return {"id": site_id, "is_site": true}
	
	var structure_id: String = builder.get_structure_at_point(world_position, Builder.PLAYER_WORK_REACH)
	if structure_id != NO_ID:
		return {"id": structure_id, "is_site": false}
	
	return none
