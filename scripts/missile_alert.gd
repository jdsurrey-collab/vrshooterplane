extends Node

## Missile warning — plays two layered alert sounds the moment the player
## becomes tracked by an incoming alien missile (see faction_battle.gd's
## rare alien-fires-at-player logic), and stops as soon as none remain
## (destroyed, missed, expired, or redirected to a flare).
##
## Detection is group-based rather than polling anything directly: every
## missile.gd instance with target_is_player=true adds itself to the
## "player_seeking_missiles" group in _ready() (and Godot drops it from
## the group automatically when the missile frees itself — no manual
## bookkeeping needed here). This node just checks whether that group is
## non-empty each frame.

var _sound_a: AudioStreamPlayer
var _sound_b: AudioStreamPlayer
var _was_tracked: bool = false


func _ready() -> void:
	_sound_a = get_node_or_null("AlertA")
	_sound_b = get_node_or_null("AlertB")


func _process(_delta: float) -> void:
	# get_node_count_in_group(), not get_nodes_in_group().size() — the latter
	# builds and throws away a whole Array of node references every frame
	# just to read its length, for a group that is empty almost all the time.
	var is_tracked := get_tree().get_node_count_in_group("player_seeking_missiles") > 0

	if is_tracked and not _was_tracked:
		if _sound_a:
			_sound_a.play()
		if _sound_b:
			_sound_b.play()
	_was_tracked = is_tracked
