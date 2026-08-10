extends Label3D

## Match-opening role announcement: ATTACKER or DEFENDER slammed across the
## view like a rubber stamp, with the impact sound to match.
##
## Which side the player is on is rerolled every match by tank_objective.gd
## (see CLAUDE.md's ground-objective section), so unlike everything else on
## the HUD it genuinely cannot be assumed — this is the one moment where the
## player is told. `battle_hud.gd`'s smaller `FUEL TANKS: n/20 [ATTACK]` line
## is the persistent reminder; this is the announcement.
##
## Helmet-anchored (a child of XRCamera3D), matching every other big readout
## in this project rather than flight_hud.gd's ship-anchored glass elements —
## a full-screen announcement should stay centred in the view regardless of
## where the player happens to be looking.
##
## THE STAMP MOTION is the whole point, and it is three distinct phases
## rather than a fade:
##   SLAM  — starts large and transparent and drives DOWN to full size over
##           `slam_time`, on a steep ease-out so almost all of the travel
##           happens in the first few frames. That deceleration into a hard
##           stop is what reads as an impact instead of a zoom.
##   HOLD  — sits still and fully opaque at a slight random tilt, because a
##           real stamp is never applied perfectly square.
##   FADE  — alpha out, no movement. Moving during the fade would undo the
##           "it has been pressed onto the glass and stays there" feel.
##
## The sound fires at the START of the slam, not on impact: at `slam_time`
## 0.16s the two are close enough that leading with the audio reads as
## simultaneous, and audio that lags a visual impact is far more noticeable
## than audio that leads it.

const STAMP_SOUND := preload("res://Assets/Audio/stamp.tres")

## Delay before stamping, measured from the moment the match starts.
## main_menu.gd's black `Fade` quad dissolves over 2.5s, so this deliberately
## lands while the world is coming into view rather than over full black.
@export var stamp_delay: float = 1.1

@export var slam_time: float = 0.16
@export var hold_time: float = 1.7
@export var fade_time: float = 0.8

## How much larger the text starts before slamming down to 1.0.
@export var slam_start_scale: float = 3.4

## A real stamp is never applied perfectly square.
@export var max_tilt_degrees: float = 5.0

## Classic rubber-stamp red for ATTACKER; the friendly cyan this project
## already uses for its own faction for DEFENDER. Both pushed above 1.0 per
## channel so Town.tscn's Glow pass blooms them — correct for a big
## announcement, unlike friendly_tags.gd's small callsigns where bloom would
## smear the text.
@export var attacker_color: Color = Color(2.6, 0.35, 0.2)
@export var defender_color: Color = Color(0.2, 2.2, 2.5)

enum Phase { IDLE, WAITING, SLAM, HOLD, FADE }

var _phase: int = Phase.IDLE
var _timer: float = 0.0
var _base_scale: Vector3 = Vector3.ONE
var _audio: AudioStreamPlayer


func _ready() -> void:
	_base_scale = scale
	visible = false
	# Non-positional: this is an announcement inside the player's own helmet,
	# not a thing happening somewhere in the world. Same reasoning as
	# main_menu.gd's music and missile_alert.gd's warnings — and the exact
	# mistake missile_system.gd's lock audio originally made by using an
	# AudioStreamPlayer3D with no positioned Node3D parent.
	_audio = AudioStreamPlayer.new()
	_audio.stream = STAMP_SOUND
	add_child(_audio)
	set_process(false)


## Called by game_flow.gd at match start. `role` is the noun to stamp
## ("ATTACKER" / "DEFENDER"); an empty string cancels, so a match with no
## ground objective simply doesn't announce anything.
func play_role(role: String) -> void:
	if role == "":
		hide_stamp()
		return
	text = role
	modulate = attacker_color if role.begins_with("ATTACK") else defender_color
	modulate.a = 0.0
	rotation.z = deg_to_rad(randf_range(-max_tilt_degrees, max_tilt_degrees))
	scale = _base_scale * slam_start_scale
	visible = false
	_phase = Phase.WAITING
	_timer = 0.0
	set_process(true)


func hide_stamp() -> void:
	visible = false
	_phase = Phase.IDLE
	scale = _base_scale
	set_process(false)


func _process(delta: float) -> void:
	_timer += delta

	match _phase:
		Phase.WAITING:
			if _timer >= stamp_delay:
				_phase = Phase.SLAM
				_timer = 0.0
				visible = true
				_audio.play()

		Phase.SLAM:
			var t: float = clampf(_timer / maxf(slam_time, 0.001), 0.0, 1.0)
			# Steep ease-out (1 - (1-t)^4): most of the travel is over within
			# the first couple of frames and it decelerates hard into its
			# final size, which is what sells an impact rather than a zoom.
			var eased: float = 1.0 - pow(1.0 - t, 4.0)
			scale = _base_scale * lerpf(slam_start_scale, 1.0, eased)
			modulate.a = eased
			if t >= 1.0:
				scale = _base_scale
				modulate.a = 1.0
				_phase = Phase.HOLD
				_timer = 0.0

		Phase.HOLD:
			if _timer >= hold_time:
				_phase = Phase.FADE
				_timer = 0.0

		Phase.FADE:
			var f: float = clampf(_timer / maxf(fade_time, 0.001), 0.0, 1.0)
			modulate.a = 1.0 - f
			if f >= 1.0:
				hide_stamp()
