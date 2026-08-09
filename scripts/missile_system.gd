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

const MISSILE := preload("res://scenes/Missile.tscn")

## Down from the previous design's 5s. Five seconds of holding still on a
## manoeuvring target is a long time in a dogfight; 3 is enough to make the
## missile a committed shot rather than a spammable one without being
## tedious. Exported so it's tunable in the headset without a code change.
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


func _physics_process(delta: float) -> void:
	if paused:
		_reset_lock()
		return
	if not _left_controller or not _left_controller.get_is_active():
		return
	if not _origin or not _battle:
		return

	var trigger_down := _left_controller.is_button_pressed("trigger_click")

	if trigger_down:
		_update_lock(delta)
	elif _trigger_was_down:
		# Release is the trigger to launch — a completed lock fires, an
		# incomplete one is simply discarded.
		if locked:
			_fire_missile()
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


func _fire_missile() -> void:
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
