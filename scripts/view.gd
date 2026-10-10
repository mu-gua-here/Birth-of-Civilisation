extends Node3D

# Object to track for camera
@export var target: Node3D
@export var follow_speed: float = 10.0

@onready var spring_arm := $SpringArm3D as SpringArm3D
@onready var copy_target := $SpringArm3D/CopyMe as Marker3D
@onready var camera := $Camera as Camera3D

# Zoom settings
@export var max_zoom := 10.0
@export var min_zoom := 1.5
@export var scroll_zoom_speed := 5.0
var zoom: float = 3.0

# Viewing settings
@export var springarm_enabled := true
@export var view_angle_restricted := true

# Viewing / Sensitivity
@export_range(0.1, 5.0) var mouse_sensitivity = 0.5

# Keyboard orbit: arrow keys (camera_left/right/forward/back actions), degrees per second
@export var key_rotate_speed := 90.0

# Browsers never send InputEventPanGesture/MagnifyGesture, so on web a trackpad's two-finger
# swipe arrives as mouse-wheel button events (which the zoom_in/zoom_out actions used to grab).
# On web: swipe = orbit, pinch (browser sends it as Ctrl+wheel) = zoom, +/- keys still zoom.
@export var web_wheel_rotates := true
@export var wheel_rotate_sensitivity := 0.7  # degrees per unit of wheel 'factor' -- tune on web
@export var pinch_zoom_speed := 0.5

# Prevent hitting exact 0.0° and -90.0° singularities
@export_range(-89.9, 89.9) var max_tilt_limit := 44.9
@export_range(-179.9, 0.1) var min_tilt_limit := -89.9

# Mouse/Camera Euler angles
var camera_rotation: Vector3
# Store current interpolated rotation in script memory
var current_rotation: Vector3

var zoom_speed: float = 0.0
const ZOOM_MAX_SPEED := 40.0
const ZOOM_ACCEL := 40.0
const ZOOM_DECEL := 80.0

func _ready():
	camera_rotation = rotation_degrees
	current_rotation = rotation_degrees
	add_to_group("view")
	camera.make_current()

func _physics_process(delta: float) -> void:
	if not target:
		return
		
	# Smoothly follow the target's location
	global_position = global_position.lerp(target.global_position, follow_speed * delta)

func _process(delta: float) -> void:
	# Lerp pure script variables using lerp_angle (NEVER read rotation_degrees!)
	var lerp_weight = delta * 12.0
	
	current_rotation.x = rad_to_deg(lerp_angle(deg_to_rad(current_rotation.x), deg_to_rad(camera_rotation.x), lerp_weight))
	current_rotation.y = rad_to_deg(lerp_angle(deg_to_rad(current_rotation.y), deg_to_rad(camera_rotation.y), lerp_weight))
	
	# Apply memory vector to node transform
	rotation_degrees = current_rotation
	
	# Handle SpringArm and Camera Zooming
	spring_arm.spring_length = zoom
	
	# Separate Camera smooth positioning relative to SpringArm Marker
	camera.global_position = camera.global_position.lerp(copy_target.global_position, delta * 15.0)
	camera.global_rotation = copy_target.global_rotation
	
	handle_input(delta)

func handle_input(_delta: float):
	# CAMERA ZOOMING (Mouse Wheel)
	if not _wheel_rotates():
		if Input.is_action_just_pressed("zoom_in"):
			zoom = max(min_zoom, zoom - scroll_zoom_speed)
		if Input.is_action_just_pressed("zoom_out"):
			zoom = min(max_zoom, zoom + scroll_zoom_speed)
	
	# Continuous zoom (Keyboard +/-)
	var zoom_axis = Input.get_axis("zoom_in_hold", "zoom_out_hold")
	if zoom_axis != 0:
		zoom_speed = move_toward(zoom_speed, zoom_axis * ZOOM_MAX_SPEED, ZOOM_ACCEL * _delta)
	else:
		zoom_speed = move_toward(zoom_speed, 0.0, ZOOM_DECEL * _delta)
	
	zoom = clamp(zoom + _delta * zoom_speed, min_zoom, max_zoom)

	# Arrow-key orbit. Left arrow turns the view left / Up arrow tilts up, matching
	# what dragging the mouse left/up does in _input().
	var yaw_axis := Input.get_axis("camera_right", "camera_left")
	var pitch_axis := Input.get_axis("camera_back", "camera_forward")
	if yaw_axis != 0.0 or pitch_axis != 0.0:
		camera_rotation.y += yaw_axis * key_rotate_speed * _delta
		camera_rotation.x += pitch_axis * key_rotate_speed * _delta
		_clamp_pitch()

func _wheel_rotates() -> bool:
	return web_wheel_rotates and OS.has_feature("web")

func _clamp_pitch() -> void:
	if view_angle_restricted:
		camera_rotation.x = clamp(camera_rotation.x, min_tilt_limit, max_tilt_limit)

func _input(event):
	# Trackpad gesture support
	if event is InputEventPanGesture:
		camera_rotation.y -= event.delta.x * mouse_sensitivity
		camera_rotation.x -= event.delta.y * mouse_sensitivity
	
	# Web trackpad: two-finger swipe = wheel events. Ctrl+wheel = pinch.
	elif event is InputEventMouseButton and event.pressed and _wheel_rotates() \
			and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var amount: float = clampf(event.factor, 0.0, 10.0)
		if event.ctrl_pressed or event.meta_pressed:
			if event.button_index == MOUSE_BUTTON_WHEEL_UP:
				zoom = clamp(zoom - amount * pinch_zoom_speed, min_zoom, max_zoom)
			elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				zoom = clamp(zoom + amount * pinch_zoom_speed, min_zoom, max_zoom)
		else:
			var step := amount * wheel_rotate_sensitivity
			match event.button_index:
				MOUSE_BUTTON_WHEEL_UP: camera_rotation.x += step
				MOUSE_BUTTON_WHEEL_DOWN: camera_rotation.x -= step
				MOUSE_BUTTON_WHEEL_LEFT: camera_rotation.y += step
				MOUSE_BUTTON_WHEEL_RIGHT: camera_rotation.y -= step
		get_viewport().set_input_as_handled()

	elif event is InputEventMagnifyGesture:
		zoom = clamp(zoom / event.factor, min_zoom, max_zoom)
	
	# Clamp Pitch (Up/Down angle)
	if view_angle_restricted:
		camera_rotation.x = clamp(camera_rotation.x, min_tilt_limit, max_tilt_limit)
