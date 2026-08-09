extends Label3D

## Top-left visor readout of the player's own three health pools — the
## mirror of the enemy's cockpit/engine/hull zones, see player_damage.gd.

var _player_damage: Node


func _ready() -> void:
	# Label3D -> XRCamera3D -> Player
	var camera := get_parent()
	var player := camera.get_parent()
	_player_damage = player.get_node_or_null("PlayerDamage")


func _process(_delta: float) -> void:
	if not _player_damage:
		return

	text = "COCKPIT: %d%%\nENGINE: %d%%\nHULL: %d%%" % [
			roundi(_player_damage.cockpit_health_fraction() * 100.0),
			roundi(_player_damage.engine_health_fraction() * 100.0),
			roundi(_player_damage.hull_health_fraction() * 100.0),
	]
