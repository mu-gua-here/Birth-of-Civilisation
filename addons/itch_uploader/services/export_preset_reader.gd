@tool
extends RefCounted
class_name ExportPresetReader

# Godot platform to Itch channel map
const ITCH_CHANNELS := {
	"Web": "web",
	"Windows Desktop": "windows",
	"macOS": "macos",
	"Linux": "linux",
}

var _dir_access := DirAccess.open('.')

func read_export_presets() -> Array[ExportPreset]:
	var export_presets := ConfigFile.new()
	var error := export_presets.load("res://export_presets.cfg")
	if error != OK:
		push_error("Could not load export_presets.cfg: " + error_string(error))
		return []
	
	var godot_version := Engine.get_version_info()
	var godot_version_number: int = godot_version.hex
	
	if godot_version_number < 0x040400:
		push_error("Unsupported Godot version: " + godot_version.string)
		return []
	elif godot_version_number < 0x040700:
		return _parse_export_presets_pre_4_7(export_presets)
	else:
		return _parse_export_presets_post_4_7(export_presets)

func _parse_export_presets_pre_4_7(export_presets: ConfigFile) -> Array[ExportPreset]:
	var project_dir := _dir_access.get_current_dir()
	
	var presets: Array[ExportPreset] = []
	
	for section in export_presets.get_sections():
		if not section.begins_with("preset."):
			continue
		if section.ends_with(".options"):
			continue
		
		var is_runnable = export_presets.get_value(section, "runnable", false)
		if not is_runnable:
			continue
		
		var platform = export_presets.get_value(section, "platform")
		if not platform or platform not in ITCH_CHANNELS:
			continue
		
		var export_path = project_dir.path_join(export_presets.get_value(section, "export_path"))
		
		presets.append(ExportPreset.new(
			export_presets.get_value(section, "name"),
			platform,
			export_path,
			ITCH_CHANNELS[platform],
		))
	
	return presets

func _parse_export_presets_post_4_7(export_presets: ConfigFile) -> Array[ExportPreset]:
	var project_dir := _dir_access.get_current_dir()
	
	var sections := export_presets.get_sections()
	
	var presets: Array[ExportPreset] = []
	var runnable_presets: Dictionary[String, String] = {}
	
	for section in sections:
		if section != "runnable_presets":
			continue
		
		var platforms := export_presets.get_section_keys(section)
		for platform in platforms:
			var preset_name := export_presets.get_value(section, platform)
			if not preset_name or not preset_name is String:
				continue
			
			runnable_presets[preset_name] = platform
	
	for section in sections:
		if not section.begins_with("preset."):
			continue
		if section.ends_with(".options"):
			continue
		
		var preset_name = export_presets.get_value(section, "name")
		if not preset_name in runnable_presets:
			continue
		
		var platform = export_presets.get_value(section, "platform")
		if not platform or platform not in ITCH_CHANNELS:
			continue
		
		var export_path = project_dir.path_join(export_presets.get_value(section, "export_path"))
		
		presets.append(ExportPreset.new(
			preset_name,
			platform,
			export_path,
			ITCH_CHANNELS[platform],
		))
	
	return presets
