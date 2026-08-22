@tool
extends RefCounted
class_name ItchPageInfo

var user: String
var project: String

func _init(user: String, project: String) -> void:
	self.user = user
	self.project = project

func _to_string() -> String:
	return "<ItchPageInfo user=\"{user}\" project=\"{project}\">".format(self)
