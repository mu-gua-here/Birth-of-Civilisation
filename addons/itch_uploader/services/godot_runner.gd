@tool
extends RefCounted
class_name GodotRunner

func run_export(preset: ExportPreset, out_log: Array[String]) -> Error:
	var godot_path := OS.get_executable_path()
	out_log.append("Godot path: " + godot_path)
	var godot_args := [
		"--headless",
		"--export-release",
		preset.name,
	]
	out_log.append("Godot args: " + str(godot_args))
	var godot_result := OS.execute(
		godot_path,
		godot_args,
		out_log,
		true,
		false,
	)
	if godot_result < 0:
		return ERR_CANT_CREATE
	elif godot_result > 0:
		return FAILED
	
	return OK
