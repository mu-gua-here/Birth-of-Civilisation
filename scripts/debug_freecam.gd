extends Node
class_name DebugFreecam

## In-game debug freecam, debug builds only. F8 toggles.
## Fly with WASD, Q/E down/up, hold right mouse to look, Shift = fast, Ctrl = slow.
##
## Why this exists: Godot's own Game-tab freelook is applied as a viewport override that scripts
## can't see, so anything that follows "the camera" (the WaterSurface grid) stays behind with the
## game camera. This is a real Camera3D made current, so get_viewport().get_camera_3d()
## returns it and the water follows. The Player and View are paused while it is active.

@export var move_speed := 12.0
@export var fast_multiplier := 4.0
@export var look_sensitivity := 0.003
## Node names (children of this node's parent) paused while flying, so WASD doesn't also walk the player.
@export var paused_nodes: PackedStringArray = ["Player", "View"]

var _camera: Camera3D
var _previous_camera: Camera3D
var _active := false
var _yaw := 0.0
var _pitch := 0.0
var _looking := false


func _ready() -> void:
	if not OS.is_debug_build():
		set_process(false)
		set_process_unhandled_input(false)
		return
	set_process(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F8:
		_set_active(not _active)
		get_viewport().set_input_as_handled()
		return
	if not _active:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_looking = event.pressed
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _looking else Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseMotion and _looking:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -1.55, 1.55)
		_camera.basis = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))


func _process(delta: float) -> void:
	var dir := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir -= _camera.global_basis.z
	if Input.is_physical_key_pressed(KEY_S): dir += _camera.global_basis.z
	if Input.is_physical_key_pressed(KEY_D): dir += _camera.global_basis.x
	if Input.is_physical_key_pressed(KEY_A): dir -= _camera.global_basis.x
	if Input.is_physical_key_pressed(KEY_E): dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q): dir += Vector3.DOWN
	var speed := move_speed
	if Input.is_physical_key_pressed(KEY_SHIFT): speed *= fast_multiplier
	if Input.is_physical_key_pressed(KEY_CTRL): speed *= 0.25
	_camera.global_position += dir.normalized() * speed * delta


func _set_active(on: bool) -> void:
	if on == _active:
		return
	_active = on
	set_process(on)
	var parent := get_parent()
	for node_name in paused_nodes:
		var n := parent.get_node_or_null(node_name)
		if n:
			n.process_mode = Node.PROCESS_MODE_DISABLED if on else Node.PROCESS_MODE_INHERIT

	if on:
		_previous_camera = get_viewport().get_camera_3d()
		_camera = Camera3D.new()
		_camera.far = 2000.0
		add_child(_camera)
		if _previous_camera:
			_camera.global_transform = _previous_camera.global_transform
			_camera.fov = _previous_camera.fov
			_camera.near = _previous_camera.near
		var euler := _camera.global_basis.get_euler()
		_pitch = euler.x
		_yaw = euler.y
		_camera.make_current()
		print("[freecam] on -- WASD/QE fly, hold RMB to look, Shift fast, F8 to exit")
	else:
		_looking = false
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if _previous_camera and is_instance_valid(_previous_camera):
			_previous_camera.make_current()
		_camera.queue_free()
		_camera = null
		print("[freecam] off")
