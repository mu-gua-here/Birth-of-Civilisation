extends AudioStreamPlayer

@export var camera: Camera3D
@export var water_level := 0.0
@export var max_depth := 30.0
@export var bus_name := "Underwater"

var bus_idx: int
var eq: AudioEffectEQ10
var reverb: AudioEffectReverb
var chorus: AudioEffectChorus

var _sub := 0.0    # 0 = above water, 1 = submerged (fast, smoothed)
var _depth := 0.0  # 0..1 how deep (slow, smoothed)

func _ready():
	bus_idx = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		push_error("Bus '%s' not found" % bus_name)
		set_process(false)
		return
	eq = AudioServer.get_bus_effect(bus_idx, 0) as AudioEffectEQ10
	reverb = AudioServer.get_bus_effect(bus_idx, 1) as AudioEffectReverb
	chorus = AudioServer.get_bus_effect(bus_idx, 2) as AudioEffectChorus
	if eq == null or reverb == null or chorus == null:
		push_error("Bus needs EQ10 (0), Reverb (1), Chorus (2)")
		set_process(false)

func _process(delta):
	if camera == null:
		camera = get_viewport().get_camera_3d()
		if camera == null:
			return

	var depth_m = max(0.0, water_level - camera.global_position.y)
	var submerged = 1.0 if depth_m > 0.0 else 0.0
	var target_depth = clamp(depth_m / max_depth, 0.0, 1.0)

	_sub = lerp(_sub, submerged, 1.0 - exp(-10.0 * delta))
	_depth = lerp(_depth, target_depth, 1.0 - exp(-3.0 * delta))

	# EQ10 bands: 0=31Hz 1=62 2=125 3=250 4=500 5=1k 6=2k 7=4k 8=8k 9=16k
	var cut_strength = _sub * lerp(0.5, 1.0, _depth)
	var cuts = [0.0, 0.0, 0.0, 0.0, -2.0, -6.0, -12.0, -24.0, -40.0, -60.0]
	for i in 10:
		eq.set_band_gain_db(i, cuts[i] * cut_strength)

	# Reverb: more enclosed the deeper you go
	reverb.room_size = 0.6
	reverb.damping = lerp(0.5, 0.9, _depth)
	reverb.wet = _sub * lerp(0.15, 0.4, _depth)
	reverb.dry = lerp(1.0, 0.7, _sub)

	# Wavy: deeper and slower with depth
	for v in chorus.voice_count:
		chorus.set_voice_depth_ms(v, _sub * lerp(2.0, 8.0, _depth))
		chorus.set_voice_rate_hz(v, lerp(1.0, 0.3, _depth))

	# Softer
	volume_db = _sub * lerp(-4.0, -14.0, _depth)
