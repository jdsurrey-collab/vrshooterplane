extends Label3D

## Top-center readout for the faction battle (faction_battle.gd): the
## friendly/enemy score race and the match countdown, plus a VICTORY/
## DEFEAT/DRAW line and a "return to menu" prompt once the match ends
## (game_flow.gd reads the same right-trigger press to act on it).
##
## RETIRED: the old "AIR SUPERIORITY / FRIENDLY n% - ENEMY n%" dome-
## presence readout and the "FUEL TANKS: n/20" line — direct instruction,
## "we're gonna go by kills... for every one kill is one point," and
## separately "get rid of all the tank mechanics." Scoring is now
## FactionBattle.friendly_score/enemy_score (kills + tower control, see
## that script's own Conquest section), racing to score_target (1000).

@export var battle_path: NodePath = ^"../../../FactionBattle"

var _battle: Node


func _ready() -> void:
	_battle = get_node_or_null(battle_path)


func _process(_delta: float) -> void:
	if not _battle:
		return

	var total_seconds := int(_battle.match_time_remaining)
	var minutes := total_seconds / 60
	var seconds := total_seconds % 60

	var friendly_towers := 0
	var enemy_towers := 0
	for zone in _battle.capture_zones:
		var owner: int = zone.owner_faction()
		if owner == CaptureZone.FRIENDLY:
			friendly_towers += 1
		elif owner == CaptureZone.ENEMY:
			enemy_towers += 1

	var lines := [
		"SCORE",
		"FRIENDLY %d  -  ENEMY %d" % [roundi(_battle.friendly_score), roundi(_battle.enemy_score)],
		"TOWERS HELD: %d - %d" % [friendly_towers, enemy_towers],
		"%02d:%02d" % [minutes, seconds],
	]

	if _battle.game_over:
		if _battle.winning_faction == Combatant.Faction.FRIENDLY:
			lines.append("VICTORY")
		elif _battle.winning_faction == Combatant.Faction.ENEMY:
			lines.append("DEFEAT")
		else:
			lines.append("DRAW")
		lines.append("PULL TRIGGER FOR MAIN MENU")

	text = "\n".join(lines)
