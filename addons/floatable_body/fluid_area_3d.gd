extends Area3D
class_name FluidArea3D

@export var density: float = 1.0
@export var simulate_turbulence := true

# Wave params -- MUST match the ShaderMaterial on the visible ocean mesh
# (addons/lowpolyterrain/shader/water.gdshader, Wave_Settings group) or this
# will drift out of sync with what's rendered again. Copy the tuned values
# from that material's Inspector into these fields by hand; there's no way
# to read them automatically since the shader lives on a resource inside
# terrain.res (binary, not something we script against).
@export var wave_direction := Vector2(1.0, 1.0)
@export var wave_speed := 1.0
@export var wave_scale := 0.2
@export var wave_height := 0.1
@export var low_poly_stepping := 12.0

const NOISE_PERIOD := 256.0

@onready var time := 0.0
var surface_height: float = 0.0

func _ready() -> void:
	surface_height = position.y
	for owner_id in get_shape_owners():
		var collision = shape_owner_get_owner(owner_id)
		if collision is CollisionShape3D:
			var shape: Shape3D = collision.shape
			if shape is BoxShape3D:
				var collision_top = Vector3(0.0, shape.size.y * 0.5, 0.0)
				surface_height += (collision.transform * collision_top).y
				break

	body_entered.connect(body_enter)
	body_exited.connect(body_exit)


func _physics_process(delta: float) -> void:
	time += delta


func body_enter(body: PhysicsBody3D) -> void:
	if body.has_method("fluid_area_enter"):
		body.fluid_area_enter(self)


func body_exit(body: PhysicsBody3D) -> void:
	if body.has_method("fluid_area_exit"):
		body.fluid_area_exit(self)


func get_height(pos: Vector3) -> float:
	return surface_height + _low_poly_wave(Vector2(pos.x, pos.z), time)

# --- Ported from water.gdshader's low_poly_wave()/hash()/value_noise() --
# (addons/lowpolyterrain/shader/water.gdshader) -- same formula, evaluated
# on the CPU instead of the GPU, so wave height here always matches what's
# actually rendered instead of drifting from independent noise. Keep this
# in sync if the shader's wave math ever changes.

func _fract(x: float) -> float:
	return x - floor(x)

func _hash(p: Vector2) -> float:
	var wrapped := Vector2(fposmod(p.x, NOISE_PERIOD), fposmod(p.y, NOISE_PERIOD))
	return _fract(sin(wrapped.dot(Vector2(127.1, 311.7))) * 43758.5453123)

func _value_noise(p: Vector2) -> float:
	var i := p.floor()
	var f := p - i
	f = f * f * (Vector2(3.0, 3.0) - f * 2.0) # smoothstep, matches shader
	return lerp(
		lerp(_hash(i), _hash(i + Vector2(1.0, 0.0)), f.x),
		lerp(_hash(i + Vector2(0.0, 1.0)), _hash(i + Vector2(1.0, 1.0)), f.x),
		f.y
	)

func _low_poly_wave(uv: Vector2, time_val: float) -> float:
	var grid_uv := (uv * low_poly_stepping).floor() / low_poly_stepping

	var move := Vector2(
		fposmod(wave_direction.x * time_val * wave_speed * 0.1, TAU),
		fposmod(wave_direction.y * time_val * wave_speed * 0.1, TAU)
	)
	var w1 := sin(grid_uv.x * 4.0 * wave_scale + move.x) * cos(grid_uv.y * 4.0 * wave_scale + move.y)

	var drift := Vector2(
		fposmod(wave_direction.x * time_val * wave_speed * 0.05, NOISE_PERIOD),
		fposmod(wave_direction.y * time_val * wave_speed * 0.05, NOISE_PERIOD)
	)
	var w2 := _value_noise(grid_uv * wave_scale * 2.0 + drift) * 2.0 - 1.0

	var detail_amount := 0.15 * wave_scale * 0.5
	return (w1 + w2 * detail_amount) * wave_height
