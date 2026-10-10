extends Node3D

## Autoload. Scene singletons register themselves here in _ready() so other
## scripts can reach them directly instead of searching the tree or groups.
## Player stats (health, energy) live on the Player itself -- read them via
## Globals.player or connect to Player.health_changed.

var player: CharacterBody3D = null
var builder: Node = null

func register_player(p: CharacterBody3D) -> void:
	player = p

func register_builder(b: Node) -> void:
	builder = b

func get_player_position() -> Vector3:
	if player:
		return player.global_position
	push_warning("Globals.gd: No player detected, returning Vector3.ZERO")
	return Vector3.ZERO
