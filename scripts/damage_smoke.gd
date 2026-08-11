extends Node3D

## Pooled trailing smoke for badly damaged ships, EITHER faction — a
## "this one is hurting" signal, and the third consumer of ribbon_trail.gd's
## RibbonTrail (missiles, afterburners, now damage). Structurally cloned from
## thruster_trails.gd, which already solves the identical problem — "N
## emitters against up to 200 combatants that aren't even Nodes" — for the
## afterburner plume; see that script's own header for the full reasoning on
## why pooling exists and why reassignment is safe with world-space ribbon
## geometry. Only what actually differs from it is called out below.
##
## Direct request: "smoke will use a reddish smoke band like we are for the
## missiles." DamageSmokeTrail.tscn is the identical ribbon_trail.gd
## technique, recoloured dark red/black rather than the missile's white or
## the afterburner's orange, so the three ribbon consumers stay visually
## distinct even though they share one script.
##
## CLAIM CONDITION IS HEALTH, not velocity or a flight-state flag: any living
## ship at or below `damage_threshold` of its own max health is a candidate,
## on EITHER faction — unlike thruster_trails.gd this pool is not
## faction-specific, since a hurt ship reads as hurt regardless of who's
## flying it. Also deliberately NOT gated on speed (thruster_trails.gd's
## min_speed) — a badly wounded ship trailing smoke while nearly stationary
## is exactly the image this is going for, not a case to filter out.
##
## No hysteresis is needed on the release side the way trail_radius's is for
## the afterburner pool: health here only ever decreases until death (there
## is no in-combat regen), so a ship that has claimed an emitter can't
## flicker back and forth across `damage_threshold` the way a ship hovering
## at a distance boundary could. It only ever releases on death or drifting
## out of `smoke_radius`.

const TRAIL_SCENE := preload("res://scenes/DamageSmokeTrail.tscn")

## How many nearby ships to consider per free emitter — see
## thruster_trails.gd's identical constant for why this needs to be well
## wider than the pool itself.
const CANDIDATE_MULTIPLIER := 8

## Primary cost dial. Smaller than the afterburner pool's 10: a wounded ship
## lingers in that state far longer than an afterburner burst does (health
## only recovers on respawn), so far fewer concurrent emitters are needed to
## keep "who's hurt nearby" reliably covered.
@export var trail_count: int = 8
@export var smoke_radius: float = 3000.0
## Health fraction at/under which a ship starts smoking.
@export var damage_threshold: float = 0.45
@export var rescan_interval: float = 0.4

var _battle: Node
var _player: Node3D
var _trails: Array = []  # {"node": RibbonTrail, "key": int}
var _rescan_timer: float = 0.0

## Set by game_flow.gd, same convention as thruster_trails.gd's own `paused`.
var paused: bool = false:
	set(value):
		paused = value
		if paused:
			for t in _trails:
				(t["node"] as RibbonTrail).emitting = false
				t["key"] = -1


func _ready() -> void:
	_battle = get_parent()
	_player = get_tree().current_scene.get_node_or_null("Player")
	_build_trails()


func _build_trails() -> void:
	for i in trail_count:
		var node: RibbonTrail = TRAIL_SCENE.instantiate()
		node.emitting = false
		# This pool positions its emitters itself (see _update_trails), so
		# the trail must NOT capture this node as its follow target — the
		# same before-add_child() ordering thruster_trails.gd's own pool
		# already established.
		node.inherit_parent_as_follow = false
		node.auto_free = false
		add_child(node)
		_trails.append({"node": node, "key": -1})


func _process(delta: float) -> void:
	if paused:
		return
	if not _battle or not _player:
		return

	_rescan_timer -= delta
	if _rescan_timer <= 0.0:
		_rescan_timer = rescan_interval
		_reassign_trails()

	_update_trails()


func _reassign_trails() -> void:
	var listener: Vector3 = _player.global_position
	var claimed := {}

	for t in _trails:
		var key: int = t["key"]
		if key < 0:
			continue
		if not _battle.is_ship_alive_by_key(key) \
				or _battle.get_ship_health_fraction_by_key(key) > damage_threshold \
				or listener.distance_to(_battle.get_ship_position_by_key(key)) > smoke_radius:
			t["key"] = -1
			continue
		claimed[key] = true

	var nearby: Array = _battle.get_ships_near(listener, smoke_radius, trail_count * CANDIDATE_MULTIPLIER)
	for key in nearby:
		if claimed.has(key) or _battle.get_ship_health_fraction_by_key(key) > damage_threshold:
			continue
		var slot: Dictionary = _free_trail()
		if slot.is_empty():
			break
		slot["key"] = key
		claimed[key] = true


func _free_trail() -> Dictionary:
	for t in _trails:
		if t["key"] < 0:
			return t
	return {}


func _update_trails() -> void:
	for t in _trails:
		var node: RibbonTrail = t["node"]
		var key: int = t["key"]

		if key < 0 or not _battle.is_ship_alive_by_key(key) \
				or _battle.get_ship_health_fraction_by_key(key) > damage_threshold:
			node.emitting = false
			continue

		node.emit_position = _battle.get_ship_position_by_key(key)
		node.emitting = true
