extends Node3D

## Points toward the city — the contested "dome" objective of the 400-ship
## faction battle (faction_battle.gd) — instead of a single enemy ship, now
## that there isn't one. Child of XRCamera3D, so the direction is computed
## in the camera's LOCAL space each frame — that's what makes the arrow
## keep pointing at the right real-world direction regardless of which way
## you're currently looking.
##
## Exposes `distance_to_objective` for the HUD (renamed from
## `distance_to_enemy` — this used to point at the old single wandering
## HOSTILE-1, now it always points at the city; hud.gd's label was updated
## to match).

@export var battle_path: NodePath = ^"../../../FactionBattle"

## Toggled by the options menu (left controller's X/"ax_button" while the
## menu is open).
var tracking_enabled: bool = true

var distance_to_objective: float = -1.0

var _camera: Node3D
var _battle: Node


func _ready() -> void:
	_camera = get_parent()
	_battle = get_node_or_null(battle_path)


func _process(_delta: float) -> void:
	if not tracking_enabled or not _battle or not _camera:
		visible = false
		distance_to_objective = -1.0
		return

	visible = true
	var to_objective_world: Vector3 = (_battle.dome_center as Vector3) - _camera.global_position
	distance_to_objective = to_objective_world.length()
	if distance_to_objective < 0.01:
		return

	# Camera-local direction, so the arrow points the right real-world way
	# no matter how the headset is currently rotated.
	var local_dir: Vector3 = _camera.global_transform.basis.inverse() * (to_objective_world / distance_to_objective)
	if local_dir.length() > 0.01:
		basis = Basis.looking_at(local_dir, Vector3.UP)
