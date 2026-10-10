extends RefCounted
class_name FluidInteractor3D

class Floater3D:
	var position: Vector3
	var radius: float
	var state: int
	
	func _init(pos: Vector3, r: float):
		position = pos
		radius = r
	
	func is_in_fluid() -> bool:
		return state >= 2
	
	func is_just_entered_to_fluid() -> bool:
		return state == 2

	func is_just_exited_from_fluid() -> bool:
		return state == 1


var floaters: Array[Floater3D]
var volume: float = 0.0
var fluid_area: FluidArea3D = null
var float_position: Vector3 = Vector3.ZERO
var float_force: Vector3 = Vector3.ZERO


func _init():
	floaters = []


func process(transform: Transform3D, mass: float = 1.0, gravity_scale: float = 1.0) -> void:
	float_position = Vector3.ZERO
	float_force = Vector3.ZERO

	if fluid_area == null:
		# Still have to decay each floater's submersion history even with no
		# fluid area -- without this, a floater whose state hit >=2 while
		# submerged stays "in fluid" forever after exiting, since nothing
		# else ever shifts state back down (see Floater3D.is_in_fluid()).
		for floater in floaters:
			floater.state >>= 1
		return

	var sum_positions := Vector3.ZERO
	var sum_weights := 0.0
	var max_diff := 0.0
	var min_diff := 1000000.0
	# Floater radii are authored in the body's local units but positions go through the full
	# transform, so a scaled body (e.g. the 0.5-scale Player) must scale the radius too, or the
	# floaters extend far below the real collider and the body rides too high.
	var radius_scale: float = transform.basis.get_scale().y
	for floater in floaters:
		var floater_position = transform * floater.position
		var world_radius: float = floater.radius * radius_scale
		var surface_height = fluid_area.get_height(floater_position)
		var diff_b: float = floater_position.y - world_radius - surface_height;
		var diff_u: float = floater_position.y + world_radius - surface_height;
		
		max_diff = max(max_diff, diff_u)
		min_diff = min(min_diff, diff_b)
		floater.state >>= 1
		if diff_b < 0:
			sum_positions += floater_position * -diff_b
			sum_weights += -diff_b
			floater.state |= 2
	
	if sum_weights > 0.0:
		var float_volume: float = volume
		var float_diff: float = abs(min_diff - max_diff)
		if max_diff > 0.0:
			float_volume *= abs(min_diff) / float_diff
			float_diff = abs(min_diff)

		float_position = sum_positions / sum_weights - transform.origin
		float_force = Vector3.UP * float_diff * float_volume / mass * fluid_area.density * 1000.0 * gravity_scale


func add_collision_shape(collision: CollisionShape3D) -> void:
	var shape: Shape3D = collision.shape
	if shape is BoxShape3D:
		var extent: Vector3 = shape.size * 0.5
		add_floater(collision.transform * Vector3(-extent.x, 0.0, -extent.z))
		add_floater(collision.transform * Vector3(-extent.x, 0.0,  extent.z))
		add_floater(collision.transform * Vector3( extent.x, 0.0, -extent.z))
		add_floater(collision.transform * Vector3( extent.x, 0.0,  extent.z))
		volume += shape.size.x * shape.size.y * shape.size.z
	elif shape is SphereShape3D:
		add_floater(collision.position, shape.radius)
		volume += (4.0 / 3.0) * PI * pow(shape.radius, 3.0)
	elif shape is CylinderShape3D:
		add_floater(collision.transform * Vector3(0.0, -shape.height * 0.5 + shape.radius, 0.0), shape.radius)
		add_floater(collision.transform * Vector3(0.0, +shape.height * 0.5 - shape.radius, 0.0), shape.radius)
		volume += PI * pow(shape.radius, 2.0) * shape.height
	elif shape is CapsuleShape3D:
		add_floater(collision.transform * Vector3(0.0, -shape.height * 0.5 + shape.radius, 0.0), shape.radius)
		add_floater(collision.transform * Vector3(0.0, +shape.height * 0.5 - shape.radius, 0.0), shape.radius)
		volume += (4.0 / 3.0) * PI * pow(shape.radius, 3.0) + PI * pow(shape.radius, 2.0) * shape.height
	elif shape != null:
		# Fallback for any other shape (convex, concave, ...): approximate it by its
		# bounding box so a single imported hull still floats without extra setup.
		var mesh := shape.get_debug_mesh()
		if mesh == null:
			return
		var aabb := mesh.get_aabb()
		var c := aabb.get_center()
		var e := aabb.size * 0.5
		add_floater(collision.transform * (c + Vector3(-e.x, 0.0, -e.z)))
		add_floater(collision.transform * (c + Vector3(-e.x, 0.0,  e.z)))
		add_floater(collision.transform * (c + Vector3( e.x, 0.0, -e.z)))
		add_floater(collision.transform * (c + Vector3( e.x, 0.0,  e.z)))
		volume += aabb.size.x * aabb.size.y * aabb.size.z * abs(collision.transform.basis.determinant())


func add_floater(position: Vector3, radius: float = 0.0) -> void:
	floaters.push_back(Floater3D.new(position, radius))


func clear_floaters() -> void:
	floaters.clear()


func get_floaters() -> Array[Floater3D]:
	return floaters


func fluid_area_enter(area: FluidArea3D) -> void:
	fluid_area = area


func fluid_area_exit(area: FluidArea3D) -> void:
	if fluid_area == area:
		fluid_area = null
