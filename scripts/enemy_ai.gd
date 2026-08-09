extends Node3D

## Simple autonomous wander AI for a roaming enemy fighter: picks a random
## point within a bounded flight volume around the map center, steers
## smoothly toward it, and cruises forward — re-picking a new target once
## it gets close, or once it strays past the boundary. No combat behavior
## yet, this is just "have something flying around the map."
##
## "Stay within the bounds of the skybox" — the skybox itself is just a
## background panorama with no real geometry/collision to bound against, so
## `bounds_radius` is a simulated flight boundary instead (comfortably
## inside the terrain's own extent).
##
## Ground collision reuses the same approach as the player
## (crash_handler.gd): no physics body, so each frame position is checked
## directly against the terrain's heightmap surface (Terrain.get_height_at).
## Buildings are checked too, via CrashEffects.check_building_collision()
## (a physics point query against city_generator.gd's collision layer —
## there's no heightmap shortcut for discrete scattered objects). On either
## kind of impact it spawns the same crash effect/debris as the player
## (CrashEffects, shared with crash_handler.gd), hides, waits
## RESPAWN_DELAY seconds, then reappears at a fresh point in the air.
##
## GROUND AVOIDANCE — `ground_avoidance_enabled` gates a reactive pull-up:
## each frame it checks clearance both at the current position AND at a
## projected point `lookahead_time` seconds ahead along the current
## heading: if either is under `min_ground_clearance`, it overrides normal
## wander steering with a climb until clear. This is the hook for the
## planned engine-failure system — a damaged/failing ship should fly with
## `ground_avoidance_enabled = false` so it can actually crash from bad
## flying instead of always safely pulling up, while a healthy one avoids
## the ground. No health/damage state exists yet, this is just the toggle
## that system will flip.

const RESPAWN_DELAY := 10.0

@export var terrain_path: NodePath = ^"../Terrain"
@export var bounds_center: Vector3 = Vector3.ZERO
@export var bounds_radius: float = 40000.0
@export var min_altitude: float = 200.0  # above terrain
@export var max_altitude: float = 3000.0  # above terrain
@export var cruise_speed: float = 165.0  # m/s (75% of the original 220)
@export var turn_rate: float = 0.4  # steering responsiveness, higher = tighter turns
@export var retarget_distance: float = 500.0  # pick a new target once this close
@export var altitude_drift: float = 400.0  # max altitude change per retarget, see _pick_new_target

@export_group("Ground Avoidance")
@export var ground_avoidance_enabled: bool = true
@export var min_ground_clearance: float = 150.0  # meters; pull up if under this
@export var lookahead_time: float = 4.0  # seconds ahead to check clearance too

## First-spawn-only placement, close enough to actually see and confirm
## it's working — bounds_radius (tens of km) is way too far to notice.
## Only used once in _ready(); every respawn after a crash goes back to the
## normal wide-area _pick_new_target().
@export var initial_spawn_distance: float = 300.0  # meters from bounds_center
@export var initial_spawn_altitude: float = 300.0  # above terrain

var _terrain: Node
var _target_point: Vector3 = Vector3.ZERO
var _crashed: bool = false
var _respawn_timer: float = 0.0


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)

	var spawn_x := bounds_center.x
	var spawn_z := bounds_center.z - initial_spawn_distance  # -Z: in front of the player's default facing
	var ground_height: float = _terrain.get_height_at(spawn_x, spawn_z) if _terrain else 0.0
	global_position = Vector3(spawn_x, ground_height + initial_spawn_altitude, spawn_z)

	_pick_new_target()


func _physics_process(delta: float) -> void:
	if not _terrain:
		return

	if _crashed:
		_respawn_timer = maxf(0.0, _respawn_timer - delta)
		if _respawn_timer <= 0.0:
			_respawn()
		return

	# Hard boundary: if we've strayed outside bounds_radius, override the
	# current target with a point back toward the center so the ship can't
	# just keep wandering off between retargets.
	if global_position.distance_to(bounds_center) > bounds_radius:
		_target_point = bounds_center + Vector3(0.0, global_position.y - bounds_center.y, 0.0)

	var to_target := _target_point - global_position
	if to_target.length() < retarget_distance:
		_pick_new_target()
		to_target = _target_point - global_position

	var current_forward := -global_transform.basis.z
	var desired_forward := _get_desired_forward(current_forward, to_target)
	var new_forward := current_forward.slerp(desired_forward, clampf(turn_rate * delta, 0.0, 1.0))
	if new_forward.length() > 0.01:
		global_transform.basis = Basis.looking_at(new_forward.normalized(), Vector3.UP)

	global_position += -global_transform.basis.z * cruise_speed * delta

	var ground_height: float = _terrain.get_height_at(global_position.x, global_position.z)
	if global_position.y <= ground_height:
		_crash()
		return

	if CrashEffects.check_building_collision(get_world_3d().direct_space_state, global_position):
		_crash()


## When healthy, overrides the wander target with a hard climb whenever
## ground clearance is (or is about to become, per the lookahead) too low —
## a reactive "pull up", not real pathfinding. Disabled entirely for a
## damaged/failing ship (see the class comment).
func _get_desired_forward(current_forward: Vector3, to_target: Vector3) -> Vector3:
	if not ground_avoidance_enabled:
		return to_target.normalized()

	var ground_here: float = _terrain.get_height_at(global_position.x, global_position.z)
	var clearance_here := global_position.y - ground_here

	var lookahead_pos := global_position + current_forward * cruise_speed * lookahead_time
	var ground_ahead: float = _terrain.get_height_at(lookahead_pos.x, lookahead_pos.z)
	var clearance_ahead := lookahead_pos.y - ground_ahead

	if clearance_here < min_ground_clearance or clearance_ahead < min_ground_clearance:
		return (current_forward + Vector3.UP * 1.5).normalized()

	return to_target.normalized()


## Altitude drifts gradually from wherever the ship currently is, instead
## of being re-randomized across the full min/max band every time — picking
## a fresh independent altitude on every retarget (which could easily swing
## nearly 3km) was the actual cause of the constant climbs/dives. Real
## patrol flight mostly holds a cruising band and only gently drifts.
func _pick_new_target() -> void:
	var angle := randf() * TAU
	var dist := randf_range(bounds_radius * 0.2, bounds_radius)
	var x := bounds_center.x + cos(angle) * dist
	var z := bounds_center.z + sin(angle) * dist
	var ground_height: float = _terrain.get_height_at(x, z) if _terrain else 0.0

	var ground_here: float = _terrain.get_height_at(global_position.x, global_position.z) if _terrain else 0.0
	var current_altitude := global_position.y - ground_here
	var new_altitude := clampf(
			current_altitude + randf_range(-altitude_drift, altitude_drift), min_altitude, max_altitude)

	_target_point = Vector3(x, ground_height + new_altitude, z)


func _crash() -> void:
	_crashed = true
	_respawn_timer = RESPAWN_DELAY
	visible = false
	CrashEffects.spawn(get_tree().current_scene, _terrain, global_position)


func _respawn() -> void:
	_crashed = false
	_pick_new_target()
	global_position = _target_point
	visible = true
