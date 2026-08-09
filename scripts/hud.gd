extends Label3D

## Simple cockpit HUD readout: FPS, current speed, live weapon-system status
## (right controller active, trigger state, fire cooldown, shot count),
## crash/respawn status, and distance to the city objective (paired with the
## EnemyLocator arrow) — so issues are visible in-headset instead of only
## in the editor console. The FPS line exists mainly to tell "the game is
## actually dropping frames" apart from "the game is fine, something
## external (OBS, Virtual Desktop encoding) is the bottleneck."
##
## PERF line added after a live report of FPS collapsing to ~6 during the
## 400-ship Faction Battle — headless testing can confirm simulation logic
## is correct (see faction_battle.gd's header) but can never measure actual
## GPU draw-call cost or VR stereo rendering time, so this is the only way
## to tell whether a slowdown is CPU-side (PHYS ms, the AI/physics-query
## loop) or GPU-side (DRAW, draw call count — the 400-ship MultiMeshes,
## bolts, and any live ShipExplosion particle/light effects) without
## guessing.

var _flight_controller: Node
var _weapon_system: Node
var _missile_system: Node
var _crash_handler: Node
var _enemy_locator: Node


func _ready() -> void:
	# Label3D -> XRCamera3D -> Player
	var camera := get_parent()
	var player := camera.get_parent()
	_flight_controller = player.get_node_or_null("FlightController")
	_weapon_system = player.get_node_or_null("WeaponSystem")
	_missile_system = player.get_node_or_null("MissileSystem")
	_crash_handler = player.get_node_or_null("CrashHandler")
	_enemy_locator = camera.get_node_or_null("EnemyLocator")


func _process(_delta: float) -> void:
	var fps_text := "FPS: %d" % Engine.get_frames_per_second()

	var perf_text := "PROC:%.1fms PHYS:%.1fms DRAW:%d OBJ:%d" % [
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			Performance.get_monitor(Performance.OBJECT_COUNT),
	]

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

	# Missile lock state. Worth a permanent HUD line: the weapon is a
	# hold-the-left-trigger lock (see missile_system.gd) and without a
	# readout there's no way to tell "nothing is designated" apart from
	# "locking" apart from "the weapon is broken" — which is exactly how the
	# previous lock design failed silently.
	var missile_text := "MSL: --"
	if _missile_system:
		if _missile_system.locked:
			missile_text = "MSL: LOCKED — release to fire"
		elif _missile_system.acquiring:
			if _missile_system.tracked_target_index >= 0:
				missile_text = "MSL: LOCKING %d%%" % roundi(
						100.0 * _missile_system.lock_progress / maxf(_missile_system.lock_time, 0.001))
			else:
				missile_text = "MSL: no target in cone"
		else:
			missile_text = "MSL: hold left trigger"

	var enemy_text := "CITY: --"
	if _enemy_locator and _enemy_locator.distance_to_objective >= 0.0:
		enemy_text = "CITY: %d m — follow the yellow arrow" % roundi(_enemy_locator.distance_to_objective)

	var lines := [fps_text, perf_text, speed_text, gun_text, missile_text, enemy_text]
	if _crash_handler and _crash_handler.crashed:
		lines.append("CRASHED — respawning in %ds" % ceili(_crash_handler.respawn_time_remaining))

	text = "\n".join(lines)
