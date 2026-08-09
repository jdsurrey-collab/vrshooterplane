extends Node3D

## Debug aid: rotates to always point at the enemy ship, so it's findable
## even if it's currently far away or off to the side/behind. Child of
## XRCamera3D, so the direction is computed in the camera's LOCAL space
## each frame — that's what makes the arrow keep pointing at the right
## real-world direction regardless of which way you're currently looking.
##
## Also exposes `distance_to_enemy` for the HUD to display — useful for
## telling "it's just far away" apart from "something's actually broken
## and it's not rendering at all".

@export var enemy_path: NodePath = ^"../../../EnemyShip"

## Toggled by the options menu (left controller's X/"ax_button" while the
## menu is open).
var tracking_enabled: bool = true

var distance_to_enemy: float = -1.0

var _camera: Node3D
var _enemy: Node3D


func _ready() -> void:
	_camera = get_parent()
	_enemy = get_node_or_null(enemy_path)


func _process(_delta: float) -> void:
	if not tracking_enabled or not _enemy or not _camera:
		visible = false
		distance_to_enemy = -1.0
		return

	visible = true
	var to_enemy_world := _enemy.global_position - _camera.global_position
	distance_to_enemy = to_enemy_world.length()
	if distance_to_enemy < 0.01:
		return

	# Camera-local direction, so the arrow points the right real-world way
	# no matter how the headset is currently rotated.
	var local_dir: Vector3 = _camera.global_transform.basis.inverse() * (to_enemy_world / distance_to_enemy)
	if local_dir.length() > 0.01:
		basis = Basis.looking_at(local_dir, Vector3.UP)
