extends Node

## "You are being hit" feedback — the missing half of the damage system.
## player_damage.gd already tracked three health pools and played a hit
## sound, but nothing about taking fire was *felt*, so combat read as
## ambient noise rather than danger.
##
## Three layers, called together from player_damage.gd's apply_damage():
##
## 1. SHAKE. Translational only, never rotational. Rotating a VR camera the
##    player didn't rotate is the classic way to make people sick;
##    translating it briefly is comparatively benign and still reads as a
##    hard impact. The offset is applied to the XROrigin3D (the whole rig)
##    because XRCamera3D's own transform is overwritten every frame by the
##    XR tracker and cannot be offset directly.
##
##    DRIFT SAFETY: flight_controller.gd moves the same node every physics
##    frame (`_origin.global_position += velocity * delta`). So this script
##    never *sets* a position — each frame it subtracts the offset it
##    applied last frame and adds the new one, leaving flight's own motion
##    completely intact and guaranteeing the shake can't accumulate into a
##    permanent positional drift.
##
## 2. FLASH. A red translucent quad parented to the camera, alpha decaying
##    from the hit. Built in code (like target_lock.gd's HUD elements) so
##    Player.tscn doesn't need another hand-maintained node. It sits nearer
##    the camera than the HUD labels so it tints them too — deliberate; a
##    damage flash that the HUD punches through reads as a UI bug.
##    It stays *behind* main_menu.gd's Fade quad, which owns
##    render_priority -1 and z=-0.15 (the player is paused in menus anyway).
##
## 3. HAPTICS. A short pulse on both controllers. In VR this is by far the
##    most unambiguous "that hit you" signal available and costs nothing.
##
## Everything scales with the damage amount, normalised against
## SCALE_REFERENCE_DAMAGE (a single laser bolt), so a missile hit lands
## much harder than routine chip damage.

const SHAKE_DURATION := 0.45
const SHAKE_FREQUENCY := 34.0
const FLASH_DURATION := 0.7
const SCALE_REFERENCE_DAMAGE := 10.0  # one laser_bolt.gd hit
const MAX_INTENSITY := 2.5

@export var shake_amplitude: float = 0.11  # meters at intensity 1.0 — keep modest, this is VR
@export var flash_peak_alpha: float = 0.5
@export var haptic_duration: float = 0.12

var _origin: Node3D
var _camera: Node3D
var _left_controller: XRController3D
var _right_controller: XRController3D
var _flash: MeshInstance3D
var _flash_material: StandardMaterial3D

var _shake_time: float = 0.0
var _shake_intensity: float = 0.0
var _applied_offset: Vector3 = Vector3.ZERO

var _flash_time: float = 0.0
var _flash_intensity: float = 0.0

var _noise_seed: float = 0.0


func _ready() -> void:
	_origin = get_parent()
	_camera = _origin.get_node_or_null("XRCamera3D")
	_left_controller = _origin.get_node_or_null("LeftHand")
	_right_controller = _origin.get_node_or_null("RightHand")
	_noise_seed = randf() * 100.0
	_build_flash()


func _build_flash() -> void:
	if not _camera:
		return
	_flash = MeshInstance3D.new()
	_flash.name = "DamageFlash"

	var quad := QuadMesh.new()
	quad.size = Vector2(1.4, 1.4)
	_flash.mesh = quad

	_flash_material = StandardMaterial3D.new()
	_flash_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash_material.no_depth_test = true
	_flash_material.albedo_color = Color(0.75, 0.03, 0.03, 0.0)
	_flash.material_override = _flash_material

	_camera.add_child(_flash)
	_flash.position = Vector3(0.0, 0.0, -0.3)
	_flash.visible = false


## Called by player_damage.gd on every hit that lands on the player.
func play_hit(amount: float) -> void:
	var intensity := clampf(amount / SCALE_REFERENCE_DAMAGE, 0.35, MAX_INTENSITY)

	# Take the stronger of the incoming hit and whatever is still playing,
	# rather than restarting flat — back-to-back chip damage shouldn't cancel
	# out a big hit that's mid-shake.
	_shake_intensity = maxf(_shake_intensity, intensity)
	_shake_time = SHAKE_DURATION
	_flash_intensity = maxf(_flash_intensity, intensity)
	_flash_time = FLASH_DURATION

	_pulse(_left_controller, intensity)
	_pulse(_right_controller, intensity)


func _pulse(controller: XRController3D, intensity: float) -> void:
	if not controller or not controller.get_is_active():
		return
	controller.trigger_haptic_pulse(
			"haptic", 0.0, clampf(intensity * 0.6, 0.2, 1.0), haptic_duration, 0.0)


func _process(delta: float) -> void:
	_update_shake(delta)
	_update_flash(delta)


func _update_shake(delta: float) -> void:
	if not _origin:
		return

	# Always undo last frame's offset first, so flight_controller.gd's own
	# translation of this same node is never disturbed and the shake can't
	# integrate into a drift.
	if _applied_offset != Vector3.ZERO:
		_origin.global_position -= _applied_offset
		_applied_offset = Vector3.ZERO

	if _shake_time <= 0.0:
		_shake_intensity = 0.0
		return

	_shake_time -= delta
	var falloff := clampf(_shake_time / SHAKE_DURATION, 0.0, 1.0)
	var magnitude := shake_amplitude * _shake_intensity * falloff * falloff

	var t := (Time.get_ticks_msec() / 1000.0) * SHAKE_FREQUENCY + _noise_seed
	var offset := Vector3(sin(t * 1.7), sin(t * 2.3 + 1.1), sin(t * 1.3 + 2.7)) * magnitude

	# Shake along the ship's own axes so it reads as the airframe being
	# struck rather than the world sliding around.
	_applied_offset = _origin.global_transform.basis * offset
	_origin.global_position += _applied_offset


func _update_flash(delta: float) -> void:
	if not _flash_material:
		return
	if _flash_time <= 0.0:
		if _flash.visible:
			_flash.visible = false
		return

	_flash_time -= delta
	var falloff := clampf(_flash_time / FLASH_DURATION, 0.0, 1.0)
	_flash.visible = true
	_flash_material.albedo_color.a = flash_peak_alpha * _flash_intensity * falloff * falloff
	if _flash_time <= 0.0:
		_flash_intensity = 0.0
