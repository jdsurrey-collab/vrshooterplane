extends Node3D

## AFTERBURNER smoke trails for the AI ships — the long, persistent plume a
## ship lays down while its burner is lit. Deliberately NOT tied to
## ordinary thrust: AI ships are under power essentially all the time, so
## gating on throttle meant every nearby ship permanently smoking, which
## is both wrong (a plume should mark a boost) and the worst possible case
## for the overdraw cost below. Mirrors the player's own trail, which is
## gated on the same afterburner rather than on the throttle.
##
## POOLED EMITTERS, not one per ship — the identical reasoning (and very
## nearly the identical structure) as ship_engine_audio.gd, which already
## solves this exact problem for engine noise. There are up to 200
## combatants and they are deliberately not Nodes (see combatant.gd), but
## the real blocker is cost: smoke is large transparent quads, and
## transparent overdraw is the most expensive thing you can put on a VR
## renderer — every pixel is shaded twice, once per eye, and stacked smoke
## quads shade the same pixel many times over. This project already has an
## unresolved frame-rate collapse with GPU-side suspicion (see CLAUDE.md's
## Known gaps), so 200 unbudgeted particle systems was never an option.
## Instead a small fixed pool is handed to whichever ships are nearest the
## player.
##
## WHY REASSIGNMENT IS SAFE HERE, unlike the audio pool: the geometry is
## world-space, so a trail already laid down stays exactly where it was.
## Moving an emitter to a different ship leaves the old plume hanging in the
## sky to fade on its own and starts a new one elsewhere — there is no
## equivalent of the audio pool's "pop" on a voice steal, so none of its
## gain-ramp machinery is needed. The hysteresis below is purely to stop
## emitters churning between ships hovering at the edge of `trail_radius`.
##
## That property survived the move from particles to ribbons but is no
## longer free: a ribbon is CONNECTED, so teleporting an emitter to a new
## ship would draw one continuous streak between the two straight across
## the map. RibbonTrail handles it with a break-on-jump (see
## `break_distance` there) rather than clearing the old geometry, which is
## what keeps the no-pop behaviour intact.
##
## KNOWN LIMITATION, worth stating plainly: ships beyond the pool's reach
## have no trail at all. A trail is long enough to be visible from much
## further away than `trail_radius`, so a distant furball will look
## emptier than a near one. That is a deliberate cost trade, not an
## oversight — covering every ship would need trails batched into a single
## MultiMesh, a much bigger piece of work.

const TRAIL_SCENE := preload("res://scenes/ThrusterTrail.tscn")

## How many nearby ships to consider per free emitter. Only a fraction are
## burning at any moment (a burst lasts a couple of seconds against a
## 6-14s cooldown), so the candidate list has to be well wider than the
## pool or free emitters would routinely find nothing to attach to.
const CANDIDATE_MULTIPLIER := 8

## How many ships can be trailing at once. THE primary cost dial for this
## whole feature — raise it only against a measured frame budget.
@export var trail_count: int = 10
## How close a ship must be to the player to be given an emitter.
@export var trail_radius: float = 3500.0
## An emitter holds its ship out to this multiple of trail_radius before
## letting go, so ships loitering near the boundary don't cause churn.
@export var release_hysteresis: float = 1.25
@export var rescan_interval: float = 0.35
## Below this the ship isn't really moving (parked on the deck), so it gets
## no plume regardless of anything else — a burner lit on a stationary ship
## would just smoke in place.
@export var min_speed: float = 20.0
## How far behind the ship's own origin the plume starts, so it reads as
## coming out of the exhaust rather than the middle of the hull.
@export var nozzle_offset: float = 6.0

var _battle: Node
var _player: Node3D
var _trails: Array = []  # {"node": RibbonTrail, "key": int}
var _rescan_timer: float = 0.0

## Set by game_flow.gd, same convention as ship_engine_audio.gd's own
## `paused`. At MENU the whole fleet sits parked on the mothership deck
## right next to the player; without this every emitter would be claimed
## and smoking over the black menu screen.
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
		# This pool positions its emitters itself (see _update_trails), so the
		# trail must NOT capture this node as its follow target. Assigned
		# before add_child() because add_child() runs _ready() immediately,
		# which is where that capture happens — the same standing rule that
		# once cost this project a completely undamageable player.
		node.inherit_parent_as_follow = false
		node.auto_free = false
		add_child(node)
		_trails.append({"node": node, "key": -1})


func _process(delta: float) -> void:
	if paused:
		# The setter already stopped every emitter once; returning here is
		# what keeps them stopped, exactly as ship_engine_audio.gd does —
		# otherwise the next reassignment pass immediately re-claims the
		# parked ships surrounding the player and starts smoking again.
		return
	if not _battle or not _player:
		return

	_rescan_timer -= delta
	if _rescan_timer <= 0.0:
		_rescan_timer = rescan_interval
		_reassign_trails()

	_update_trails()


## Releases emitters whose ship died, stopped burning, or drifted out of
## range, then hands free emitters to nearby ships that ARE burning.
##
## Claiming is filtered on the afterburner, not just proximity — with only
## `trail_count` emitters against potentially dozens of nearby ships,
## assigning them to the nearest ships regardless would park emitters on
## cruising ships doing nothing while an actually-boosting ship a little
## further out went untrailed. A burn only lasts a couple of seconds, so
## emitters need to follow the burns, not the neighbourhood.
##
## `get_ships_near` is asked for a generous multiple of `trail_count`
## because most of what it returns won't be burning at any given moment.
func _reassign_trails() -> void:
	var listener: Vector3 = _player.global_position
	var release_range := trail_radius * release_hysteresis
	var claimed := {}

	for t in _trails:
		var key: int = t["key"]
		if key < 0:
			continue
		if not _battle.is_ship_alive_by_key(key) \
				or not _battle.is_ship_afterburning_by_key(key) \
				or listener.distance_to(_battle.get_ship_position_by_key(key)) > release_range:
			t["key"] = -1
			continue
		claimed[key] = true

	var nearby: Array = _battle.get_ships_near(listener, trail_radius, trail_count * CANDIDATE_MULTIPLIER)
	for key in nearby:
		if claimed.has(key) or not _battle.is_ship_afterburning_by_key(key):
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

		if key < 0 or not _battle.is_ship_alive_by_key(key):
			node.emitting = false
			continue

		# AFTERBURNER ONLY — a plume marks a boost, not ordinary flight.
		# Matches the player's own trail, which is gated on the same
		# afterburner flag rather than on throttle.
		if not _battle.is_ship_afterburning_by_key(key):
			node.emitting = false
			continue

		var vel: Vector3 = _battle.get_ship_velocity_by_key(key)
		if vel.length() < min_speed:
			node.emitting = false
			continue

		# Park the emitter behind the ship, at its engine end, so the plume
		# reads as coming out of the exhaust rather than the hull's centre.
		node.emit_position = _battle.get_ship_position_by_key(key) - vel.normalized() * nozzle_offset
		node.emitting = true
