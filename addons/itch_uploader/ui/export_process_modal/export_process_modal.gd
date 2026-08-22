@tool
extends Window
class_name ExportProcessModal

var itch_page_url_storage: ItchPageUrlStorage
var project_exporter: ProjectExporter
var export_presets: Array[ExportPreset]

const PROCESS_ENTRY_RES := preload("res://addons/itch_uploader/ui/export_process_modal/export_process_entry.tscn")
const LOG_MODAL_RES := preload("res://addons/itch_uploader/ui/export_process_modal/log_modal.tscn")

@onready var _process_entry_container := %"ProcessEntryContainer"
@onready var _ok_button := %"OkButton"

var _page_info: ItchPageInfo = null
var _process_entries: Dictionary[ExportPreset, ExportProcessEntry] = {}
var _logs: Dictionary[ExportPreset, LogCollector] = {}
var _thread := Thread.new()

func _enter_tree():
	if is_part_of_edited_scene():
		return
	
	_page_info = itch_page_url_storage.get_page_info()
	
	if not _page_info:
		push_error("Page info is null")
		hide()
		queue_free()

func _ready():
	_ok_button.disabled = true
	
	for preset in export_presets:
		var process_entry := PROCESS_ENTRY_RES.instantiate()
		process_entry.label = preset.name
		process_entry.connect("log_requested", self._on_log_requested.bind(preset))
		_process_entries[preset] = process_entry
		_process_entry_container.add_child(process_entry)
		process_entry.state = ExportProcessEntry.State.WAITING
	
	var result := _thread.start(self._run_export)
	if result != OK:
		push_error("Could not start the thread")

func _exit_tree():
	if _thread.is_started():
		_thread.wait_to_finish()

func _on_log_requested(preset: ExportPreset):
	if preset not in _logs:
		return
	
	var modal := LOG_MODAL_RES.instantiate()
	modal.log = _logs[preset]
	add_child(modal)
	modal.show()

func _on_close_requested():
	if _thread.is_alive():
		return
	queue_free()

func _run_export():
	for preset in export_presets:
		_process_entries[preset].call_deferred("set_state", ExportProcessEntry.State.IN_PROGRESS)
		
		_logs[preset] = LogCollector.new()
		var log: Array[String] = []
		
		var result := project_exporter.export_preset(preset, log)
		
		_logs[preset].add_lines(log)
		
		if result == OK:
			_process_entries[preset].call_deferred("set_state", ExportProcessEntry.State.SUCCESS)
		else:
			_process_entries[preset].call_deferred("set_state", ExportProcessEntry.State.ERROR)
	
	_ok_button.call_deferred("set_disabled", false)
