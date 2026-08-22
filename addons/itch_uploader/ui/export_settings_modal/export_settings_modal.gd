@tool
extends Window
class_name ExportSettingsModal

signal export_accepted(selected_export_presets: Array[ExportPreset])

var export_presets: Array[ExportPreset] = []
var butler_runner: ButlerRunner

@onready var _butler_path_picker := %"ButlerPathPicker"
@onready var _butler_error_dialog := %"ButlerErrorDialog"
@onready var _export_preset_container := %"ExportPresetsContainer"
@onready var _no_presets_dialog := %"NoPresetsDialog"
@onready var _export_preset_warning := %"ExportPathWarningContainer"

var _export_preset_checkboxes: Dictionary[ExportPreset, CheckBox] = {}

func _ready():
	if is_part_of_edited_scene():
		return

	_butler_path_picker.path = butler_runner.read_butler_executable()

	for preset in export_presets:
		var checkbox := CheckBox.new()
		checkbox.text = preset.name
		checkbox.button_pressed = true
		_export_preset_checkboxes[preset] = checkbox
		_export_preset_container.add_child(checkbox)
	
	_export_preset_warning.visible = false
	for index_1 in range(len(export_presets)):
		for index_2 in range(index_1 + 1, len(export_presets)):
			var export_dir_1 := export_presets[index_1].path.get_base_dir()
			var export_dir_2 := export_presets[index_2].path.get_base_dir()
			
			if export_dir_1.begins_with(export_dir_2) or export_dir_2.begins_with(export_dir_1):
				_export_preset_warning.visible = true

func _on_close_requested():
	queue_free()

func _on_upload_button_pressed():
	var butler_path: String = _butler_path_picker.path

	if not ButlerRunner.is_butler_executable_valid(butler_path):
		_butler_error_dialog.show()
		return

	butler_runner.save_butler_executable(butler_path)

	var selected_export_presets: Array[ExportPreset] = []
	for preset in export_presets:
		if preset not in _export_preset_checkboxes:
			continue

		var checkbox := _export_preset_checkboxes[preset]
		if not checkbox.button_pressed:
			continue

		selected_export_presets.append(preset)

	if selected_export_presets.is_empty():
		_no_presets_dialog.show()
		return

	hide()
	emit_signal("export_accepted", selected_export_presets)
	queue_free()
