extends Node3D

## Small white callsign tags floating under every FRIENDLY ship within
## `tag_radius` (1000m), so you can read who's flying near you.
##
## WHY THIS IS A POOL RATHER THAN A LABEL PER SHIP.
##
## Friendly ships are not nodes. They are lightweight `Combatant` objects
## (RefCounted, never in the scene tree) drawn through a single
## MultiMeshInstance3D — that is the whole reason a 200-ship battle is
## affordable at all, see faction_battle.gd's header. So there is nothing to
## parent a Label3D to, and creating 100 of them would hand back a large part
## of what that design bought: every Label3D is its own node, its own quad,
## and its own text-shaping/texture cost.
##
## Instead a fixed pool of `tag_count` labels is dynamically attached to
## whichever friendlies are currently nearest the player — structurally the
## same solution as ship_engine_audio.gd's 12 voices and thruster_trails.gd's
## 10 emitters, reusing the identical FactionBattle API
## (`get_ships_near()` / `is_ship_alive_by_key()` /
## `get_ship_position_by_key()`) plus `get_ship_label_by_key()` for the name
## itself. Among ships whose tag you cannot read, you cannot tell which one
## isn't wearing one.
##
## FRIENDLIES ONLY, structurally. `get_ships_near()` returns both factions,
## so results are filtered through `FactionBattle.is_friendly_key()`. Because
## a furball can easily put more hostiles than friendlies inside the radius,
## the candidate list is requested `CANDIDATE_MULTIPLIER` times longer than
## the pool and then filtered — asking for only `tag_count` nearest ships of
## ANY faction would routinely come back with too few friendlies in exactly
## the situation where you most want to know who's around you. Same reasoning
## thruster_trails.gd uses to find afterburning ships.
##
## TEXT IS WRITTEN ONCE PER ASSIGNMENT, NOT PER FRAME. Assigning `Label3D.text`
## re-shapes the string and rebuilds the label's mesh; the callsign only
## changes when a tag is handed to a different ship, so only the position is
## touched each frame.

const CANDIDATE_MULTIPLIER := 6
const FONT := preload("res://Assets/Fonts/Orbitron-Variable.ttf")

## Pool size — the maximum number of friendly tags visible at once. Squads
## are 1-5 ships and separation steering holds same-faction ships ~550-620m
## apart in combat, so this comfortably covers a normal engagement without
## paying for a hundred labels.
@export var tag_count: int = 18

## RANGE — raised from an originally-specified 1000m after measuring what
## 1000m actually covers in this world, which is nearly nothing.
##
## Sampled over a real match with the player at the friendly spawn: once the
## fleet launches (~t=30s) the number of friendlies within 1000m is **0,
## essentially always** — the nearest friendly sits between 1.5km and 8.8km
## away for the rest of the match. Counts in range at t=42-126s:
##
##     <1000m   0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
##     <2000m   0 0 0 0 0 0 0 0 0 0 0 1 0 0 0
##     <3000m   2 0 0 1 0 1 0 0 1 1 1 1 4 1 3
##     <4000m  11 2 0 1 0 1 0 1 2 6 4 4 5 7 4
##     <6000m  29 16 1 2 1 1 1 1 3 6 9 6 9 9 10
##
## 1000m simply isn't "nearby" at this scale — the dome alone is 8000m in
## radius and the city is 10800m across. 4000m keeps the peak inside the
## label pool while making the feature actually do its job. Because
## `fixed_size` holds apparent size constant (see `font_size`), a callsign at
## 4000m is exactly as legible as one at 400m, so range costs nothing in
## readability. Drop it back to 1000.0 if the wider net reads as clutter.
@export var tag_radius: float = 4000.0

## A tag keeps its ship until that ship dies or drifts past
## `tag_radius * release_hysteresis`, so ships hovering right at the boundary
## don't make tags flicker between callsigns.
@export var release_hysteresis: float = 1.2

## Reassignment is not a per-frame job — ships do not cross a 1000m boundary
## in a few milliseconds. Positions of already-assigned tags still update
## every frame.
@export var rescan_interval: float = 0.4

## How far BELOW the ship the tag sits, in metres. Ships render at
## FactionBattle.SHIP_SCALE (2.0) on a hull only ~0.75m tall, so this is
## mostly about clearing the ship's silhouette rather than its actual size.
@export var tag_y_offset: float = 7.0

## Constant on-screen size regardless of range (Label3D.fixed_size), so a
## callsign at 950m is exactly as legible as one at 50m. Without it the text
## would shrink with distance and be unreadable well before the 1000m cutoff
## — the same "fixed apparent size" reasoning target_lock.gd already uses for
## its visor-anchored readouts.
@export var font_size: int = 36
@export var pixel_size: float = 0.0006

@export var battle_path: NodePath = ^".."
@export var player_path: NodePath = ^"../../Player"

## Set by game_flow.gd alongside the other FactionBattle-owned pools, so
## callsigns don't hang in the air over the MENU / GAME_OVER black screens.
var paused: bool = false:
	set(value):
		paused = value
		if paused:
			for t in _tags:
				t["key"] = -1
				(t["node"] as Label3D).visible = false

var _battle: Node
var _player: Node3D
var _tags: Array = []  # {"node": Label3D, "key": int}
var _rescan_timer: float = 0.0


func _ready() -> void:
	_battle = get_node_or_null(battle_path)
	_player = get_node_or_null(player_path)
	_build_tags()


func _build_tags() -> void:
	for i in tag_count:
		var label := Label3D.new()
		label.font = FONT
		label.font_size = font_size
		label.pixel_size = pixel_size
		# Constant apparent size at any range — see `font_size` above.
		label.fixed_size = true
		# Always face the camera. Every world-space Label3D in this project
		# billboards; the only non-billboarded ones are flight_hud.gd's, which
		# are deliberately fixed to the cockpit glass.
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# Plain white, NOT pushed above 1.0 the way this project's other HUD
		# text is. Those are pushed deliberately so Town.tscn's Glow pass
		# blooms them, which is right for a big readout but would smear small
		# text at range into an illegible blob.
		label.modulate = Color(1.0, 1.0, 1.0)
		# Dark outline so the callsign survives being read against a bright
		# sky, a dark city, or an explosion — matching the outline convention
		# the rest of this project's Label3Ds already use.
		label.outline_size = 10
		label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
		# ALWAYS ON TOP. This was originally left depth-tested on the
		# reasoning that a wingman's callsign behind a skyscraper ought to be
		# hidden by it — which sounded principled and was wrong in practice,
		# because it made the feature fail silently in the one place tags are
		# guaranteed to be assigned.
		#
		# Every ship starts the match PARKED on its mothership's flight deck,
		# and a tag sits `tag_y_offset` BELOW its ship — i.e. inside the
		# mothership's own solid hull. Depth-tested, all ~16 of those tags
		# render inside the deck and are invisible, so the entire pre-launch
		# window (the one stretch where friendlies are reliably close) showed
		# nothing at all. The same thing happens to anyone flying below a
		# tower in the city.
		#
		# An identification aid whose whole job is "tell me who that is"
		# should not be defeated by the geometry the target is standing on.
		# This also matches every other HUD element in this project.
		label.no_depth_test = true
		label.visible = false
		add_child(label)
		_tags.append({"node": label, "key": -1})


func _process(delta: float) -> void:
	if paused or _battle == null or _player == null:
		return

	_rescan_timer -= delta
	if _rescan_timer <= 0.0:
		_rescan_timer = rescan_interval
		_reassign_tags()

	_update_tags()


func _reassign_tags() -> void:
	var origin: Vector3 = _player.global_position
	var release_sq: float = pow(tag_radius * release_hysteresis, 2.0)

	# Release any tag whose ship has died or drifted out of range.
	var held: Dictionary = {}
	for t in _tags:
		var key: int = t["key"]
		if key < 0:
			continue
		if not _battle.is_ship_alive_by_key(key) \
				or origin.distance_squared_to(_battle.get_ship_position_by_key(key)) > release_sq:
			t["key"] = -1
			(t["node"] as Label3D).visible = false
		else:
			held[key] = true

	# Hand every free tag to the nearest un-tagged friendly.
	var candidates: Array = _battle.get_ships_near(
			origin, tag_radius, tag_count * CANDIDATE_MULTIPLIER)
	for key in candidates:
		if not _battle.is_friendly_key(key) or held.has(key):
			continue
		var free_tag := _free_tag()
		if free_tag.is_empty():
			break
		free_tag["key"] = key
		held[key] = true
		var label: Label3D = free_tag["node"]
		# Written once here, not every frame — see the class comment.
		label.text = _battle.get_ship_label_by_key(key)
		label.visible = true


func _free_tag() -> Dictionary:
	for t in _tags:
		if t["key"] < 0:
			return t
	return {}


func _update_tags() -> void:
	for t in _tags:
		var key: int = t["key"]
		if key < 0:
			continue
		var label: Label3D = t["node"]
		label.global_position = _battle.get_ship_position_by_key(key) \
				- Vector3(0.0, tag_y_offset, 0.0)
