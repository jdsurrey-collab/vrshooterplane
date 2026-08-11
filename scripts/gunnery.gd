class_name Gunnery
extends Node

## Single, shared firing-solution solver for the player's twin-gun laser
## weapon — Phase 2/3 of the gunnery overhaul (see CLAUDE.md). Computes one
## firing solution per physics frame and every consumer (weapon_system.gd's
## gun aim, target_lock.gd's PIP) reads it, replacing three separate
## approximations of the same problem that had drifted apart.
##
## THE REAL BUG THIS FIXES, PRECISELY STATED. target_lock.gd's PIP ring was
## already solving its intercept from the GUN MOUNTS' own midpoint, not the
## camera — only the PIP's on-screen DISPLAY direction used the camera, the
## same visor-anchored technique every HUD element in this project already
## uses, and that part was always correct. The actual gap was that
## weapon_system.gd's guns never read that solution at all:
## `_setup_convergence()` toed both mounts in ONCE in `_ready()` at a fixed
## 229m and never touched them again. So even a shot lined up perfectly on
## the PIP only truly lands if the target happens to be at almost exactly
## 229m — at any other range the two barrels cross at the wrong point in
## space and straddle the target regardless of where the ship's nose points.
## DYNAMIC, PER-FRAME CONVERGENCE (see weapon_system.gd's `_update_gun_convergence`)
## is what actually closes that gap. This solver is what makes "converge at
## the target's true range" one well-defined operation instead of a fourth
## ad hoc calculation living in weapon_system.gd on top of the two that
## already existed in target_lock.gd and faction_battle.gd.
##
## GIMBAL ASSIST — Star Citizen's actual model, confirmed directly: tracks
## the Y-LOCKED target ONLY, never an unlocked one. A furball of 200 ships
## makes "whatever's nearest the nose" an unstable thing to gimbal onto, and
## gating behind a deliberate lock keeps the assist a deliberate act rather
## than free aim-lock — you still have to do the work of designating a
## target. Within `gimbal_cone_deg` of the true lead direction AND inside
## `lethal_range`, the guns deflect onto the lead point, hard-capped by
## `gimbal_max_deflection_deg`; outside the cone, past lethal range, or with
## no lock, the guns hold the ship's own bore line and the player leads
## manually. The cone is what keeps this a skill check — it removes only the
## residual convergence/parallax error once the player has already done the
## hard part of pointing roughly at the solution.
##
## RANGE BANDS AND DISPERSION. `lethal_range` (1200m) is full accuracy with
## the gimbal live; `max_range` (2000m) is the outer edge of "can still hit,
## unreliably" — `dispersion_deg` ramps 0 -> `max_dispersion_deg` across that
## band, read by weapon_system.gd to jitter the actual fired bolt.
## Deliberately driven off `convergence_distance` rather than a separate
## target-range lookup: with no lock, convergence sits at
## `default_convergence_distance` (229m, well under lethal_range), so
## dispersion is naturally zero with nothing designated — the guns are
## "zeroed" at their default distance, full accuracy, exactly matching the
## old fixed-229m behaviour when nothing is locked.

enum RangeBand { LETHAL, DEGRADED, OUT_OF_RANGE }

@export var battle_path: NodePath = ^"../../FactionBattle"
@export var target_lock_path: NodePath = ^"../TargetLock"
@export var gun_left_path: NodePath = ^"../Ship/GunMountLeft"
@export var gun_right_path: NodePath = ^"../Ship/GunMountRight"
@export var bolt_speed: float = 600.0  # must match laser_bolt.gd's `speed`

## Range bands — laser_bolt.gd's own max_range despawn is kept in step with
## `max_range` here by hand, the same documented coupling this project
## already carries elsewhere (e.g. target_lock.gd's bolt_speed comment).
@export var lethal_range: float = 1200.0
@export var max_range: float = 2000.0

@export var gimbal_cone_deg: float = 2.0
@export var gimbal_max_deflection_deg: float = 6.0
@export var max_dispersion_deg: float = 3.5

## Fallback convergence distance with nothing locked — the original fixed
## 229m WWII harmonization figure (see docs/gunnery-reference.md), still the
## right default absent any better information.
@export var default_convergence_distance: float = 229.0

var has_solution: bool = false
var target_index: int = -1
var target_position: Vector3 = Vector3.ZERO
var target_velocity: Vector3 = Vector3.ZERO
var range_to_target: float = 0.0
var bore_direction: Vector3 = Vector3.FORWARD  # ship-forward, no assist applied
var lead_point: Vector3 = Vector3.ZERO  # true intercept, world space
var aim_error_deg: float = 999.0  # angle between the bore and the true lead direction
var assist_active: bool = false
var range_band: int = RangeBand.OUT_OF_RANGE
var gun_aim_point: Vector3 = Vector3.ZERO  # where the guns should converge THIS frame
var convergence_distance: float = 229.0  # scalar version of the above, for weapon_system's toe-in
var dispersion_deg: float = 0.0  # current fired-shot inaccuracy — see class comment

var _origin: Node3D  # XROrigin3D — true forward, matching every other "which way is forward" use in this project
var _battle: Node
var _target_lock: Node
var _gun_left: Node3D
var _gun_right: Node3D


func _ready() -> void:
	_origin = get_parent()
	_battle = get_node_or_null(battle_path)
	_target_lock = get_node_or_null(target_lock_path)
	_gun_left = get_node_or_null(gun_left_path)
	_gun_right = get_node_or_null(gun_right_path)


func _physics_process(_delta: float) -> void:
	_solve()


func _gun_midpoint() -> Vector3:
	if _gun_left and _gun_right:
		return (_gun_left.global_position + _gun_right.global_position) * 0.5
	return _origin.global_position if _origin else Vector3.ZERO


func _solve() -> void:
	has_solution = false
	assist_active = false
	target_index = -1
	bore_direction = -_origin.global_transform.basis.z if _origin else Vector3.FORWARD

	var shooter_pos := _gun_midpoint()

	if _target_lock and _target_lock.locked and _battle and _battle.is_alive(_target_lock.locked_index):
		target_index = _target_lock.locked_index
		target_position = _battle.get_alien_position(target_index)
		target_velocity = _battle.get_velocity(target_index)
		range_to_target = shooter_pos.distance_to(target_position)
		lead_point = solve_intercept(shooter_pos, target_position, target_velocity, bolt_speed)
		has_solution = true

		var to_lead := lead_point - shooter_pos
		aim_error_deg = rad_to_deg(bore_direction.angle_to(to_lead.normalized())) if to_lead.length() > 0.01 else 0.0
		range_band = _classify_range(range_to_target)

		if range_band == RangeBand.LETHAL and aim_error_deg <= gimbal_cone_deg:
			assist_active = true
	else:
		range_to_target = 0.0
		range_band = RangeBand.OUT_OF_RANGE
		aim_error_deg = 999.0

	_update_gun_aim_point(shooter_pos)


func _classify_range(d: float) -> int:
	if d <= lethal_range:
		return RangeBand.LETHAL
	if d <= max_range:
		return RangeBand.DEGRADED
	return RangeBand.OUT_OF_RANGE


## Where the guns should converge THIS frame — DYNAMIC CONVERGENCE, always
## on regardless of whether the gimbal assist itself is active. This only
## corrects the two guns straddling the target at any range other than a
## fixed distance; it adds no lead/aim help by itself. With no target it
## falls back to `default_convergence_distance` along the ship's own bore,
## matching the old fixed-229m behaviour exactly.
func _update_gun_aim_point(shooter_pos: Vector3) -> void:
	if not has_solution:
		convergence_distance = default_convergence_distance
		dispersion_deg = 0.0
		gun_aim_point = shooter_pos + bore_direction * default_convergence_distance
		return

	convergence_distance = clampf(range_to_target, 5.0, max_range * 1.5)

	# Dispersion is a function of WHERE THE GUNS ARE ZEROED, not a separate
	# target-range check — see the class comment for why that's the right
	# source rather than range_to_target directly.
	if convergence_distance > lethal_range:
		var t := clampf((convergence_distance - lethal_range) / maxf(max_range - lethal_range, 0.001), 0.0, 1.0)
		dispersion_deg = t * max_dispersion_deg
	else:
		dispersion_deg = 0.0

	if assist_active:
		gun_aim_point = shooter_pos + _deflected_direction(bore_direction, lead_point - shooter_pos) * convergence_distance
	else:
		gun_aim_point = shooter_pos + bore_direction * convergence_distance


## Rotates `bore` toward `to_lead`, capped at `gimbal_max_deflection_deg` —
## a hard ceiling on how far the assist can pull the guns off the ship's own
## bore, independent of how far off the true lead solution actually is. In
## practice `assist_active` only ever goes true within `gimbal_cone_deg`
## (2 degrees), well inside the cap (6 degrees), so this ceiling is a
## deliberate safety net rather than something normally reached — worth
## keeping explicit in case the two are ever retuned inconsistently.
func _deflected_direction(bore: Vector3, to_lead_raw: Vector3) -> Vector3:
	if to_lead_raw.length() < 0.01:
		return bore
	var to_lead := to_lead_raw.normalized()
	var angle := bore.angle_to(to_lead)
	if angle < 0.0001:
		return to_lead
	var max_rad := deg_to_rad(gimbal_max_deflection_deg)
	var f := clampf(max_rad / angle, 0.0, 1.0)
	return bore.slerp(to_lead, f)


## Shared quadratic firing solution — the one copy now used by
## target_lock.gd's PIP, this solver's own `lead_point`, and (unchanged in
## behaviour, just de-duplicated) faction_battle.gd's AI gunnery via
## `_lead_point()`'s thin wrapper. Given a bullet_speed and the target's
## current position/velocity, returns the point a bullet fired NOW would
## meet it — solves a*t^2 + b*t + c = 0 for the smallest positive t from
## |rel_pos + target_vel*t| = bullet_speed*t, falling back to the target's
## current position when there is no valid positive-time solution (e.g. it's
## outrunning the bolt). See docs/gunnery-reference.md.
static func solve_intercept(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, bullet_speed: float) -> Vector3:
	var rel := target_pos - shooter_pos
	var a := target_vel.dot(target_vel) - bullet_speed * bullet_speed
	var b := 2.0 * rel.dot(target_vel)
	var c := rel.dot(rel)

	var t := -1.0
	if absf(a) < 0.0001:
		if absf(b) > 0.0001:
			t = -c / b
	else:
		var disc := b * b - 4.0 * a * c
		if disc >= 0.0:
			var sqrt_d := sqrt(disc)
			var t1 := (-b + sqrt_d) / (2.0 * a)
			var t2 := (-b - sqrt_d) / (2.0 * a)
			if t1 > 0.0 and t2 > 0.0:
				t = minf(t1, t2)
			elif t1 > 0.0:
				t = t1
			elif t2 > 0.0:
				t = t2

	if t <= 0.0:
		return target_pos
	return target_pos + target_vel * t
