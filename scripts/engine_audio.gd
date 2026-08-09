extends Node

## Two looping engine layers, both always playing but faded by volume/pitch
## based on flight input:
##
## - Accelerate (main drive): tied to the right grip (forward thrust). Gets
##   louder AND deeper (lower pitch) the harder you push it.
## - Thrust (maneuvering RCS): tied to roll, elevation/vertical strafe, and
##   reverse grip — anything that isn't the main drive.

@export var accelerate_min_volume_db: float = -30.0
@export var accelerate_max_volume_db: float = 0.0
@export var accelerate_max_pitch: float = 1.0  # at zero throttle
@export var accelerate_min_pitch: float = 0.55  # at full throttle — "deeper"

@export var thrust_min_volume_db: float = -30.0
@export var thrust_max_volume_db: float = -6.0
@export var thrust_min_pitch: float = 0.9
@export var thrust_max_pitch: float = 1.2

@export var response_speed: float = 6.0  # how fast volume/pitch chase their target

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

	if _accelerate_player:
		var accel: float = clampf(_flight_controller.right_grip_value, 0.0, 1.0)
		var target_volume := lerpf(accelerate_min_volume_db, accelerate_max_volume_db, accel)
		var target_pitch := lerpf(accelerate_max_pitch, accelerate_min_pitch, accel)
		_accelerate_player.volume_db = lerpf(_accelerate_player.volume_db, target_volume, response_speed * delta)
		_accelerate_player.pitch_scale = lerpf(_accelerate_player.pitch_scale, target_pitch, response_speed * delta)

	if _thrust_player:
		var maneuvering: float = clampf(
				absf(_flight_controller.roll_input_value)
				+ absf(_flight_controller.vertical_input_value)
				+ _flight_controller.left_grip_value,
				0.0, 1.0)
		var target_volume := lerpf(thrust_min_volume_db, thrust_max_volume_db, maneuvering)
		var target_pitch := lerpf(thrust_min_pitch, thrust_max_pitch, maneuvering)
		_thrust_player.volume_db = lerpf(_thrust_player.volume_db, target_volume, response_speed * delta)
		_thrust_player.pitch_scale = lerpf(_thrust_player.pitch_scale, target_pitch, response_speed * delta)
