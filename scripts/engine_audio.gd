extends Node

## Two looping engine layers, both always playing but faded by volume/pitch
## based on flight input:
##
## - Accelerate (main drive): tied to the right grip (forward thrust). Gets
##   louder AND deeper (lower pitch) the harder you push it.
## - Thrust (maneuvering RCS): tied to roll, elevation/vertical strafe, and
##   reverse grip — anything that isn't the main drive.
##
## `paused` (set by game_flow.gd alongside flight_controller.gd/
## weapon_system.gd, same convention) pulls both layers' TARGET volume down
## to silent rather than just leaving them at their last idle level. Without
## this, the player's own engine hum was still clearly audible over the
## MENU/GAME_OVER/DEAD black screens, since 0 grip input is quiet
## (`accelerate_min_volume_db` -30dB) but not actually silent — those
## screens are meant to have only the main menu's own music/chatter.
##
## SOURCE FORMAT: `accelerate.ogg`/`thrust.ogg`, converted from the original
## `.mp3`s. This is a real fix, not a style choice — MP3 has an inherent
## encoder delay/padding gap at the exact sample the file loops back to, and
## for a loop this long (11-27s) held for minutes at a time in the cockpit,
## that gap is what was heard as audio "popping" on every loop cycle, and on
## VBR-encoded files the loop-point math can be imprecise enough that
## playback occasionally reaches true end-of-stream and does not restart at
## all — reported as "the loop will end even though I'm still holding the
## trigger." Ogg Vorbis loops sample-accurately in Godot; this project
## already reached the same conclusion for `ship_engine.ogg` and the
## mothership drone layers. `_process()` below also defensively restarts
## either player if it's ever found stopped while unpaused, as a second line
## of defense against exactly that symptom.

@export var accelerate_min_volume_db: float = -30.0
@export var accelerate_max_volume_db: float = 0.0
@export var accelerate_max_pitch: float = 1.0  # at zero throttle
@export var accelerate_min_pitch: float = 0.55  # at full throttle — "deeper"

@export var thrust_min_volume_db: float = -30.0
@export var thrust_max_volume_db: float = -6.0
@export var thrust_min_pitch: float = 0.9
@export var thrust_max_pitch: float = 1.2

@export var response_speed: float = 6.0  # how fast volume/pitch chase their target

const SILENT_DB := -80.0

## Set by game_flow.gd while the player is at a menu/death/game-over screen.
var paused: bool = false

var _flight_controller: Node
var _accelerate_player: AudioStreamPlayer
var _thrust_player: AudioStreamPlayer


func _ready() -> void:
	var player := get_parent()
	_flight_controller = player.get_node_or_null("FlightController")
	_accelerate_player = get_node_or_null("AcceleratePlayer")
	_thrust_player = get_node_or_null("ThrustPlayer")

	for stream_player in [_accelerate_player, _thrust_player]:
		if stream_player and stream_player.stream:
			stream_player.stream.loop = true
			stream_player.volume_db = -80.0
			stream_player.play()


func _process(delta: float) -> void:
	if not _flight_controller:
		return

	# Belt-and-braces: if either loop is ever found stopped while it should
	# be running, restart it. Converting to Ogg Vorbis (see the class
	# comment) is the real fix for the loop dying mid-hold; this is a second
	# line of defense so the same symptom can never come back silently, at
	# the cost of one `.playing` check per layer per frame.
	if not paused:
		if _accelerate_player and not _accelerate_player.playing:
			_accelerate_player.play()
		if _thrust_player and not _thrust_player.playing:
			_thrust_player.play()

	# Paused screens (menu/death/game-over) fade both layers to silence
	# rather than snapping — the lerp below already exists for input
	# response, so a paused target just reuses it, giving START a small
	# engine-spooling-up feel for free instead of a hard audio cut.
	if _accelerate_player:
		var target_volume := SILENT_DB
		var target_pitch := accelerate_max_pitch
		if not paused:
			var accel: float = clampf(_flight_controller.right_grip_value, 0.0, 1.0)
			target_volume = lerpf(accelerate_min_volume_db, accelerate_max_volume_db, accel)
			target_pitch = lerpf(accelerate_max_pitch, accelerate_min_pitch, accel)
		_accelerate_player.volume_db = lerpf(_accelerate_player.volume_db, target_volume, response_speed * delta)
		_accelerate_player.pitch_scale = lerpf(_accelerate_player.pitch_scale, target_pitch, response_speed * delta)

	if _thrust_player:
		var target_volume := SILENT_DB
		var target_pitch := thrust_min_pitch
		if not paused:
			var maneuvering: float = clampf(
					absf(_flight_controller.roll_input_value)
					+ absf(_flight_controller.vertical_input_value)
					+ _flight_controller.left_grip_value,
					0.0, 1.0)
			target_volume = lerpf(thrust_min_volume_db, thrust_max_volume_db, maneuvering)
			target_pitch = lerpf(thrust_min_pitch, thrust_max_pitch, maneuvering)
		_thrust_player.volume_db = lerpf(_thrust_player.volume_db, target_volume, response_speed * delta)
		_thrust_player.pitch_scale = lerpf(_thrust_player.pitch_scale, target_pitch, response_speed * delta)
