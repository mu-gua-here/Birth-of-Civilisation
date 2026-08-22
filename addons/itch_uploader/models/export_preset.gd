@tool
extends RefCounted
class_name ExportPreset

var name: String
var platform: String
var path: String
var channel: String

func _init(name: String, platform: String, path: String, channel: String):
	self.name = name
	self.platform = platform
	self.path = path
	self.channel = channel

func _to_string() -> String:
	return "<ExportPreset name=\"{name}\" platform=\"{platform}\" path=\"{path}\" channel=\"{channel}\">".format(self)

func equals(other: ExportPreset) -> bool:
	return self.name == other.name \
		and self.platform == other.platform \
		and self.path == other.path \
		and self.channel == other.channel
