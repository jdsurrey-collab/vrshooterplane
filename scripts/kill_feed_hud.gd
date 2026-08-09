extends Label3D

## Bottom-left kill feed — who died and how, sourced from
## faction_battle.gd's own ring-buffer + time-based expiry
## (kill_feed_text, already newline-joined and capped/aged there so this
## script only has to display it).

@export var battle_path: NodePath = ^"../../../FactionBattle"

var _battle: Node


func _ready() -> void:
	_battle = get_node_or_null(battle_path)


func _process(_delta: float) -> void:
	if not _battle:
		return
	text = _battle.kill_feed_text
