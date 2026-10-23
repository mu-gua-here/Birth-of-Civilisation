extends Node
class_name PushSource

## Child node for a RigidBody3D whose root script belongs to someone else (e.g. the boulder, whose
## root script is the floatable_body addon). Makes the parent shove carriers on contact, without
## touching the parent's script. Add it as a child of the body, nothing else needed.

func _ready() -> void:
	var body := get_parent() as RigidBody3D
	if body == null:
		push_error("PushSource must be a child of a RigidBody3D.")
		return
	body.contact_monitor = true
	body.max_contacts_reported = 8

func _physics_process(_delta: float) -> void:
	var body := get_parent() as RigidBody3D
	if body != null:
		PhysicsPush.solve_rigid_contacts(body)
