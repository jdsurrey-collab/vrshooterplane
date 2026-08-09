extends Node

## Plays one of several "we just got hit" sounds, driven by
## player_damage.gd's apply_damage().
##
## SOUND LENGTH MATTERS HERE. Two of the four supplied files were 33s and
## 64s long — full recordings rather than impacts — so a single hit started
## a sound that played straight through the player's death, the crash
## sequence and the respawn. That was the "hull damage noise persisting at
## death" report. They're now all trimmed to ~1.2s impacts. `stop_all()`
## below is the belt-and-braces half of that fix: whatever the assets are,
## nothing this node started should survive the player dying.

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


## Cuts every hit sound immediately — called on death and on respawn, so
## damage audio can never bleed across a life.
func stop_all() -> void:
	for p in _players:
		p.stop()
