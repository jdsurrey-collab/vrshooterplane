extends Node3D

## Engine smoke trails for the AI ships — the long, persistent exhaust plume
## a ship lays down while its thrusters are running.
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
## WHY REASSIGNMENT IS SAFE HERE, unlike the audio pool: these emitters use
## `local_coords = false`, so particles already in the air stay exactly
## where they were laid down. Moving an emitter to a different ship leaves
## the old trail hanging in the sky to dissipate on its own and simply
## starts laying new smoke elsewhere — there is no equivalent of the audio
## pool's "pop" on a voice steal, so no gain-ramp machinery is needed. The
## hysteresis below is purely to stop emitters churning between ships that
## are all hovering at the edge of `trail_radius`.
##
## KNOWN LIMITATION, worth stating plainly: ships beyond the pool's reach
## have no trail at all. A trail is long enough to be visible from much
## further away than `trail_radius`, so a distant furball will look
## emptier than a near one. That is a deliberate cost trade, not an
## oversight — covering every ship would need a MultiMesh-based trail
## (a much bigger piece of work) rather than GPUParticles3D.

const TRAIL_SCENE := preload("res://scenes/ThrusterTrail.tscn")

## How many ships can be trailing at once. THE primary cost dial for this
## whole feature — raise it only against a measured frame budget.
@export var trail_count: int = 10
## How close a ship must be to the player to be given an emitter.
@export var trail_radius: float = 3500.0
## An emitter holds its ship out to this multiple of trail_radius before
## letting go, so ships loitering near the boundary don't cause churn.
@export var release_hysteresis: float = 1.25
@export var rescan_interval: float = 0.35
## Ships slower than this aren't under meaningful thrust — parked on the
## mothership deck, mostly — so they get no plume.
@export var min_speed: float = 20.0
## How far behind the ship's own origin the plume starts, so it reads as
## coming out of the exhaust rather than the middle of the hull.
@export var nozzle_offset: float = 6.0

var _battle: Node
var _player: Node3D
var _trails: Array = []  # {"node": GPUParticles3D, "key": int}
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
				(t["node"] as GPUParticles3D).emitting = false
				t["key"] = -1


func _ready() -> void:
	_battle = get_parent()
	_player = get_tree().current_scene.get_node_or_null("Player")
	_build_trails()


func _build_trails() -> void:
	for i in trail_count:
		var node: GPUParticles3D = TRAIL_SCENE.instantiate()
		node.emitting = false
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


## Releases emitters whose ship died or drifted out of range, then hands
## free emitters to the nearest unclaimed ships.
func _reassign_trails() -> void:
	var listener: Vector3 = _player.global_position
	var release_range := trail_radius * release_hysteresis
	var claimed := {}

	for t in _trails:
		var key: int = t["key"]
		if key < 0:
			continue
		if not _battle.is_ship_alive_by_key(key) \
				or listener.distance_to(_battle.get_ship_position_by_key(key)) > release_range:
			t["key"] = -1
			continue
		claimed[key] = true

	var nearby: Array = _battle.get_ships_near(listener, trail_radius, trail_count)
	for key in nearby:
		if claimed.has(key):
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
		var node: GPUParticles3D = t["node"]
		var key: int = t["key"]

		if key < 0 or not _battle.is_ship_alive_by_key(key):
			node.emitting = false
			continue

		var vel: Vector3 = _battle.get_ship_velocity_by_key(key)
		if vel.length() < min_speed:
			node.emitting = false
			continue

		# Park the emitter behind the ship, at its engine end, so the plume
		# reads as coming out of the exhaust rather than the hull's centre.
		node.global_position = _battle.get_ship_position_by_key(key) - vel.normalized() * nozzle_offset
		node.emitting = true
