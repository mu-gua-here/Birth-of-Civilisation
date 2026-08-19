extends Carrier

# Movement settings
const BASE_SPEED = 5.0
const JUMP_HEIGHT := 1.0
var actual_speed: float
var wander_timer: float = 0.0
var idle_timer: float = 0.0

# Chase settings
var is_chasing_player: bool = false
var chase_repath_timer := 0.0
const CHASE_REPATH_INTERVAL := 0.25

# Distance a citizen needs to be from a gatherable/build cell to start contributing
const WORK_REACH := 1.5

# Attack settings (only relevant while is_chasing_player is true)
@export var attack_damage: float = 10.0
@export var attack_cooldown_time: float = 1.0  # seconds between hits on the same target
@export var attack_knockback_force: float = 0.5
var attack_cooldown: float = 0.0

@onready var nav_agent = $NavigationAgent3D
@onready var mesh_instance: MeshInstance3D = $MeshInstance3D

@export var data: CitizenData

var happiness_material: StandardMaterial3D

var housing_check_timer: float = 0.0
const HOUSING_CHECK_INTERVAL := 2.0 # how often to re-derive housing status from builder.buildings
var _has_housing: bool = false

var is_gathering: bool = false
const NO_ID := ""
var gather_target_id: String = NO_ID

# Building (A.4) -- entered only via explicit assignment (manual click for now)
var is_building: bool = false
var build_target_id: String = NO_ID

# Pushing a gathered resource prop back toward the spawn/stockpile point
# (Carrier.SPAWN_POINT) after a gather completes -- see carrier.gd for the
# actual per-frame push, which is shared with player.gd. This just drives a
# citizen to walk up to the nearest uncollected prop so the push has
# something in reach.
var is_pushing: bool = false
var push_target: RigidBody3D = null
var push_repath_timer: float = 0.0
const PUSH_REPATH_INTERVAL := 0.3

func _ready():
	if data == null:
		data = CitizenData.new()
	
	add_to_group("citizen")
	_carrier_ready() # sets `builder` (see carrier.gd)
		
	call_deferred("set_new_destination", Vector3(
		randf_range(-20, 20),
		0,
		randf_range(-20, 20)))
	nav_agent.velocity_computed.connect(_on_velocity_computed)
	
	# Create the override material
	happiness_material = StandardMaterial3D.new()
	mesh_instance.set_surface_override_material(0, happiness_material)
	update_happiness_color()

func _exit_tree():
	if builder and builder.has_method("release_citizen") and data:
		builder.release_citizen(data.id)

func _physics_process(delta):
	_apply_buoyancy(delta) # see carrier.gd -- must run before gravity/movement
	
	# Gravity
	if not is_on_floor():
		velocity += get_gravity() * delta
	
	# Periodically re-check whether this citizen is currently housed.
	# NOTE: job assignment is intentionally NOT auto-retried here -- per the
	# plan, manual (CitizenSelector) or policy (Milestone B, not yet built)
	# assignment via PolicyEngine is the only path to a job right now.
	housing_check_timer -= delta
	if housing_check_timer <= 0.0:
		housing_check_timer = HOUSING_CHECK_INTERVAL
		_refresh_housing_status()
	
	_update_gathering(delta)
	_update_building(delta)
	_update_pushing(delta)
	
	# Update citizen stats
	if data.job == "":
		data.job_satisfaction -= 10 * delta
	else:
		data.job_satisfaction += randf_range(0.0, 0.01)
	
	data.job_satisfaction = clamp(data.job_satisfaction, 0.0, 100.0)
	
	# Housing satisfaction eases toward 100 if housed, 0 if not
	var housing_target = 100.0 if _has_housing else 0.0
	data.housing_satisfaction = move_toward(data.housing_satisfaction, housing_target, delta * 20.0)
	
	data.happiness = clamp(50 - (100 - data.energy) * 0.005 + (data.job_satisfaction * 0.01 if data.job != "" else -data.job_satisfaction * 0.01) + (data.housing_satisfaction - 50.0) * 0.1, 0, 100)
	update_happiness_color()
	
	actual_speed = BASE_SPEED + (100 - data.happiness) * 0.01
	nav_agent.max_speed = actual_speed
	
	if data.happiness < 0.1:
		is_chasing_player = true
	elif data.happiness > 10.0:
		is_chasing_player = false
	
	if is_chasing_player:
		chase_repath_timer -= delta
		if chase_repath_timer <= 0.0:
			chase_repath_timer = CHASE_REPATH_INTERVAL
			if Globals.player:
				set_new_destination(Globals.player.global_position)
		
		# Tick down attack cooldown
		if attack_cooldown > 0.0:
			attack_cooldown -= delta

	# Wander timer (skipped while actively gathering, building, or pushing)
	if not is_gathering and not is_building and not is_pushing:
		wander_timer -= delta
		if is_on_floor() and wander_timer > 0:
			if data.energy > 0.0:
				velocity.y = JUMP_HEIGHT
		else:
			wander_timer = randf_range(0, 2) * (100 - data.happiness)
			idle_timer -= delta
			if idle_timer <= 0:
				set_new_destination(Vector3(
					randf_range(-20, 20),
					0,
					randf_range(-20, 20)
				))
				idle_timer = clamp(data.happiness, 180, 6000)	
	
	if not nav_agent.is_navigation_finished() and data.energy > 0.0:
		var next = nav_agent.get_next_path_position()
		var direction = (next - global_position).normalized()
		var desired_velocity = Vector3(direction.x * actual_speed, velocity.y, direction.z * actual_speed)
		if nav_agent.avoidance_enabled:
			nav_agent.set_velocity(desired_velocity)  # triggers velocity_computed signal
		else:
			velocity = desired_velocity
	else:
		velocity.x = move_toward(velocity.x, 0, actual_speed)
		velocity.z = move_toward(velocity.z, 0, actual_speed)
	
	# Slow citizen if citizen need food
	if data.energy < 50.0:
		var energy_mult = clamp(data.energy * 0.02, 0.25, 1.0)
		velocity.x *= energy_mult
		velocity.z *= energy_mult
	
	data.energy -= (data.metabolism + data.metabolism * Vector3(velocity.x, 0, velocity.z).length()) * delta
	data.energy = clamp(data.energy, 0, 100)
	
	move_and_slide()
	_push_colliding_resource_props() # shared with player.gd, see carrier.gd -- must run AFTER move_and_slide() to read this frame's collisions
	
	# Real physical collision check — did we actually touch the player this frame?
	if is_chasing_player and attack_cooldown <= 0.0:
		for i in get_slide_collision_count():
			var collision = get_slide_collision(i)
			var collider = collision.get_collider()
			if collider == Globals.player:
				if collider.has_method("take_damage"):
					collider.take_damage(attack_damage, global_position, attack_knockback_force)
				attack_cooldown = attack_cooldown_time
				break
		
	if position.y < -10:
		velocity = Vector3.ZERO
		position = Vector3(randf_range(-5, 5), 1, randf_range(-5, 5))

func _on_velocity_computed(safe_velocity: Vector3):
	velocity.x = safe_velocity.x
	velocity.z = safe_velocity.z

# Derives housing status directly from builder.buildings (the source of
# truth for occupancy) instead of a since-removed has_housing_for() call.
# A citizen is housed if their id appears in any BuildingInstance's residents.
func _refresh_housing_status() -> void:
	if builder == null:
		return
	_has_housing = false
	for instance in builder.buildings.values():
		if data.id in instance.residents:
			_has_housing = true
			break
	
	# Citizens without housing/a job just wander until the player assigns them
	# something via CitizenSelector -> PolicyEngine (or a future policy).

func _start_gathering() -> void:
	var id = builder.get_nearest_gatherable(global_position)
	if id == NO_ID:
		return
	_start_gathering_at(id)

func _start_gathering_at(id: String) -> void:
	# Targeted version -- player assigned this specific tree via click (A.3).
	# Also used by _start_gathering() after it resolves the nearest id.
	gather_target_id = id
	is_gathering = true
	set_new_destination(builder.get_structure_position(id))

# _carried_total() and _update_carried_log_visuals() now live on Carrier (carrier.gd).

func _update_gathering(delta: float) -> void:
	if not is_gathering:
		return
	if builder == null:
		is_gathering = false
		return
	
	# Tree already destroyed, go somewhere else
	var structure_index = builder.get_structure_index(gather_target_id)
	if structure_index < 0 or structure_index >= builder.structures.size() or not builder.structures[structure_index].gatherable:
		is_gathering = false
		_start_gathering()
		return
	
	# Still walking -- no progress, UNLESS already physically close enough
	# (guards against is_navigation_finished() never triggering -- see WORK_REACH).
	var target_pos = builder.get_structure_position(gather_target_id)
	var target_world_pos = Vector3(target_pos.x, global_position.y, target_pos.z)
	var close_enough = global_position.distance_to(target_world_pos) <= WORK_REACH
	if not nav_agent.is_navigation_finished() and not close_enough:
		return
	
	# Arrived -- contribute labor toward the shared, persisted chop progress.
	var gather_time = builder.structures[structure_index].gather_time
	var energy_required = builder.structures[structure_index].energy_required
	data.energy = clamp(data.energy - energy_required * delta, 0.0, 100.0)
	# add_chop_progress returns a Dictionary (not a bool) -- it's ALWAYS
	# truthy since it always has keys, even mid-chop. Must check the
	# "completed" key explicitly, not the dict itself.
	var result: Dictionary = builder.add_chop_progress(gather_target_id, delta / gather_time)
	if result.get("completed", false):
		is_gathering = false
		var energy_bonus: float = result.get("energy_bonus", 0.0)
		if energy_bonus > 0.0:
			data.energy = clamp(data.energy + energy_bonus, 0.0, 100.0)
		_start_pushing_nearest_prop()

# Called once a gather finishes. Rather than carrying anything, the citizen
# walks up to the nearest uncollected resource prop (spawned incrementally
# during the gather -- see Builder.add_chop_progress()) and leans on it,
# nudging it toward the spawn/stockpile point via the shared push logic in
# carrier.gd. If there's nothing to push (someone/something else already
# pushed every prop in), it just goes back to gathering.
func _start_pushing_nearest_prop() -> void:
	var nearest: RigidBody3D = null
	var nearest_dist := INF
	for prop in get_tree().get_nodes_in_group("resource_prop"):
		if not is_instance_valid(prop) or prop.collected:
			continue # already piled at the stockpile -- nothing left to push
		var d = global_position.distance_squared_to(prop.global_position)
		if d < nearest_dist:
			nearest_dist = d
			nearest = prop
	if nearest == null:
		_start_gathering()
		return
	is_pushing = true
	push_target = nearest
	push_repath_timer = 0.0
	set_new_destination(nearest.global_position)

func _update_pushing(delta: float) -> void:
	if not is_pushing:
		return
	# Prop already got collected (by us or anyone else nudging it in) --
	# resource_prop.gd no longer frees itself on collection (logs stay
	# visible forever as the stockpile pile -- see resource_prop.gd), so
	# check its `collected` flag instead of instance validity.
	if push_target == null or not is_instance_valid(push_target) or push_target.collected:
		is_pushing = false
		push_target = null
		_start_gathering()
		return
	push_repath_timer -= delta
	if push_repath_timer <= 0.0:
		push_repath_timer = PUSH_REPATH_INTERVAL
		set_new_destination(push_target.global_position)

# Begins walking to an already-assigned construction site
func _start_building(site_id: String) -> void:
	build_target_id = site_id
	is_building = true
	set_new_destination(builder.construction_sites[site_id].position)

func _update_building(delta: float) -> void:
	if not is_building:
		return
	if builder == null:
		is_building = false
		return
	
	# Site finished, got demolished, or was unassigned -- stop walking toward it
	if not builder.construction_sites.has(build_target_id):
		is_building = false
		build_target_id = NO_ID
		return
	
	var site = builder.construction_sites[build_target_id]
	if not data.id in site.assigned_builders:
		is_building = false
		build_target_id = NO_ID
		return
	
	# Building costs energy while actively assigned to a site -- same
	# per-second model as gathering (see Structure.build_energy_required).
	var structure: Structure = builder.structures[site.structure_index]
	data.energy = clamp(data.energy - structure.build_energy_required * delta, 0.0, 100.0)

func set_new_destination(target):
	nav_agent.target_position = target

func update_happiness_color():
	# Green when happy, red when unhappy
	var t = data.happiness / 100.0
	happiness_material.albedo_color = Color(1.0 - t, t, 0.0)
