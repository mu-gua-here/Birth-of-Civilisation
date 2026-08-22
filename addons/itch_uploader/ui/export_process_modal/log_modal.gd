@tool
extends Window

const ERROR_TIPS: Dictionary[String, String] = {
	"Please set BUTLER_API_KEY to your API key": 
		"Not logged into Butler. Please run [code]butler login[/code]",
	
	"creating build on remote server: itch.io API error (400): /wharf/builds: invalid target (bad user)": 
		"Incorrect Itch.io project URL. Go to Project Settings → Itch Uploader and make sure it's correct",
	
	"creating build on remote server: itch.io API error (400): /wharf/builds: invalid game": 
		"The Itch.io project doesn't exist, or you don't have permissions for it[ul]Check the Itch.io project URL in Project Settings → Itch Uploader\nIf you are not the owner of the project, make sure you are added as an admin in the Itch.io project dashboard[/ul]",
}

var log: LogCollector = null

@onready var _log_text := %"LogText"
@onready var _error_tips := %"ErrorTips"

func _ready():
	_error_tips.visible = false
	if log:
		var log_text := log.get_log()
		_log_text.text = log_text
		
		var has_tips := false
		_error_tips.clear()
		
		_error_tips.push_bold()
		_error_tips.add_text("Possible issues:")
		_error_tips.pop()
		
		_error_tips.push_list(0, RichTextLabel.LIST_DOTS, false)
		for error_text in ERROR_TIPS:
			if log_text.findn(error_text) >= 0:
				has_tips = true
				_error_tips.append_text(ERROR_TIPS[error_text])
		_error_tips.pop()
		
		_error_tips.visible = has_tips
	else:
		push_warning("Log modal opened with no log")
		_log_text.text = ""

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == Key.KEY_ESCAPE and event.pressed:
		_on_close_requested()

func _on_close_requested():
	queue_free()
