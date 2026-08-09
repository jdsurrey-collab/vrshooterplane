extends Node

## Player-side mirror of enemy_ai.gd's damage model (see
## docs/damage-reference.md) — three independent health pools (cockpit,
## engine, hull), zone-classified by local-Z position along `ShipHull`
## (same ship1.obj mesh and 2x scale the enemy uses, so the same
## ZONE_FRONT_Z/ZONE_BACK_Z boundaries apply directly — ShipHull carries no
## extra rotation relative to it, unlike the cockpit model, see
## scenes/Player.tscn).
##
## Cockpit or hull reaching 0 triggers the same crash sequence as a
## terrain/building impact (CrashHandler.trigger_crash()) — pilot killed /
## structural failure, matching the enemy's instant-destroy zones. Engine
## reaching 0 is tracked but has no flight-degradation effect yet (the
## enemy's progressive speed/turn-rate falloff wasn't ported over — out of
## scope for this pass, see CLAUDE.md's known gaps).
##
## Every hit plays one of the four DamageAudio hit sounds.
##
## Nothing can actually call apply_damage() yet — laser_bolt.gd only spawns
## player-owned bolts right now (see its `fired_by_player` flag), and no
## enemy weapon exists. This is real and testable via apply_damage()
## directly, but has no live trigger until an enemy can fire back.

const ZONE_FRONT_Z := -3.27
const ZONE_BACK_Z := 3.88

@export var cockpit_max_health: float = 40.0
@export var engine_max_health: float = 60.0
@export var hull_max_health: float = 100.0

## Live status, readable by the HUD.
var cockpit_health: float
var engine_health: float
var hull_health: float

var _player: Node3D
var _ship_hull: Node3D
var _crash_handler: Node
var _damage_audio: Node


func _ready() -> void:
	_player = get_parent()
	_ship_hull = _player.get_node_or_null("ShipHull")
	_crash_handler = _player.get_node_or_null("CrashHandler")
	_damage_audio = _player.get_node_or_null("DamageAudio")
	reset_health()


func reset_health() -> void:
	cockpit_health = cockpit_max_health
	engine_health = engine_max_health
	hull_health = hull_max_health


## World-space hit position -> zone name. Converts into ShipHull's local
## space (undoing its 2x scale) to land in the same coordinate convention
## enemy_ai.gd's ZONE_FRONT_Z/ZONE_BACK_Z were measured in.
func classify_hit_zone(hit_world_pos: Vector3) -> String:
	if not _ship_hull:
		return "hull"

	var local_z: float = (_ship_hull.global_transform.affine_inverse() * hit_world_pos).z * 2.0
	var third := (ZONE_BACK_Z - ZONE_FRONT_Z) / 3.0
	var cockpit_boundary := ZONE_FRONT_Z + third
	var engine_boundary := ZONE_BACK_Z - third
	if local_z <= cockpit_boundary:
		return "cockpit"
	if local_z >= engine_boundary:
		return "engine"
	return "hull"


func apply_damage(amount: float, zone: String) -> void:
	if _crash_handler and _crash_handler.crashed:
		return

	match zone:
		"cockpit":
			cockpit_health = maxf(0.0, cockpit_health - amount)
		"engine":
			engine_health = maxf(0.0, engine_health - amount)
		_:
			hull_health = maxf(0.0, hull_health - amount)

	if _damage_audio and _damage_audio.has_method("play_random_hit"):
		_damage_audio.play_random_hit()

	if (cockpit_health <= 0.0 or hull_health <= 0.0) and _crash_handler and _crash_handler.has_method("trigger_crash"):
		_crash_handler.trigger_crash()


func cockpit_health_fraction() -> float:
	return cockpit_health / cockpit_max_health if cockpit_max_health > 0.0 else 0.0


func engine_health_fraction() -> float:
	return engine_health / engine_max_health if engine_max_health > 0.0 else 0.0


func hull_health_fraction() -> float:
	return hull_health / hull_max_health if hull_max_health > 0.0 else 0.0
