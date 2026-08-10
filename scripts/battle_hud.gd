extends Label3D

## Top-center readout for the faction battle (faction_battle.gd): the
## friendly/enemy Air Superiority split and the match countdown, plus a
## VICTORY/DEFEAT/DRAW line and a "return to menu" prompt once the match
## ends (game_flow.gd reads the same right-trigger press to act on it).

@export var battle_path: NodePath = ^"../../../FactionBattle"
@export var tanks_path: NodePath = ^"../../../TankObjective"

var _battle: Node
var _tanks: Node


func _ready() -> void:
	_battle = get_node_or_null(battle_path)
	_tanks = get_node_or_null(tanks_path)


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

	# Ground objective. The role line matters as much as the count: which side
	# of the tank fight the player is on is rerolled every match, so it can't
	# be assumed and has to be stated.
	if _tanks and _tanks.active:
		lines.append("FUEL TANKS: %d/%d  [%s]"
				% [_tanks.tanks_remaining, _tanks.tank_count, _tanks.player_role_text()])

	if _battle.game_over:
		if _battle.winning_faction == Combatant.Faction.FRIENDLY:
			lines.append("VICTORY")
		elif _battle.winning_faction == Combatant.Faction.ENEMY:
			lines.append("DEFEAT")
		else:
			lines.append("DRAW")
		lines.append("PULL TRIGGER FOR MAIN MENU")

	text = "\n".join(lines)
