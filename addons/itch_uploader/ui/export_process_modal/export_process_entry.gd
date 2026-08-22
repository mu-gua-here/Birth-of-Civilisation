@tool
extends Control
class_name ExportProcessEntry

signal log_requested

@export var label: String
@export var state := State.WAITING : set = set_state

@onready var _success_status_icon := %"SuccessStatusIcon"
@onready var _error_status_icon := %"ErrorStatusIcon"
@onready var _canceled_status_icon := %"CanceledStatusIcon"
@onready var _in_progress_status_icon := %"InProgressStatusIcon"
@onready var _in_progress_status_icon_sprite := %"InProgressStatusIconSprite"
@onready var _view_log_button := %"ViewLogButton"
@onready var _name_label := %"ExportPresetNameLabel"

func set_state(value):
	state = value
	
	_success_status_icon.visible = (state == State.SUCCESS)
	
	_error_status_icon.visible = (state == State.ERROR)
	_view_log_button.visible = (state == State.ERROR)
	
	_canceled_status_icon.visible = (state == State.CANCELED)
	
	_in_progress_status_icon.visible = (state == State.IN_PROGRESS)

func _ready():
	if is_part_of_edited_scene():
		return
		
	_name_label.text = label
	_in_progress_status_icon_sprite.play("default")

enum State {
	WAITING,
	IN_PROGRESS,
	SUCCESS,
	ERROR,
	CANCELED,
}
