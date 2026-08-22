@tool
extends RefCounted
class_name ItchPageUrlStorage

const SETTING := "itch_page_url"
const EXAMPLE := "https://user.itch.io/game"

var _full_setting_name := ItchUploader.get_setting_name(SETTING)
var _itch_page_url_regex := RegEx.new()

func _init() -> void:
	_itch_page_url_regex.compile("^https://(?<user>[a-zA-Z0-9_-]+)\\.itch\\.io/(?<project>[a-zA-Z0-9_-]+)$")

func register_project_settings():
	if not ProjectSettings.has_setting(_full_setting_name):
		ProjectSettings.set(_full_setting_name, "")
	ProjectSettings.set_as_basic(_full_setting_name, true)
	ProjectSettings.set_initial_value(_full_setting_name, "")
	ProjectSettings.add_property_info({
		"name": _full_setting_name,
		"type": TYPE_STRING,
		"hint": PROPERTY_HINT_PLACEHOLDER_TEXT,
		"hint_string": EXAMPLE,
	})

func unregister_project_settings():
	ProjectSettings.set(_full_setting_name, null)

func get_page_info() -> ItchPageInfo:
	var value := get_raw_value()
	if not value or not value is String:
		push_error("Value for Itch page URL is not set or is incorrect")
		return null
	
	var regex_match := _itch_page_url_regex.search(value)
	if not regex_match:
		push_error("Incorrect Itch page URL: " + value)
		return null
	
	return ItchPageInfo.new(
		regex_match.get_string("user"),
		regex_match.get_string("project"),
	)

func get_raw_value() -> String:
	return ProjectSettings.get_setting(ItchUploader.get_setting_name(SETTING))

func get_example() -> String:
	return EXAMPLE
