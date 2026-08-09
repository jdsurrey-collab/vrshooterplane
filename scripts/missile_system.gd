extends Node

## Homing missile weapon — left trigger. Requires target_lock.gd's Y-button
## lock to already be active on a target first — this script no longer
## does its own independent aim-cone detection (an earlier version tracked
## the ship's gun crosshair directly; replaced per direct request so
## missile lock only ever happens against a deliberately Y-locked target,
## not just "whatever's under the crosshair"). While a Y-lock is held on
## the same target continuously for LOCK_TIME (5s), progress builds;
## losing it — Y-lock drops, or target_lock.gd cycles to a different
## target (see its header), or the target dies — resets progress to zero,
## no partial credit. A beep (LockAudio) plays once when lock completes.
## Firing only works while locked and consumes the lock, so every shot
## needs a fresh 5-second track — deliberately a slower, more committed
## weapon than the guns, not a second trigger-happy option.

const MISSILE := preload("res://scenes/Missile.tscn")
const LOCK_TIME := 5.0

@export var target_lock_path: NodePath = ^"../TargetLock"
@export var launch_mount_path: NodePath = ^"../Ship/GunMountRight"

## Set by the options menu / game_flow.gd while paused, so config/menu
## states can't trigger a launch — same convention weapon_system.gd uses.
var paused: bool = false

## Live status, readable by a future HUD readout if wanted.
var lock_progress: float = 0.0
var locked: bool = false

var _left_controller: XRController3D
var _ship: Node3D
var _launch_mount: Node3D
var _battle: Node
var _target_lock: Node
var _lock_audio: AudioStreamPlayer3D
var _launch_audio: AudioStreamPlayer3D

var _tracked_target_index: int = -1
var _trigger_was_down: bool = false


func _ready() -> void:
	var origin := get_parent()
	_left_controller = origin.get_node_or_null("LeftHand")
	_ship = origin.get_node_or_null("Ship")
	_launch_mount = get_node_or_null(launch_mount_path)
	_battle = get_tree().current_scene.get_node_or_null("FactionBattle")
	_target_lock = get_node_or_null(target_lock_path)
	_lock_audio = get_node_or_null("LockAudio")
	_launch_audio = get_node_or_null("LaunchAudio")


func _physics_process(delta: float) -> void:
	if paused:
		return
	if not _left_controller or not _left_controller.get_is_active():
		return
	if not _ship or not _battle or not _target_lock:
		return

	_update_lock(delta)

	var trigger_down := _left_controller.is_button_pressed("trigger_click")
	if trigger_down and not _trigger_was_down and locked:
		_fire_missile()
	_trigger_was_down = trigger_down


func _update_lock(delta: float) -> void:
	var candidate := -1
	if _target_lock.locked and _battle.is_alive(_target_lock.locked_index):
		candidate = _target_lock.locked_index

	if candidate < 0 or candidate != _tracked_target_index:
		lock_progress = 0.0
		locked = false
		_tracked_target_index = candidate
		if candidate < 0:
			return

	lock_progress = clampf(lock_progress + delta, 0.0, LOCK_TIME)
	if lock_progress >= LOCK_TIME and not locked:
		locked = true
		if _lock_audio:
			_lock_audio.play()


func _fire_missile() -> void:
	var missile := MISSILE.instantiate()
	get_tree().current_scene.add_child(missile)
	var spawn_pos: Vector3 = _launch_mount.global_position if _launch_mount else _ship.global_position
	missile.global_transform = Transform3D(_ship.global_transform.basis, spawn_pos)
	missile.target_index = _tracked_target_index
	missile.battle = _battle

	if _launch_audio:
		_launch_audio.play()

	lock_progress = 0.0
	locked = false
	_tracked_target_index = -1
