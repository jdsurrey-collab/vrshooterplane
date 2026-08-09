extends Node

## Plays one of several "we just got hit" sounds. Ready-but-unconsumed
## infrastructure: nothing calls play_random_hit() yet, because there's no
## player-side damage/health system to trigger it from — the player's own
## ship has no hit-zone/health pool the way enemy_ai.gd's does (see
## docs/damage-reference.md's Scope section). Once that exists (most likely
## as a laser_bolt.gd extension symmetric to _check_enemy_hit(), or an
## eventual enemy weapon), wire its damage-taken path to call
## play_random_hit() on this node.

var _players: Array[AudioStreamPlayer] = []
var _next_index: int = 0


func _ready() -> void:
	for child in get_children():
		if child is AudioStreamPlayer:
			_players.append(child)
	_players.shuffle()


## Plays a random hit sound, avoiding an immediate repeat of the last one
## played when there's more than one option.
func play_random_hit() -> void:
	if _players.is_empty():
		return
	var index := randi() % _players.size()
	if _players.size() > 1 and index == _next_index:
		index = (index + 1) % _players.size()
	_next_index = index
	_players[index].play()
