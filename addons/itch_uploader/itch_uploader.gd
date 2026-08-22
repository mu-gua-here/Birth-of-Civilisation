@tool
extends EditorPlugin
class_name ItchUploader

const TOOL_MENU_ITEM_NAME := "Export and Upload to Itch..."
const SETTINGS_TAB_NAME := "itch_uploader"

const EXPORT_SETTINGS_MODAL_RES := preload("res://addons/itch_uploader/ui/export_settings_modal/export_settings_modal.tscn")
var _export_settings_modal: ExportSettingsModal = null

const EXPORT_PROCESS_MODAL_RES := preload("res://addons/itch_uploader/ui/export_process_modal/export_process_modal.tscn")
var _export_process_modal: ExportProcessModal = null

var _export_preset_reader := ExportPresetReader.new()
var _itch_page_url_storage := ItchPageUrlStorage.new()
var _butler_runner := ButlerRunner.new()
var _godot_runner := GodotRunner.new()
var _project_exporter := ProjectExporter.new(_itch_page_url_storage, _butler_runner, _godot_runner)

func _enter_tree():
	add_tool_menu_item(TOOL_MENU_ITEM_NAME, _open_export_settings_modal)
	_itch_page_url_storage.register_project_settings()

func _exit_tree():
	remove_tool_menu_item(TOOL_MENU_ITEM_NAME)
	_itch_page_url_storage.unregister_project_settings()

static func get_setting_name(field: String) -> String:
	return "{0}/{1}".format([SETTINGS_TAB_NAME, field])

func _open_export_settings_modal():
	_export_settings_modal = EXPORT_SETTINGS_MODAL_RES.instantiate()
	_export_settings_modal.theme = EditorInterface.get_editor_theme()
	_export_settings_modal.export_presets = _export_preset_reader.read_export_presets()
	_export_settings_modal.butler_runner = _butler_runner
	_export_settings_modal.connect("export_accepted", self._start_export)
	EditorInterface.popup_dialog_centered(_export_settings_modal)

func _start_export(selected_export_presets: Array[ExportPreset]):
	var error_messages := []
	
	if _itch_page_url_storage.get_page_info() == null:
		error_messages.append(
			"The Itch.io page URL is incorrect. It should look like this: {0}. Please check your project settings."
				.format([_itch_page_url_storage.get_example()])
		)
		
	if not _butler_runner.is_butler_executable_valid(_butler_runner.read_butler_executable()):
		error_messages.append(
			"The Butler path is incorrect. Please choose a correct Butler executable path and try again."
		)
	
	if not error_messages.is_empty():
		var error_dialog := AcceptDialog.new()
		error_dialog.title = "Export errors"
		var message := ""
		for error in error_messages:
			message += error + "\n\n"
		error_dialog.dialog_text = message
		EditorInterface.popup_dialog_centered(error_dialog)
		return
	
	_export_process_modal = EXPORT_PROCESS_MODAL_RES.instantiate()
	_export_process_modal.theme = EditorInterface.get_editor_theme()
	_export_process_modal.project_exporter = _project_exporter
	_export_process_modal.itch_page_url_storage = _itch_page_url_storage
	_export_process_modal.export_presets = selected_export_presets
	EditorInterface.popup_dialog_centered(_export_process_modal)
