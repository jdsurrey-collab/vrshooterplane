extends Label3D

## Simple cockpit HUD readout: current speed, live weapon-system status
## (right controller active, trigger state, fire cooldown, shot count),
## crash/respawn status, and distance to the enemy ship (paired with the
## EnemyLocator arrow) — so issues are visible in-headset instead of only
## in the editor console.

var _flight_controller: Node
var _weapon_system: Node
var _crash_handler: Node
var _enemy_locator: Node


func _ready() -> void:
	# Label3D -> XRCamera3D -> Player
	var camera := get_parent()
	var player := camera.get_parent()
	_flight_controller = player.get_node_or_null("FlightController")
	_weapon_system = player.get_node_or_null("WeaponSystem")
	_crash_handler = player.get_node_or_null("CrashHandler")
	_enemy_locator = camera.get_node_or_null("EnemyLocator")


func _process(_delta: float) -> void:
	var speed_text := "SPEED: -- m/s"
	if _flight_controller:
		speed_text = "SPEED: %d m/s" % roundi(_flight_controller.get_speed())

	var gun_text := "GUN: no weapon system found"
	if _weapon_system:
		gun_text = "GUN R:%s TRG:%s CD:%.2f SHOTS:%d" % [
				"Y" if _weapon_system.right_controller_active else "N",
				"Y" if _weapon_system.trigger_pressed else "N",
				_weapon_system.cooldown_remaining,
				_weapon_system.shots_fired,
		]

	var enemy_text := "ENEMY: --"
	if _enemy_locator and _enemy_locator.distance_to_enemy >= 0.0:
		enemy_text = "ENEMY: %d m — follow the yellow arrow" % roundi(_enemy_locator.distance_to_enemy)

	var lines := [speed_text, gun_text, enemy_text]
	if _crash_handler and _crash_handler.crashed:
		lines.append("CRASHED — respawning in %ds" % ceili(_crash_handler.respawn_time_remaining))

	text = "\n".join(lines)
