extends RefCounted
class_name LogCollector

var _escape_sequence_regex := RegEx.create_from_string("\u001B\\[[\u0030-\u003F]*[\u0020-\u002F]*[\u0040-\u007E]")
var _logs: String = ""

func add_line(line: String) -> void:
	_logs += _escape_sequence_regex.sub(line, "", true) + "\n"

func add_lines(lines: Array[String]) -> void:
	for line in lines:
		add_line(line)

func get_log() -> String:
	return _logs.strip_edges()
