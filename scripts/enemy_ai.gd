extends Node3D

## Simple autonomous wander AI for a roaming enemy fighter: picks a random
## point within a bounded flight volume around the map center, steers
## smoothly toward it, and cruises forward — re-picking a new target once
## it gets close, or once it strays past the boundary.
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
## wander steering with a climb until clear. Forced off automatically once
## the engine is badly damaged (see DAMAGE below) — a struggling engine
## can't reliably out-climb terrain either.
##
## DAMAGE — see docs/damage-reference.md for the full design and the real
## flight-sim sources (DCS, Star Citizen) it's grounded in. Three
## independent health pools (cockpit/engine/hull), not one shared bar —
## laser_bolt.gd classifies each hit by local Z position and calls
## apply_damage(). Cockpit and hull both destroy the ship instantly at 0
## (pilot killed / structural failure). Engine damage is a process, not a
## switch: cruise speed and turn rate scale down as engine_health drops,
## ground avoidance cuts out below 30%, and at 0 the engine dies entirely —
## the ship glides forward at a fixed low speed while losing altitude until
## it meets the terrain through the SAME ground-collision check above, no
## separate destruction path needed. Each zone also grows persistent smoke
## as its health drops, escalating in two stages.

const RESPAWN_DELAY := 10.0
const SOFT_PARTICLE_TEXTURE := preload("res://Assets/Textures/soft_particle.png")
const SHIP_HIT_EFFECT := preload("res://scenes/ShipHitEffect.tscn")

@export var terrain_path: NodePath = ^"../Terrain"
@export var bounds_center: Vector3 = Vector3.ZERO
@export var bounds_radius: float = 40000.0
@export var min_altitude: float = 200.0  # above terrain
@export var max_altitude: float = 3000.0  # above terrain
@export var cruise_speed: float = 165.0  # m/s (75% of the original 220) — full-health speed
@export var turn_rate: float = 0.4  # steering responsiveness, higher = tighter turns — full-health rate
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

## Shown on the target-lock info readout (target_lock.gd).
@export var display_name: String = "HOSTILE-1"

@export_group("Damage")
@export var cockpit_max_health: float = 40.0
@export var engine_max_health: float = 60.0
@export var hull_max_health: float = 100.0
@export var dead_engine_glide_speed: float = 40.0  # m/s, momentum after power loss
@export var dead_engine_descent_rate: float = 15.0  # m/s downward while gliding dead

## Hit-zone boundaries along local Z (see docs/damage-reference.md — nose is
## the more-negative-Z end, matching this AI's own forward convention).
## Measured from ship1.obj's actual mesh bounds at the ship's 2x scale, not
## guessed.
const ZONE_FRONT_Z := -3.27
const ZONE_BACK_Z := 3.88

## Live status, readable by other scripts (target_lock.gd's info readout,
## the HUD, etc).
var crashed: bool = false
var engine_dead: bool = false
var cockpit_health: float
var engine_health: float
var hull_health: float

var _terrain: Node
var _target_point: Vector3 = Vector3.ZERO
var _respawn_timer: float = 0.0

var _cockpit_smoke: GPUParticles3D
var _engine_smoke: GPUParticles3D
var _hull_smoke: GPUParticles3D
var _cockpit_smoke_stage: int = 0
var _engine_smoke_stage: int = 0
var _hull_smoke_stage: int = 0


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)

	cockpit_health = cockpit_max_health
	engine_health = engine_max_health
	hull_health = hull_max_health

	var third := (ZONE_BACK_Z - ZONE_FRONT_Z) / 3.0
	_cockpit_smoke = _build_damage_smoke(Vector3(0.0, 0.3, ZONE_FRONT_Z + third * 0.5))
	_hull_smoke = _build_damage_smoke(Vector3(0.0, 0.3, 0.0))
	_engine_smoke = _build_damage_smoke(Vector3(0.0, 0.3, ZONE_BACK_Z - third * 0.5))

	var spawn_x := bounds_center.x
	var spawn_z := bounds_center.z - initial_spawn_distance  # -Z: in front of the player's default facing
	var ground_height: float = _terrain.get_height_at(spawn_x, spawn_z) if _terrain else 0.0
	global_position = Vector3(spawn_x, ground_height + initial_spawn_altitude, spawn_z)

	_pick_new_target()


func _physics_process(delta: float) -> void:
	if not _terrain:
		return

	if crashed:
		_respawn_timer = maxf(0.0, _respawn_timer - delta)
		if _respawn_timer <= 0.0:
			_respawn()
		return

	if engine_dead:
		global_position += -global_transform.basis.z * dead_engine_glide_speed * delta
		global_position.y -= dead_engine_descent_rate * delta
		_check_crash_conditions()
		return

	var effective_speed := _effective_cruise_speed()
	var effective_turn := _effective_turn_rate()
	var avoidance_active := ground_avoidance_enabled and _engine_health_fraction() >= 0.3

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
	var desired_forward := _get_desired_forward(current_forward, to_target, effective_speed, avoidance_active)
	var new_forward := current_forward.slerp(desired_forward, clampf(effective_turn * delta, 0.0, 1.0))
	if new_forward.length() > 0.01:
		global_transform.basis = Basis.looking_at(new_forward.normalized(), Vector3.UP)

	global_position += -global_transform.basis.z * effective_speed * delta

	_check_crash_conditions()


func _check_crash_conditions() -> void:
	var ground_height: float = _terrain.get_height_at(global_position.x, global_position.z)
	if global_position.y <= ground_height:
		_crash()
		return

	if CrashEffects.check_building_collision(get_world_3d().direct_space_state, global_position):
		_crash()


func _engine_health_fraction() -> float:
	return engine_health / engine_max_health if engine_max_health > 0.0 else 1.0


## Wounded engine = less power and worse handling, not full power until it
## isn't — see docs/damage-reference.md.
func _effective_cruise_speed() -> float:
	return cruise_speed * clampf(_engine_health_fraction(), 0.35, 1.0)


func _effective_turn_rate() -> float:
	return turn_rate * clampf(_engine_health_fraction(), 0.4, 1.0)


## When healthy, overrides the wander target with a hard climb whenever
## ground clearance is (or is about to become, per the lookahead) too low —
## a reactive "pull up", not real pathfinding. Disabled when avoidance is
## off (ground_avoidance_enabled=false, or engine health under 30%).
func _get_desired_forward(current_forward: Vector3, to_target: Vector3, speed: float, avoidance_active: bool) -> Vector3:
	if not avoidance_active:
		return to_target.normalized()

	var ground_here: float = _terrain.get_height_at(global_position.x, global_position.z)
	var clearance_here := global_position.y - ground_here

	var lookahead_pos := global_position + current_forward * speed * lookahead_time
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
	crashed = true
	_respawn_timer = RESPAWN_DELAY
	visible = false
	CrashEffects.spawn(get_tree().current_scene, _terrain, global_position)


func _respawn() -> void:
	crashed = false
	engine_dead = false
	cockpit_health = cockpit_max_health
	engine_health = engine_max_health
	hull_health = hull_max_health
	_cockpit_smoke_stage = 0
	_engine_smoke_stage = 0
	_hull_smoke_stage = 0
	_cockpit_smoke.emitting = false
	_engine_smoke.emitting = false
	_hull_smoke.emitting = false
	_pick_new_target()
	global_position = _target_point
	visible = true


## Instantaneous world-space velocity — exact, not estimated, since this AI
## is purely kinematic (always moving at its current effective speed along
## its current facing, no separate velocity state to track). Used by
## target_lock.gd for the lead/PIP calculation.
func get_velocity() -> Vector3:
	if crashed:
		return Vector3.ZERO
	if engine_dead:
		return -global_transform.basis.z * dead_engine_glide_speed
	return -global_transform.basis.z * _effective_cruise_speed()


## Classifies a LOCAL-space hit position (laser_bolt.gd already computed
## this from the world-space hit point via to_local()) into one of the
## three zones.
func classify_hit_zone(local_pos: Vector3) -> String:
	var third := (ZONE_BACK_Z - ZONE_FRONT_Z) / 3.0
	var cockpit_boundary := ZONE_FRONT_Z + third
	var engine_boundary := ZONE_BACK_Z - third
	if local_pos.z <= cockpit_boundary:
		return "cockpit"
	if local_pos.z >= engine_boundary:
		return "engine"
	return "hull"


## Applies damage to the given zone, spawns a hit-spark at the impact
## point, and triggers whatever that zone's health crossing a threshold
## should do — see the class comment / docs/damage-reference.md.
func apply_damage(amount: float, zone: String, hit_world_position: Vector3) -> void:
	if crashed:
		return

	match zone:
		"cockpit":
			cockpit_health = maxf(0.0, cockpit_health - amount)
			_update_smoke_stage(_cockpit_smoke, cockpit_health / cockpit_max_health, "_cockpit_smoke_stage")
			if cockpit_health <= 0.0:
				_spawn_hit_effect(hit_world_position)
				_crash()
				return
		"engine":
			engine_health = maxf(0.0, engine_health - amount)
			_update_smoke_stage(_engine_smoke, engine_health / engine_max_health, "_engine_smoke_stage")
			if engine_health <= 0.0 and not engine_dead:
				engine_dead = true
				ground_avoidance_enabled = false
		"hull":
			hull_health = maxf(0.0, hull_health - amount)
			_update_smoke_stage(_hull_smoke, hull_health / hull_max_health, "_hull_smoke_stage")
			if hull_health <= 0.0:
				_spawn_hit_effect(hit_world_position)
				_crash()
				return

	_spawn_hit_effect(hit_world_position)


func _spawn_hit_effect(world_position: Vector3) -> void:
	var effect := SHIP_HIT_EFFECT.instantiate()
	get_tree().current_scene.add_child(effect)
	effect.global_position = world_position


## Two-stage escalation (light smoke under 66% zone health, heavier under
## 33%) — the simplified version of DCS's smoke-then-fire progression this
## project's particle-effect approach can actually build. `stage_var_name`
## lets one function serve all three zones without three near-identical
## copies.
func _update_smoke_stage(smoke: GPUParticles3D, health_fraction: float, stage_var_name: String) -> void:
	var stage: int = get(stage_var_name)
	var new_stage := stage
	if health_fraction <= 0.33:
		new_stage = 2
	elif health_fraction <= 0.66:
		new_stage = 1
	else:
		new_stage = 0

	if new_stage == stage:
		return
	set(stage_var_name, new_stage)

	if new_stage == 0:
		smoke.emitting = false
		return

	smoke.amount = 20 if new_stage == 1 else 45
	smoke.restart()
	smoke.emitting = true


func _build_damage_smoke(local_pos: Vector3) -> GPUParticles3D:
	var smoke := GPUParticles3D.new()
	add_child(smoke)
	smoke.position = local_pos
	smoke.emitting = false
	smoke.amount = 20
	smoke.lifetime = 2.5
	smoke.visibility_aabb = AABB(Vector3(-15, -2, -15), Vector3(30, 30, 30))

	var quad := QuadMesh.new()
	quad.size = Vector2(0.7, 0.7)
	smoke.draw_pass_1 = quad

	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(0.05, 0.05, 0.05, 1.0)
	mat.albedo_texture = SOFT_PARTICLE_TEXTURE
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	smoke.material_override = mat

	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	gradient.colors = PackedColorArray([
		Color(0.05, 0.05, 0.05, 0.8), Color(0.05, 0.05, 0.05, 0.6), Color(0.05, 0.05, 0.05, 0.0),
	])
	var gradient_texture := GradientTexture1D.new()
	gradient_texture.gradient = gradient

	var process_mat := ParticleProcessMaterial.new()
	process_mat.direction = Vector3.UP
	process_mat.spread = 20.0
	process_mat.initial_velocity_min = 1.5
	process_mat.initial_velocity_max = 3.0
	process_mat.gravity = Vector3(0.0, -0.1, 0.0)
	process_mat.damping_min = 0.3
	process_mat.damping_max = 0.5
	process_mat.scale_min = 0.6
	process_mat.scale_max = 1.3
	process_mat.color_ramp = gradient_texture
	process_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	process_mat.emission_sphere_radius = 0.3
	smoke.process_material = process_mat

	return smoke
