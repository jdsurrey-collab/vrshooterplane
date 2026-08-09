extends Node3D

## Debris doesn't spawn already resting on the ground — it falls there.
## Ties into the GRAVITY COMPENSATOR STANDARD documented in
## flight_controller.gd: every ship's drives actively cancel gravity while
## powered, so it never normally falls. On destruction that compensation
## stops, and both the ship and its wreckage are just ordinary matter under
## real gravity again. CrashEffects.spawn() spawns each piece at the SHIP'S
## actual death altitude (not pre-placed at ground level), sets `terrain`
## and a random `tumble_speed` on it, and this script does the rest: falls
## under gravity, tumbling, until it reaches the terrain height for its
## (x, z), then stops for good.

@export var gravity_accel: float = 800.0  # m/s^2 — matches flight_controller.gd's scaled value
@export var tumble_speed: Vector3 = Vector3.ZERO  # radians/sec while falling, set by CrashEffects.spawn()
var terrain: Node  # set by CrashEffects.spawn()

var _fall_speed: float = 0.0
var _landed: bool = false
var _scorch: Node3D


func _ready() -> void:
	# The scorch/burn mark is the ground under the wreckage — doesn't make
	# sense tumbling through the air before it lands, so it stays hidden
	# until touchdown.
	_scorch = get_node_or_null("Scorch")
	if _scorch:
		_scorch.visible = false


func _physics_process(delta: float) -> void:
	if _landed or not terrain:
		return

	_fall_speed += gravity_accel * delta
	global_position.y -= _fall_speed * delta

	rotate_object_local(Vector3.RIGHT, tumble_speed.x * delta)
	rotate_object_local(Vector3.UP, tumble_speed.y * delta)
	rotate_object_local(Vector3.FORWARD, tumble_speed.z * delta)

	var ground_height: float = terrain.get_height_at(global_position.x, global_position.z)
	if global_position.y <= ground_height:
		global_position.y = ground_height
		_landed = true
		if _scorch:
			_scorch.visible = true
