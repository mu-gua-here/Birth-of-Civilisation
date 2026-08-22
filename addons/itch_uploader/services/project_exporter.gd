@tool
extends RefCounted
class_name ProjectExporter

var _itch_page_url_storage: ItchPageUrlStorage
var _butler_runner: ButlerRunner
var _godot_runner: GodotRunner
var _dir_access := DirAccess.open(".")

func _init(
	itch_page_url_storage: ItchPageUrlStorage, 
	butler_runner: ButlerRunner, 
	godot_runner: GodotRunner,
) -> void:
	self._itch_page_url_storage = itch_page_url_storage
	self._butler_runner = butler_runner
	self._godot_runner = godot_runner

func export_preset(preset: ExportPreset, out_log: Array[String]) -> Error:
	var export_dir := preset.path.get_base_dir()
	if not _dir_access.dir_exists(export_dir):
		out_log.append("Creating export dir: " + export_dir)
		var make_dir_result := _dir_access.make_dir_recursive(export_dir)
		if make_dir_result != OK:
			out_log.append("Could not create export dir: " + error_string(make_dir_result))
			return ERR_CANT_CREATE
	
	var godot_error := _godot_runner.run_export(preset, out_log)
	if godot_error != OK:
		out_log.append("Could not run Godot: " + error_string(godot_error))
		return ERR_CANT_CREATE
	
	var page_info := _itch_page_url_storage.get_page_info()
	var butler_error := _butler_runner.push_build(preset, page_info, out_log)
	if butler_error != OK:
		out_log.append("Could not run Butler: " + error_string(butler_error))
		return ERR_CANT_CREATE
	
	out_log.append("Export and upload finished successfully")
	return OK
