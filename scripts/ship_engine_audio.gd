extends Node

## Proximity engine noise for the AI ships — every ship has a sphere of
## influence, and flying into it means hearing that ship's engine, falling
## off and muffling with distance the way a real one does.
##
## POOLED EMITTERS, not one player per ship. There are 200 combatants and
## they are deliberately not Nodes (see combatant.gd) — but even if they
## were, 200 simultaneous positional voices with per-voice distance
## filtering is far past what Godot's audio server will do, and would be a
## serious CPU cost on its own. Instead a small fixed pool of
## AudioStreamPlayer3D voices is dynamically attached to whichever ships are
## currently nearest the player. This is the standard approach for crowd and
## vehicle audio, and at these distances it's indistinguishable from the
## real thing: you cannot pick out an individual engine among ships you
## can't hear anyway.
##
## VOICE STEALING is the part that has to be handled carefully, because
## naive reassignment is very audible — a voice whose position suddenly
## jumps to a different ship pops. Two mitigations:
##   * HYSTERESIS — a voice keeps its ship until that ship dies or leaves
##     `audible_radius * release_hysteresis`, so ships hovering right at the
##     edge of the radius don't cause constant churn.
##   * GAIN RAMPS — voices fade in and out (`ramp_db_per_second`) rather
##     than cutting, and a released voice must fade essentially to silence
##     before it can be handed to a new ship.
## The streams themselves never stop; only the gain moves. Restarting a
## stream per assignment would click, and each voice starts at a random
## offset into the 72s loop so they don't phase-lock into one another.
##
## DISTANCE BEHAVIOUR is what sells it as a real engine, and most of it is
## Godot doing the work:
##   * `unit_size` / `max_distance` / inverse-distance attenuation for the
##     volume falloff.
##   * `attenuation_filter_cutoff_hz` — air absorption. High frequencies die
##     off with distance far faster than low ones, so a distant engine is
##     not just quieter but duller. This single property does more for
##     believable distance than the volume curve does.
##   * A doppler-style pitch shift computed here from the ship's closing
##     speed (see _voice_pitch). Godot's built-in `doppler_tracking` is
##     deliberately NOT used: it derives velocity from how the node moved
##     between frames, and these emitters teleport when reassigned, which
##     would produce an enormous pitch spike on every voice steal. Deriving
##     it from the combatant's own known velocity is both correct and free.
##
## The source is one merged loop built from three user-supplied rocket
## recordings — see Assets/Audio/ship_engine.ogg and CLAUDE.md.

const ENGINE_LOOP := preload("res://Assets/Audio/ship_engine.ogg")
const SILENT_DB := -60.0
const REASSIGN_DB := -45.0  # a released voice must be at least this quiet before reuse

@export var voice_count: int = 12
## How close a ship has to be before you can hear it at all.
@export var audible_radius: float = 2400.0
## A voice holds its ship out to this multiple of audible_radius before
## letting go, so ships loitering near the boundary don't cause churn.
@export var release_hysteresis: float = 1.25
@export var base_volume_db: float = -5.0
## Distance at which a voice is at full volume; beyond it, falloff begins.
@export var unit_size: float = 160.0
@export var ramp_db_per_second: float = 110.0
@export var rescan_interval: float = 0.25

## Doppler-ish wail. Closing speed is divided by this and clamped, so a ship
## screaming past shifts pitch noticeably in both directions.
@export var doppler_reference_speed: float = 700.0
@export var doppler_max_shift: float = 0.22

var _battle: Node
var _player: Node3D
var _voices: Array = []  # {"player": AudioStreamPlayer3D, "key": int, "gain": float}
var _rescan_timer: float = 0.0


var _stream: AudioStream


func _ready() -> void:
	_battle = get_parent()
	_player = get_tree().current_scene.get_node_or_null("Player")
	# Held in a var rather than used as the preloaded const directly: the
	# loop flag has to be set on the resource, and GDScript won't let a
	# const's properties be assigned.
	_stream = ENGINE_LOOP
	if _stream and "loop" in _stream:
		_stream.loop = true
	_build_voices()


func _build_voices() -> void:
	for i in voice_count:
		var player := AudioStreamPlayer3D.new()
		player.stream = _stream
		player.unit_size = unit_size
		player.max_distance = audible_radius * release_hysteresis
		player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		# Air absorption — the property that actually makes distance read.
		player.attenuation_filter_cutoff_hz = 2200.0
		player.attenuation_filter_db = -26.0
		player.volume_db = SILENT_DB
		player.max_db = 0.0
		add_child(player)
		# Random offset so the pool doesn't phase-lock into one loud unison.
		player.play(randf() * 60.0)
		_voices.append({"player": player, "key": -1, "gain": SILENT_DB})


func _process(delta: float) -> void:
	if not _battle or not _player:
		return

	_rescan_timer -= delta
	if _rescan_timer <= 0.0:
		_rescan_timer = rescan_interval
		_reassign_voices()

	_update_voices(delta)


## Releases voices whose ship died or drifted out of range, then hands free
## voices to the nearest unclaimed ships.
func _reassign_voices() -> void:
	var listener: Vector3 = _player.global_position
	var release_range := audible_radius * release_hysteresis
	var claimed := {}

	for v in _voices:
		var key: int = v["key"]
		if key < 0:
			continue
		if not _battle.is_ship_alive_by_key(key) \
				or listener.distance_to(_battle.get_ship_position_by_key(key)) > release_range:
			v["key"] = -1
			continue
		claimed[key] = true

	var nearby: Array = _battle.get_ships_near(listener, audible_radius, voice_count)
	for key in nearby:
		if claimed.has(key):
			continue
		var slot: Dictionary = _free_voice()
		if slot.is_empty():
			break
		slot["key"] = key
		claimed[key] = true


## A voice is only reusable once it has actually faded out — handing a
## still-audible voice to a ship somewhere else is the pop this whole
## design exists to avoid. Returns an empty Dictionary when none is free.
func _free_voice() -> Dictionary:
	for v in _voices:
		if v["key"] < 0 and (v["gain"] as float) <= REASSIGN_DB:
			return v
	return {}


func _update_voices(delta: float) -> void:
	var listener: Vector3 = _player.global_position
	for v in _voices:
		var player: AudioStreamPlayer3D = v["player"]
		var key: int = v["key"]
		var target := SILENT_DB

		if key >= 0 and _battle.is_ship_alive_by_key(key):
			var ship_pos: Vector3 = _battle.get_ship_position_by_key(key)
			var ship_vel: Vector3 = _battle.get_ship_velocity_by_key(key)
			player.global_position = ship_pos
			player.pitch_scale = _voice_pitch(key, ship_pos, ship_vel, listener)
			target = base_volume_db

		v["gain"] = move_toward(v["gain"] as float, target, ramp_db_per_second * delta)
		player.volume_db = v["gain"]


## Per-ship base pitch (so a formation doesn't sound like one engine played
## twelve times) plus a doppler-style shift from closing speed.
func _voice_pitch(key: int, ship_pos: Vector3, ship_vel: Vector3, listener: Vector3) -> float:
	var base_pitch := 0.82 + float(key % 9) * 0.035

	var to_listener := listener - ship_pos
	var dist := to_listener.length()
	if dist < 1.0:
		return base_pitch

	# Positive when the ship is closing on the listener.
	var closing: float = ship_vel.dot(to_listener / dist)
	var shift := clampf(closing / doppler_reference_speed, -doppler_max_shift, doppler_max_shift)
	return base_pitch * (1.0 + shift)
