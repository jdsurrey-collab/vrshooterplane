extends Node

## Homing missile weapon — HOLD the left trigger to run a lock, RELEASE to
## launch. This is the third iteration of this system and the one that
## matches how modern combat flight games (Ace Combat, Star Wars:
## Squadrons, Project Wingman) actually do it:
##
##   1. Hold the left trigger. Whatever you're pointed at gets designated.
##   2. A search tone pulses while the lock builds, accelerating as it
##      approaches completion — the audio tells you how close you are
##      without needing to read a HUD element.
##   3. At LOCK_TIME the tone goes solid: lock acquired.
##   4. Release the trigger. If the lock completed, the missile fires at
##      release. If it didn't, nothing launches and progress is discarded.
##
## The two previous designs both failed for the same underlying reason —
## they made lock *acquisition* implicit. The first ran its own aim cone
## against the gun crosshair and re-picked "nearest in cone" every frame, so
## it flickered between clustered targets and never accumulated progress.
## The second required target_lock.gd's Y-button lock to already be held on
## the target for five continuous seconds, which meant the missile could
## only ever be used after a separate, unrelated button ritual, and there
## was no feedback at all if that precondition wasn't met — from the
## cockpit it simply looked like the weapon did nothing. Holding a trigger
## is self-explanatory and self-correcting: the tone starts, or it doesn't.
##
## TARGET DESIGNATION, in priority order:
##   * target_lock.gd's Y-locked target, if one is active and alive. Y-lock
##     stays the way to deliberately pick a specific ship out of a furball
##     (it cycles nearest-to-farthest — see that script) and it also drives
##     the targeting box / PIP ring, so honouring it here keeps one obvious
##     "this is my target" concept rather than two competing ones.
##   * Otherwise, the nearest living alien inside LOCK_CONE of the ship's
##     nose and within LOCK_RANGE.
##
## Progress resets to zero — no partial credit — if the designated target
## changes, dies, or leaves the cone/range while you're holding.
##
## FORWARD-DIRECTION GOTCHA (a real bug that made this weapon look broken
## even when the lock logic was fine): do NOT take the ship's facing from
## the `Ship` node. Ship carries a 180-degree flip basis to correct the
## cockpit glTF's backwards-authored forward direction (see Player.tscn),
## so `-Ship.global_transform.basis.z` points BEHIND the craft. Both the aim
## cone and the launch orientation here use the XROrigin3D rig instead,
## whose -Z is unambiguously forward and is what flight_controller.gd
## actually flies. Previously the missile was spawned with Ship's basis and
## therefore launched backwards, which also meant missile.gd measured ~180
## degrees to its target on frame one and immediately latched its
## overshoot/ballistic handoff — every shot flew away from the target and
## never came back. The guns were never affected because weapon_system.gd
## spawns from the gun mounts, which carry their own compensating flip.

## LOCK RETICLE — a visor-anchored HUD cursor that shoots in from off to the
## side and spins around the designated target while the lock builds,
## slowing to a steady solid ring and turning green the instant `locked`
## goes true, matching the lock-on reticle modern flight/combat games use
## (Ace Combat, Star Wars: Squadrons). Disappears the instant tracking stops
## — trigger released, target lost, or target switched (in which case a new
## one immediately flies in on the new target, since that's a fresh lock
## attempt with no partial credit, same as the audio/haptic feedback above).
##
## Built and driven entirely inside this script, the same convention
## target_lock.gd uses for its own targeting box/PIP ring/info label — no
## extra HUD node in Player.tscn to keep in sync. Uses the identical
## VISOR-ANCHORED technique: placed at a fixed `RETICLE_HUD_DISTANCE` from
## the camera along the real direction to the target, so it tracks the right
## screen position at any actual range without changing apparent size.
##
## The "flies in from outside the screen" entrance is a direction slerp, not
## a screen-space animation: a start direction is picked by rotating the
## true target direction off-axis by a random angle, then every frame the
## reticle's direction eases from that start toward the true target
## direction over RETICLE_FLY_IN_TIME. Composed with the fixed HUD distance,
## that reads as the reticle swooping in from a wide angle and snapping onto
## the target — no screen-space UI math needed, it's the same 3D placement
## math the rest of the lock HUD already uses, just animated.
const RETICLE_HUD_DISTANCE := 5.0  # meters from camera — matches target_lock.gd's hud_distance convention
const RETICLE_RADIUS := 0.095
const RETICLE_TICK_COUNT := 4
const RETICLE_FLY_IN_TIME := 0.3
const RETICLE_FLY_IN_ANGLE := deg_to_rad(38.0)
const RETICLE_SPIN_SPEED_START := 7.5  # rad/s while acquisition just began
const RETICLE_SPIN_SPEED_LOCKED := 0.0  # settles to a steady ring the instant it's locked — spin = "still working", steady = "ready"
const RETICLE_COLOR_ACQUIRING := Color(1.0, 0.35, 0.15, 1.0)
const RETICLE_COLOR_LOCKED := Color(0.25, 1.0, 0.3, 1.0)
const RETICLE_PULSE_SPEED := 6.0  # locked-state "ready" pulse, purely cosmetic

const MISSILE := preload("res://scenes/Missile.tscn")

## Down from the previous design's 5s. Five seconds of holding still on a
## manoeuvring target is a long time in a dogfight; 3 is enough to make the
## missile a committed shot rather than a spammable one without being
## tedious. Exported so it's tunable in the headset without a code change.
## Direct request: "let's also add a cool down for the missiles at twenty
## seconds." Previously there was NO reload gate at all — lock, release,
## fire, and the moment the trigger was pulled again the whole cycle could
## restart immediately, which is not how a limited-ordnance weapon reads in
## any reference game this project is following.
##
## ONLY THE LAUNCH is gated, not the lock — see _fire_missile()'s caller in
## _physics_process(). Being able to track and designate while the weapon
## reloads is both how these systems actually work and less frustrating than
## a dead weapon, and lock_time (3s) already usefully overlaps the tail of a
## typical cooldown. If the trigger is held THROUGH the cooldown, `locked`
## stays true (see _update_lock's early return once already locked) and
## release fires the instant reload_remaining reaches zero — no need to
## release and re-hold.
@export var missile_reload_time: float = 20.0

@export var lock_time: float = 3.0
## Widened from 9°, which was unforgivingly narrow — aliens are sparse
## across an 8km dome, so holding a 9° bead on one long enough to notice the
## weapon existed was most of the difficulty. The Y-lock takes priority
## anyway (see _designate_target), so a generous fallback cone can't steal a
## target the player deliberately picked.
@export var lock_cone_degrees: float = 22.0
@export var lock_range: float = 6000.0
@export var target_lock_path: NodePath = ^"../TargetLock"
@export var launch_mount_path: NodePath = ^"../Ship/GunMountRight"

## Search-tone pacing: interval between beeps at zero progress, and at full
## progress. Interpolated between, so the beeping visibly accelerates.
@export var beep_interval_start: float = 0.55
@export var beep_interval_end: float = 0.11

## Set by the options menu / game_flow.gd while paused, so config/menu
## states can't trigger a launch — same convention weapon_system.gd uses.
var paused: bool = false

## Live status, readable by the HUD (see hud.gd's MSL line).
var lock_progress: float = 0.0
var locked: bool = false
var acquiring: bool = false
var tracked_target_index: int = -1

## Seconds until another missile can be LAUNCHED — 0 means ready. Public
## (not underscore-prefixed) specifically so hud.gd can read it, matching
## lock_progress/locked/acquiring's own convention.
var reload_remaining: float = 0.0

var _left_controller: XRController3D
var _origin: Node3D  # XROrigin3D — the authoritative "which way is forward", see the class comment
var _ship: Node3D
var _launch_mount: Node3D
var _battle: Node
var _target_lock: Node
## Plain (non-positional) AudioStreamPlayers, NOT AudioStreamPlayer3D.
## These are cockpit sounds — your own lock tone and your own launch, both
## happening inside your own ship — so proximity is meaningless, the same
## reasoning main_menu.gd's music and missile_alert.gd's warnings already
## use. They were originally AudioStreamPlayer3D, which was a real bug and
## a subtle one: MissileSystem is a plain `Node`, so those children had no
## Node3D ancestor and their global transform fell back to identity —
## meaning both sounds played at the WORLD ORIGIN, ~4.9km from the player's
## spawn, with max_distance 800. Totally silent. The weapon appeared to do
## nothing at all because every piece of its feedback was inaudible. The
## gun sounds were never affected because they live under Ship/GunMount*,
## which is a real Node3D chain.
var _lock_audio: AudioStreamPlayer
var _launch_audio: AudioStreamPlayer

var _trigger_was_down: bool = false
var _beep_timer: float = 0.0

var _camera: Node3D
var _reticle: Node3D
var _reticle_material: StandardMaterial3D
var _reticle_last_target: int = -1
var _reticle_fly_in_t: float = 1.0  # 1.0 = settled on the true target direction, no animation in flight
var _reticle_start_dir: Vector3 = Vector3.FORWARD
var _reticle_spin_angle: float = 0.0
var _reticle_pulse_time: float = 0.0


func _ready() -> void:
	var origin := get_parent()
	_origin = origin
	_left_controller = origin.get_node_or_null("LeftHand")
	_ship = origin.get_node_or_null("Ship")
	_launch_mount = get_node_or_null(launch_mount_path)
	_battle = get_tree().current_scene.get_node_or_null("FactionBattle")
	_target_lock = get_node_or_null(target_lock_path)
	_lock_audio = get_node_or_null("LockAudio")
	_launch_audio = get_node_or_null("LaunchAudio")
	_camera = origin.get_node_or_null("XRCamera3D")
	_build_reticle()


func _physics_process(delta: float) -> void:
	if paused:
		_reset_lock()
		return

	# Ticks even with the controller inactive or nothing designated — the
	# weapon is physically reloading regardless of what the player is doing
	# with their hands right now.
	if reload_remaining > 0.0:
		reload_remaining = maxf(0.0, reload_remaining - delta)

	if not _left_controller or not _left_controller.get_is_active():
		return
	if not _origin or not _battle:
		return

	var trigger_down := _left_controller.is_button_pressed("trigger_click")

	if trigger_down:
		_update_lock(delta)
	elif _trigger_was_down:
		# Release is the trigger to launch. A completed lock only actually
		# fires if the weapon has finished reloading — see missile_reload_time.
		if locked:
			if reload_remaining <= 0.0:
				_fire_missile()
			else:
				_deny_launch()
		_reset_lock()

	_trigger_was_down = trigger_down


func _update_lock(delta: float) -> void:
	var candidate := _designate_target()

	if candidate < 0:
		_reset_lock()
		acquiring = true  # holding the trigger with nothing designated
		return

	if candidate != tracked_target_index:
		# Switched targets mid-hold — start over, no partial credit.
		tracked_target_index = candidate
		lock_progress = 0.0
		locked = false
		_beep_timer = 0.0

	acquiring = true

	if locked:
		return

	lock_progress = clampf(lock_progress + delta, 0.0, lock_time)
	if lock_progress >= lock_time:
		locked = true
		if _lock_audio:
			_lock_audio.play()  # the solid "tone" — lock acquired
		_pulse(0.9, 0.22)
		return

	_update_search_tone(delta)


## Pulses LockAudio at an interval that shortens as the lock builds, so the
## audio alone tells you how far along you are.
func _update_search_tone(delta: float) -> void:
	_beep_timer -= delta
	if _beep_timer > 0.0:
		return
	var t := lock_progress / maxf(lock_time, 0.001)
	_beep_timer = lerpf(beep_interval_start, beep_interval_end, t)
	if _lock_audio:
		_lock_audio.play()
	# Buzz the hand holding the trigger on every beep. Audio can be missed,
	# drowned out by the battle, or (as it was) routed wrong; a pulse in the
	# hand that's pressing the button cannot be.
	_pulse(0.35, 0.05)


func _pulse(amplitude: float, duration: float) -> void:
	if _left_controller and _left_controller.get_is_active():
		_left_controller.trigger_haptic_pulse("haptic", 0.0, amplitude, duration, 0.0)


## Y-locked target first (it's the deliberate pick, and it's what the
## targeting box/PIP ring are already drawn around), otherwise whatever is
## nearest inside the nose cone.
func _designate_target() -> int:
	if _target_lock and _target_lock.locked and _battle.is_alive(_target_lock.locked_index):
		return _target_lock.locked_index

	# Rig forward, NOT Ship forward — see the class comment.
	var from: Vector3 = _origin.global_position
	var forward: Vector3 = -_origin.global_transform.basis.z
	return _battle.get_nearest_alive_alien_in_cone(
			from, forward, deg_to_rad(lock_cone_degrees), lock_range)


func _reset_lock() -> void:
	lock_progress = 0.0
	locked = false
	acquiring = false
	tracked_target_index = -1
	_beep_timer = 0.0


## A completed lock was released while the weapon was still reloading — the
## shot is refused. A SHORT, WEAKER, DISTINCT pulse from both the search-tone
## buzz (0.35/0.05) and the launch pulse (1.0/0.3), so a denied shot reads as
## "not ready" rather than as the trigger silently doing nothing. This is the
## same lesson missile_system.gd's own lock design already learned the hard
## way, twice — a weapon with invisible feedback reads as broken, not busy.
func _deny_launch() -> void:
	_pulse(0.6, 0.08)


func _fire_missile() -> void:
	reload_remaining = missile_reload_time
	var missile := MISSILE.instantiate()
	# Target assigned before add_child(), since add_child() runs missile.gd's
	# _ready() immediately — see faction_battle.gd's header for the bug this
	# ordering rule came from.
	missile.target_index = tracked_target_index
	missile.battle = _battle
	get_tree().current_scene.add_child(missile)

	# Position from the launch mount, orientation from the rig — Ship's basis
	# is flipped 180 degrees and would fire the missile backwards.
	var spawn_pos: Vector3 = _launch_mount.global_position if _launch_mount else _origin.global_position
	missile.global_transform = Transform3D(_origin.global_transform.basis, spawn_pos)

	if _launch_audio:
		_launch_audio.play()
	_pulse(1.0, 0.3)


# ---------------------------------------------------------------------------
# Lock reticle — visor HUD, see the class comment above for the design
# ---------------------------------------------------------------------------

## Four short bracket ticks arranged in a ring, all children of one root
## whose OWN local Z is what gets spun for the "orbiting" look and whose
## transform is re-aimed at the camera every frame — the same
## rotate-as-one-rigid-unit approach target_lock.gd uses for its targeting
## box, and for the same reason: per-tick billboarding would rotate each
## tick independently around its own origin instead of spinning the whole
## ring as a unit.
func _build_reticle() -> void:
	_reticle = Node3D.new()
	_reticle.name = "MissileLockReticle"
	add_child(_reticle)

	_reticle_material = StandardMaterial3D.new()
	_reticle_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_reticle_material.no_depth_test = true
	_reticle_material.albedo_color = RETICLE_COLOR_ACQUIRING
	_reticle_material.emission_enabled = true
	_reticle_material.emission = RETICLE_COLOR_ACQUIRING
	_reticle_material.emission_energy_multiplier = 5.0

	var tick_length := RETICLE_RADIUS * 0.85
	var tick_thickness := RETICLE_RADIUS * 0.16
	for i in RETICLE_TICK_COUNT:
		var angle := TAU * float(i) / float(RETICLE_TICK_COUNT)
		var tick := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(tick_thickness, tick_length, tick_thickness)
		tick.mesh = box
		tick.material_override = _reticle_material
		tick.position = Vector3(cos(angle), sin(angle), 0.0) * RETICLE_RADIUS
		tick.rotation.z = angle
		_reticle.add_child(tick)

	_reticle.visible = false


func _process(delta: float) -> void:
	if not _reticle or not _camera or not _battle:
		return

	var tracking: bool = tracked_target_index >= 0 and _battle.is_alive(tracked_target_index)
	_reticle.visible = tracking
	if not tracking:
		_reticle_last_target = -1
		return

	# A newly designated target — first acquisition, or switching mid-hold —
	# restarts the fly-in animation and the spin, so every fresh lock
	# attempt gets the same "swoop in and start spinning" entrance.
	if tracked_target_index != _reticle_last_target:
		_reticle_last_target = tracked_target_index
		_reticle_fly_in_t = 0.0
		_reticle_spin_angle = 0.0
		var true_dir: Vector3 = (_battle.get_alien_position(tracked_target_index) - _camera.global_position).normalized()
		# Rotates the true direction off-axis by RETICLE_FLY_IN_ANGLE around a
		# random perpendicular, so the entrance swoops in from a different
		# side every time rather than always the same corner.
		_reticle_start_dir = true_dir.rotated(_random_perpendicular(true_dir), RETICLE_FLY_IN_ANGLE)

	var cam_pos: Vector3 = _camera.global_position
	var cam_basis: Basis = _camera.global_transform.basis
	var true_dir: Vector3 = (_battle.get_alien_position(tracked_target_index) - cam_pos).normalized()

	var current_dir: Vector3 = true_dir
	if _reticle_fly_in_t < 1.0:
		_reticle_fly_in_t = clampf(_reticle_fly_in_t + delta / RETICLE_FLY_IN_TIME, 0.0, 1.0)
		var eased := 1.0 - (1.0 - _reticle_fly_in_t) * (1.0 - _reticle_fly_in_t)  # ease-out — fast start, gentle settle onto the target
		current_dir = _reticle_start_dir.slerp(true_dir, eased)

	var t := clampf(lock_progress / maxf(lock_time, 0.001), 0.0, 1.0)
	var spin_speed := lerpf(RETICLE_SPIN_SPEED_START, RETICLE_SPIN_SPEED_LOCKED, t)
	_reticle_spin_angle += spin_speed * delta

	_reticle.global_position = cam_pos + current_dir * RETICLE_HUD_DISTANCE
	_reticle.global_transform.basis = cam_basis * Basis(Vector3.FORWARD, _reticle_spin_angle)

	var color := RETICLE_COLOR_ACQUIRING.lerp(RETICLE_COLOR_LOCKED, t)
	var energy := 5.0
	if locked:
		# A small breathing pulse once locked — "ready", not just "not red
		# anymore" — purely cosmetic, doesn't affect any gameplay timing.
		_reticle_pulse_time += delta
		energy = 5.0 + sin(_reticle_pulse_time * RETICLE_PULSE_SPEED) * 1.5
	_reticle_material.albedo_color = color
	_reticle_material.emission = color
	_reticle_material.emission_energy_multiplier = energy


## A unit vector perpendicular to `dir`, picked pseudo-randomly per call so
## the fly-in entrance doesn't always swoop in from the same side.
func _random_perpendicular(dir: Vector3) -> Vector3:
	var arbitrary := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.9 else Vector3.RIGHT
	return dir.cross(arbitrary).rotated(dir, randf() * TAU).normalized()
