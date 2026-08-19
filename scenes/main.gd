extends Node3D

# Detect renderer and change
func _ready():
	# ENSURE CONSISTENT LIGHTING BETWEEN RENDERERS
	var env_path := "res://environments/native-main-environment.tres"
	if RenderingServer.get_rendering_device() == null:
		print("Renderer: Compatibility")
		# Compatibility/GLES3 has no RenderingDevice (Forward+/Mobile-Vulkan only)
		env_path = "res://environments/compat-main-environment.tres"
		$WorldEnvironment.environment = load(env_path)
