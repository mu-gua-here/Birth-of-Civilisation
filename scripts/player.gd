extends Carrier

# Constants
var plane := Plane(Vector3.UP, Vector3.ZERO)

@export var view_node: Node3D

# Distance NPC/Player needs to be from a gatherable/construction cell to
# work it -- shared by both gathering and building.
const GATHER_REACH := 15.0
const NO_ID := ""

# ID the player registers under in ConstructionSite.assigned_builders --
# distinct format from citizen ids (6-digit strings) so it can't collide.
const PLAYER_BUILDER_ID := "player_builder"

# Gathering (click-and-hold)
var is_gathering: bool = false
var gather_target_id: String = NO_ID

# Building (click-and-hold)
var is_building_task: bool = false
var build_target_id: String = NO_ID

var spawn_point:Vector3i

# Player physical movement
@export var SPEED: float = 0.5
@export var JUMP_HEIGHT: float = 5.0
@export var SWIM_IMPULSE: float = 6.0
@export var FRICTION: float = 0.8
@export var WATER_RESISTANCE: float = 0.9

@export var BOUNCE_HEIGHT := 4.0
var bounce_active := false

@export var swim_cooldown: float = 0.2
var swim_timer: float = 0.0

# Player physiological settings
@export var max_health: float = 100.0
@export_range(0.0, 100.0) var health: float = max_health
@export_range(0.0, 100.0) var energy: float = 100.0
@export var invuln_time: float = 0.5  # seconds of immunity after being hit
var invuln_timer: float = 0.0
@export var metabolism: float = 0.001

# Knockback
var knockback: Vector3 = Vector3.ZERO
const KNOCKBACK_FRICTION = 6.0  # how fast knockback decays per second

signal health_changed(current: float, max: float)
signal died

func _ready():
	spawn_point = global_position
	add_to_group("player")
	if view_node == null:
		view_node = find_first_node_by_name(get_tree().root, "View")
		if view_node == null:
			print("Player: Viewing node not found.")
		else:
			print("Player: Using \"%s\" as viewing node" % view_node.name)
	Globals.register_player(self)
	health = max_health
	_carrier_ready() # sets `builder` (see carrier.gd)

func find_first_node_by_name(root: Node, target_name: String) -> Node:
	for child in root.get_children():
		if child.name == target_name:
			return child
		var found := find_first_node_by_name(child, target_name)
		if found:
			return found
	return null


func _physics_process(delta: float) -> void:
	_apply_buoyancy(delta) # see carrier.gd -- must run before gravity/movement
	
	# Add the gravity
	if not is_on_floor():
		velocity += get_gravity() * delta

	# Handle jump -- a full jump off solid ground, or a much gentler swim
	# stroke if we're submerged but not standing on anything (see
	# fluid_buoyancy_scale in carrier.gd for why this doesn't rocket to the
	# surface: buoyancy + gravity here settle toward a slow sink, and this
	# stroke is the player's only way to actively counteract that).
	
	# Update swim cooldown timer
	if swim_timer > 0.0:
		swim_timer -= delta
	
	var energy_mult:float = clamp(energy * 0.02, 0.25, 1.0)
	var just_jumped := false
	
	if Input.is_action_just_pressed("player_jump") and energy > 0.0:
		if is_in_fluid():
			if swim_timer <= 0.0:
				velocity.y = SWIM_IMPULSE
				energy -= SWIM_IMPULSE * 0.01
				swim_timer = swim_cooldown
				just_jumped = true
		# Allow for jumping when player bounces, but not on the exact frame
		# player starts moving, otherwise will result in unusually high jump
		elif is_on_floor() or bounce_active:
			velocity.y = JUMP_HEIGHT
			energy -= JUMP_HEIGHT * 0.01
			bounce_active = false
			just_jumped = true
		# Apply tiredness factor to jump heights too
		if just_jumped:
			velocity.y *= energy_mult
	
	# Get the input direction and handle the movement/deceleration
	
	# Construct player movement vector
	var direction:Vector3
	var input_dir := Input.get_vector("ui_left", "ui_right", "ui_up", "ui_down")
	var up_down := Input.get_axis("swim_down", "swim_up")
	var move_vec = Vector3(input_dir.x, up_down if is_in_fluid() else 0.0, input_dir.y)
	
	# Different movement modes when in water vs not in water
	direction = move_vec.rotated(Vector3.UP, view_node.rotation.y if view_node else 0.0).normalized()
	
	var is_running:int = Input.is_action_pressed("run")
	if direction:
		velocity.x += direction.x * SPEED * (is_running + 1)
		if is_in_fluid(): velocity.y += direction.y * SPEED * (is_running + 1)
		velocity.z += direction.z * SPEED * (is_running + 1)
	
	energy -= (metabolism + Vector3(velocity.x, velocity.y if is_in_fluid() else 0.0, velocity.z).length() * metabolism) * delta
	
	# Small bounce animation
	# Guard: skip if this exact frame already set velocity.y via a jump above
	if is_on_floor() and input_dir and not just_jumped:
		velocity.y += BOUNCE_HEIGHT
		bounce_active = true
	
	# Apply slowing down of horizontal velocity
	velocity.x *= FRICTION
	velocity.z *= FRICTION
	
	# Slow player if player need food
	if energy < 50.0:
		velocity.x *= energy_mult
		velocity.z *= energy_mult
	
	# Layer in knockback from citizen and let it decay over time
	if knockback.length() > 0.01:
		velocity += knockback
		knockback = knockback.move_toward(Vector3.ZERO, KNOCKBACK_FRICTION * delta)

	# Tick down hit-immunity window
	if invuln_timer > 0.0:
		invuln_timer -= delta
	
	Globals.set_player_energy(energy)
	
	_update_gathering(delta)
	_update_building_task(delta)
	
	move_and_slide()
	_push_colliding_resource_props() # shared with citizen.gd, see carrier.gd -- must run AFTER move_and_slide() to read this frame's collisions

# Called by attackers (e.g. angry citizens). Ignored while invulnerable.
func take_damage(amount: float, source_position: Vector3 = global_position, knockback_force: float = 4.0) -> void:
	if invuln_timer > 0.0:
		return
	
	health = clamp(health - amount, 0.0, max_health)
	Globals.set_player_health(health)
	invuln_timer = invuln_time
	
	# Push the player directly away from whatever hit them
	var push_dir = global_position - source_position
	push_dir = push_dir.normalized() if push_dir.length() > 0.01 else Vector3.FORWARD
	knockback = push_dir * knockback_force
	velocity.y = max(velocity.y, 1.0)  # small upward pop on hit, tweak/remove to taste
	
	health_changed.emit(health, max_health)
	
	if health <= 0.0:
		died.emit()
		_on_death()

func _on_death() -> void:
	# Placeholder — hook up a respawn/game-over screen later
	position = spawn_point
	health = max_health
	position = Vector3i(0, 100, 0)
	velocity = Vector3.ZERO
	knockback = Vector3.ZERO
	health_changed.emit(health, max_health)

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
	# A citizen is selected -- this click is for assigning them (see
	# CitizenSelector), not for the player's own work.
	var selector = get_tree().get_first_node_in_group("citizen_selector")
	if selector and selector.selected_citizen != null:
		return
	
	var hit = _raycast_target_in_reach(screen_pos)
	if hit.id == NO_ID:
		return
	
	# Construction site takes priority over gathering at the same spot.
	if hit.is_site:
		build_target_id = hit.id
		is_building_task = true
		builder.assign_builder_to_site(PLAYER_BUILDER_ID, hit.id)
		get_viewport().set_input_as_handled()
		return
	
	var si = builder.get_structure_index(hit.id)
	if si >= 0 and si < builder.structures.size() and builder.structures[si].gatherable:
		gather_target_id = hit.id
		is_gathering = true
		get_viewport().set_input_as_handled()

func _stop_work() -> void:
	_stop_gathering()
	_stop_building_task()

func _stop_gathering() -> void:
	is_gathering = false
	gather_target_id = NO_ID

func _stop_building_task() -> void:
	if is_building_task and builder != null:
		builder.release_builder(PLAYER_BUILDER_ID)
	is_building_task = false
	build_target_id = NO_ID

# Called every physics frame while the mouse button is held (see _physics_process).
func _update_gathering(delta: float) -> void:
	if not is_gathering:
		return
	if builder == null:
		_stop_gathering()
		return
	
	# Tree already destroyed (by us or someone/something else) -- stop.
	var structure_index = builder.get_structure_index(gather_target_id)
	if structure_index < 0 or structure_index >= builder.structures.size() or not builder.structures[structure_index].gatherable:
		_stop_gathering()
		return
	
	# Wandered out of reach while holding -- stop rather than gathering at a distance.
	var target_pos = builder.get_structure_position(gather_target_id)
	var world_pos = Vector3(target_pos.x, global_position.y, target_pos.z)
	if global_position.distance_to(world_pos) > GATHER_REACH:
		_stop_gathering()
		return
	
	var gather_time = builder.structures[structure_index].gather_time
	var energy_required = builder.structures[structure_index].energy_required
	energy = clamp(energy - energy_required * delta, 0.0, 100.0)
	
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / gather_time)
	if result.get("completed", false):
		var energy_bonus: float = result.get("energy_bonus", 0.0)
		if energy_bonus > 0.0:
			energy = clamp(energy + energy_bonus, 0.0, 100.0)
		_stop_gathering()

# Called every physics frame while the mouse button is held on a construction
# site. Progress itself accrues in builder._process_construction() purely by
# virtue of PLAYER_BUILDER_ID being present in assigned_builders -- this only
# needs to validate the hold is still legitimate and pay the energy cost.
func _update_building_task(delta: float) -> void:
	if not is_building_task:
		return
	if builder == null:
		_stop_building_task()
		return
	
	# Site finished or got demolished mid-hold -- stop.
	if not builder.construction_sites.has(build_target_id):
		_stop_building_task()
		return
	
	# Wandered out of reach while holding -- stop, same as gathering.
	var site_pos = builder.construction_sites[build_target_id].position
	var world_pos = Vector3(site_pos.x, global_position.y, site_pos.z)
	if global_position.distance_to(world_pos) > GATHER_REACH:
		_stop_building_task()
		return
	
	var site = builder.construction_sites[build_target_id]
	var structure: Structure = builder.structures[site.structure_index]
	energy = clamp(energy - structure.build_energy_required * delta, 0.0, 100.0)

# Raycasts from the camera into the world and returns whichever placeable
# thing (construction site or placed structure) is within GATHER_REACH of
# the player at that point, if any. {id: String, is_site: bool}, id == NO_ID
# if nothing qualifies. Caller decides what to actually do with it.
func _raycast_target_in_reach(screen_pos: Vector2) -> Dictionary:
	var none := {"id": NO_ID, "is_site": false}
	if builder == null or view_node == null:
		return none
	var camera = view_node.get_node_or_null("Camera")
	if camera == null:
		return none
	
	var world_position = plane.intersects_ray(
		camera.project_ray_origin(screen_pos),
		camera.project_ray_normal(screen_pos))
	
	if world_position == null:
		return none
	
	if global_position.distance_to(Vector3(world_position.x, global_position.y, world_position.z)) > GATHER_REACH:
		return none
	
	var site_id = builder.get_nearest_construction_site(world_position)
	if site_id != NO_ID and builder.construction_sites[site_id].position.distance_to(world_position) <= GATHER_REACH:
		return {"id": site_id, "is_site": true}
	
	var structure_id = builder.get_structure_at_point(world_position, GATHER_REACH)
	if structure_id != NO_ID:
		return {"id": structure_id, "is_site": false}
	
	return none
