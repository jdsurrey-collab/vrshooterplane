extends Label3D

## Top-center readout for the faction battle (faction_battle.gd): the
## friendly/enemy Air Superiority split and the match countdown, plus a
## VICTORY/DEFEAT/DRAW line once the match ends.

@export var battle_path: NodePath = ^"../../../FactionBattle"

var _battle: Node


func _ready() -> void:
	_battle = get_node_or_null(battle_path)


func _process(_delta: float) -> void:
	if not _battle:
		return

	var friendly_pct: float = (_battle.air_superiority + 100.0) / 2.0
	var enemy_pct: float = 100.0 - friendly_pct
	var total_seconds := int(_battle.match_time_remaining)
	var minutes := total_seconds / 60
	var seconds := total_seconds % 60

	var lines := [
		"AIR SUPERIORITY",
		"FRIENDLY %d%% - ENEMY %d%%" % [roundi(friendly_pct), roundi(enemy_pct)],
		"%02d:%02d" % [minutes, seconds],
	]

	if _battle.game_over:
		if _battle.winning_faction == Combatant.Faction.FRIENDLY:
			lines.append("VICTORY")
		elif _battle.winning_faction == Combatant.Faction.ENEMY:
			lines.append("DEFEAT")
		else:
			lines.append("DRAW")

	text = "\n".join(lines)
