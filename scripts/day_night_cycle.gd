extends Node3D
class_name DayNightCycle

## Lightweight day/night cycle. No shaders, no post-process — just rotates the
## sun light and lerps a couple of colors on the WorldEnvironment. Cheap enough
## for web export.
##
## time_of_day is 0..1: 0.0 = midnight, 0.25 = sunrise, 0.5 = noon, 0.75 = sunset.

@export var enabled := true

@export_group("General")
## How many real-world seconds a full in-game day takes.
@export var day_length_seconds: float = 600.0
@export_range(0.0, 1.0) var time_of_day: float = 0.25
## Where the cycle starts, 0..1
@export_range(0.0, 1.0) var start_time: float = 0.25

@export var sun: DirectionalLight3D
@export var world_environment: WorldEnvironment

@export_group("Light")
@export var noon_light_color: Color = Color(1.0, 0.97, 0.9)
@export var noon_light_energy: float = 1.1
@export var horizon_light_color: Color = Color(1.0, 0.55, 0.35)
@export var horizon_light_energy: float = 0.6
@export var night_light_color: Color = Color(0.25, 0.3, 0.45)
@export var night_light_energy: float = 0.05

@export_group("Ambient")
@export var noon_ambient_color: Color = Color(0.662745, 0.694118, 0.772549)
@export var night_ambient_color: Color = Color(0.08, 0.09, 0.14)
@export var noon_bg_color: Color = Color(0.560784, 0.592157, 0.670588)
@export var night_bg_color: Color = Color(0.02, 0.02, 0.05)

## Only matters if the WorldEnvironment's background_mode is Sky (BG_SKY) with a
## ProceduralSkyMaterial assigned -- see native-main-environment.tres. Ignored under
## background_mode Color, where noon_bg_color/night_bg_color above are what's visible instead.
@export_group("Sky")
@export var noon_sky_top_color: Color = Color(0.30, 0.45, 0.75)
@export var night_sky_top_color: Color = Color(0.01, 0.01, 0.04)
@export var noon_sky_horizon_color: Color = Color(0.68, 0.72, 0.78)
@export var night_sky_horizon_color: Color = Color(0.03, 0.03, 0.07)
@export var noon_sky_energy: float = 1.0
@export var night_sky_energy: float = 0.15

@export_group("Fog")
@export var noon_fog_color: Color = Color(0.860812, 0.8745884, 0.897545)
@export var night_fog_color: Color = Color(0.05, 0.06, 0.1)
@export var noon_fog_density: float = 0.015
@export var night_fog_density: float = 0.035

# Set by other scripts (view.gd) to stop this script's own fog lerp from
# fighting theirs -- e.g. while the camera is underwater.
var suppress_fog := false

func _ready() -> void:
	time_of_day = start_time
	_apply(time_of_day)


func _process(delta: float) -> void:
	# NOTE: `enabled` used to only gate whether time_of_day advances, while
	# _apply() ran every frame regardless
	if not enabled:
		_apply(time_of_day)
		return
	if day_length_seconds <= 0.0:
		day_length_seconds = 1.0
	time_of_day = fposmod(time_of_day + delta / day_length_seconds, 1.0)
	_apply(time_of_day)


func _apply(t: float) -> void:
	var angle := t * TAU
	# -1 at midnight, 1 at noon, 0 right at sunrise/sunset.
	var height := sin(angle - PI / 2.0)
	var day_pct: float = clamp(height, 0.0, 1.0)
	var horizon_pct: float = clamp(1.0 - abs(height) * 4.0, 0.0, 1.0)
	
	# print(time_of_day)
	
	if sun:
		sun.rotation.x = angle + PI / 2.0

		var color := night_light_color.lerp(noon_light_color, day_pct)
		sun.light_color = color.lerp(horizon_light_color, horizon_pct)

		var energy: float = lerp(night_light_energy, noon_light_energy, day_pct)
		sun.light_energy = lerp(energy, horizon_light_energy, horizon_pct)

		sun.shadow_enabled = day_pct > 0.02 or horizon_pct > 0.3

	if world_environment and world_environment.environment:
		var env := world_environment.environment
		env.ambient_light_color = night_ambient_color.lerp(noon_ambient_color, day_pct)
		env.background_color = night_bg_color.lerp(noon_bg_color, day_pct)

		# Sky reactivity -- only does anything when background_mode is Sky with a
		# ProceduralSkyMaterial assigned (see the Sky export group above for why).
		if env.sky and env.sky.sky_material is ProceduralSkyMaterial:
			var sky_mat: ProceduralSkyMaterial = env.sky.sky_material
			sky_mat.sky_top_color = night_sky_top_color.lerp(noon_sky_top_color, day_pct)
			sky_mat.sky_horizon_color = night_sky_horizon_color.lerp(noon_sky_horizon_color, day_pct)
			sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
			sky_mat.sky_energy_multiplier = lerp(night_sky_energy, noon_sky_energy, day_pct)

		# Fog reactivity -- thicker and bluer at night, thin and warm at noon.
		# Skipped while suppress_fog is set (e.g. by view.gd while the camera's
		# underwater) so day/night cycling doesn't fight the underwater tint.
		if not suppress_fog:
			env.fog_light_color = night_fog_color.lerp(noon_fog_color, day_pct)
			env.fog_density = lerp(night_fog_density, noon_fog_density, day_pct)
