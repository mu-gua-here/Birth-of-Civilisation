@tool
extends RefCounted
class_name ButlerRunner

const BUTLER_SETTINGS_FILE := "addons/itch_uploader/butler.cfg"
const DEFAULT_BUTLER_PATH := "butler"

var _butler_settings := ConfigFile.new()

func push_build(preset: ExportPreset, page_info: ItchPageInfo, out_log: Array[String]) -> Error:
	var butler_path := read_butler_executable()
	if butler_path.is_empty():
		butler_path = DEFAULT_BUTLER_PATH
	out_log.append("Butler path: " + butler_path)
	
	var butler_args := [
		"push",
		preset.path.get_base_dir(),
		"{0}/{1}:{2}".format([
			page_info.user,
			page_info.project,
			preset.channel,
		]),
	]
	out_log.append("Butler args: " + str(butler_args))
	
	var butler_result := OS.execute(
		butler_path,
		butler_args,
		out_log,
		true,
		false,
	)
	if butler_result < 0:
		return ERR_CANT_CREATE
	elif butler_result > 0:
		return FAILED
	
	return OK

static func is_butler_executable_valid(path: String) -> bool:
	if path.is_empty():
		path = DEFAULT_BUTLER_PATH

	var output: Array[String] = []
	var result := OS.execute(path, ["--help"], output, true, false)

	if result != 0:
		return false

	if output.is_empty():
		return false

	var output_str := output[0]
	if not output_str.contains("Your happy little itch.io helper"):
		return false

	return true

func read_butler_executable() -> String:
	_butler_settings.clear()
	var result := _butler_settings.load(BUTLER_SETTINGS_FILE)
	if result != OK:
		return ""

	return _butler_settings.get_value("butler", "path", "")

func save_butler_executable(path: String):
	_butler_settings.clear()
	_butler_settings.set_value("butler", "path", path)
	_butler_settings.save(BUTLER_SETTINGS_FILE)
