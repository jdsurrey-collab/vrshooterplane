extends Node

## Target lock-on: the left controller's Y button ("by_button" — free to
## use, nothing else on this project binds it) CYCLES a lock through living
## aliens from faction_battle.gd's 200-ship roster, nearest-to-farthest,
## wrapping back to nearest after the last one (the old single hardcoded
## HOSTILE-1 enemy is retired) — first press locks nearest, each press
## after that steps to the next one out. There's no manual unlock; it only
## drops automatically (target dies, or drifts past max_lock_range).
## Because this only ever queries the alien-faction array, friendlies are
## structurally impossible to lock onto — not an explicit exclusion check,
## just a consequence of the two factions being separate arrays in the
## manager. `missile_system.gd`'s homing lock now requires this Y-lock to
## already be active on a target before it'll even start building its own
## 5-second track — see that script. While locked:
## - A red targeting square, an info readout (name, distance, closing/
##   opening speed), and a yellow PIP ring (see below) are all shown.
## - Closing/opening speed is the rate of change of the actual distance
##   between the two ships — not the enemy's raw speed — so it already
##   accounts for the player's own motion, no separate relative-velocity
##   bookkeeping needed.
## - The PIP ("predicted impact point") ring shows exactly where to put the
##   crosshair to hit a moving target — the lead-computing gunsight
##   documented as future work in docs/gunnery-reference.md, now built.
## - Auto-unlocks if the target drifts past `max_lock_range` (12km for now).
##
## VISOR-ANCHORED HUD, not true 3D world objects: the box/pip/label are each
## placed at a FIXED distance from the camera (`hud_distance`), along the
## real direction to the target (or, for the PIP, the real direction to the
## computed intercept point) — so they correctly point at the right place
## and track relative to your view, but their apparent size never changes
## with actual distance to target, and they stay legible at any range. This
## replaced an earlier version that placed the box at the target's true
## position/orientation/distance, which shrank to unreadable at range.
##
## The targeting box is a flat square (4 edges, not a 3D cube) because it's
## always camera-facing now — a full wireframe cube's depth edges would
## never be visible face-on anyway. It's rotated as ONE RIGID UNIT to match
## the camera's basis each frame — NOT via per-edge `billboard_mode` on the
## material, which would rotate each of the 4 edges independently around
## its own origin and distort the square. The PIP ring and info label are
## single mesh instances, so ordinary billboard_mode works fine for them.
##
## PIP MATH — a real firing-solution intercept, not a visual approximation:
## given the target's current position/velocity (faction_battle.gd's
## get_velocity(), exact since that AI is purely kinematic) and the bolt's
## fixed speed, solves the quadratic for the smallest positive time t where
## a bolt fired now would meet the target's projected position:
##   |target_pos + target_vel*t - shooter_pos| = bolt_speed * t
## See _solve_intercept(). Falls back to the target's current position if
## there's no valid positive-time solution (e.g. it's outrunning the bolt).

@export var battle_path: NodePath = ^"../../FactionBattle"
@export var gun_left_path: NodePath = ^"../Ship/GunMountLeft"
@export var gun_right_path: NodePath = ^"../Ship/GunMountRight"
@export var bolt_speed: float = 600.0  # must match laser_bolt.gd's `speed` — both were lowered from 900 so bolts are actually visible in flight
@export var max_lock_range: float = 12000.0  # meters — auto-unlocks past this

@export_group("Visor HUD")
@export var hud_distance: float = 5.0  # meters from camera — fixed, so apparent size never changes
@export var box_size: float = 0.06  # meters, at hud_distance (half again, was 0.12)
@export var label_offset: float = 0.09  # meters below the box, in view-space (widened — text was overlapping the target)

const EDGE_THICKNESS := 0.00125
const BOX_EDGES := [[0, 1], [1, 2], [2, 3], [3, 0]]

var _player: Node3D
var _camera: Node3D
var _battle: Node
var _left_controller: XRController3D
var _targeting_box: Node3D
var _pip_ring: MeshInstance3D
var _info_label: Label3D

var locked: bool = false
var locked_index: int = -1
var _lock_button_was_down: bool = false
var _previous_distance: float = -1.0


func _ready() -> void:
	_player = get_parent()
	_camera = _player.get_node_or_null("XRCamera3D")
	_battle = get_node_or_null(battle_path)
	_left_controller = _player.get_node_or_null("LeftHand")

	_targeting_box = _build_targeting_box()
	_pip_ring = _build_pip_ring()
	_info_label = _build_info_label()

	_targeting_box.visible = false
	_pip_ring.visible = false
	_info_label.visible = false


func _process(delta: float) -> void:
	if not _left_controller or not _left_controller.get_is_active():
		return

	var lock_button_down := _left_controller.is_button_pressed("by_button")
	if lock_button_down and not _lock_button_was_down:
		_toggle_lock()
	_lock_button_was_down = lock_button_down

	if not locked or not _battle or not _camera:
		return
	if not _battle.is_alive(locked_index):
		_set_locked(false)
		return

	_update_lock_display(delta)


## Y no longer toggles lock off — it CYCLES through living aliens,
## nearest-to-farthest, wrapping back to nearest after the last one.
## Unlocking still happens automatically (target dies or drifts past
## max_lock_range, see _update_lock_display()), just not via Y itself.
func _toggle_lock() -> void:
	if not _battle:
		return
	var sorted: Array = _battle.get_alive_aliens_sorted_by_distance(_player.global_position)
	if sorted.is_empty():
		_set_locked(false)
		return

	if not locked:
		locked_index = sorted[0]
		_set_locked(true)
		return

	var pos: int = sorted.find(locked_index)
	var next_pos: int = (pos + 1) % sorted.size() if pos >= 0 else 0
	locked_index = sorted[next_pos]
	_previous_distance = -1.0


func _set_locked(value: bool) -> void:
	locked = value
	_targeting_box.visible = locked
	_pip_ring.visible = locked
	_info_label.visible = locked
	_previous_distance = -1.0


func _update_lock_display(delta: float) -> void:
	var target_pos: Vector3 = _battle.get_alien_position(locked_index)
	var distance := _player.global_position.distance_to(target_pos)
	if distance > max_lock_range:
		_set_locked(false)
		return

	var cam_pos := _camera.global_position
	var cam_basis := _camera.global_transform.basis

	var target_dir := (target_pos - cam_pos).normalized()
	var box_pos := cam_pos + target_dir * hud_distance

	_targeting_box.global_position = box_pos
	_targeting_box.global_transform.basis = cam_basis  # rigid unit, faces camera exactly

	var rate := 0.0
	if _previous_distance >= 0.0 and delta > 0.0:
		rate = (_previous_distance - distance) / delta
	_previous_distance = distance

	var rate_text := "HOLDING"
	if rate > 0.5:
		rate_text = "CLOSING %d m/s" % roundi(rate)
	elif rate < -0.5:
		rate_text = "OPENING %d m/s" % roundi(-rate)

	var target_name := "HOSTILE-%03d" % locked_index
	_info_label.text = "%s\n%d m\n%s" % [target_name, roundi(distance), rate_text]
	# Below the box in VIEW-space (camera's own local down), not world down —
	# stays correctly positioned relative to the box regardless of head tilt.
	_info_label.global_position = box_pos - cam_basis.y * label_offset

	_update_pip(cam_pos, target_pos)


func _update_pip(cam_pos: Vector3, target_pos: Vector3) -> void:
	var gun_left := get_node_or_null(gun_left_path)
	var gun_right := get_node_or_null(gun_right_path)
	var shooter_pos: Vector3 = _player.global_position
	if gun_left and gun_right:
		shooter_pos = (gun_left.global_position + gun_right.global_position) * 0.5

	var target_vel: Vector3 = _battle.get_velocity(locked_index)
	var intercept := _solve_intercept(shooter_pos, target_pos, target_vel, bolt_speed)

	var pip_dir := (intercept - cam_pos).normalized()
	_pip_ring.global_position = cam_pos + pip_dir * hud_distance


## Solves a*t^2 + b*t + c = 0 for the smallest positive t, derived from
## |rel_pos + target_vel*t| = bullet_speed*t. Returns the target's current
## position if there's no valid positive-time solution.
func _solve_intercept(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, bullet_speed: float) -> Vector3:
	var rel_pos := target_pos - shooter_pos
	var a := target_vel.dot(target_vel) - bullet_speed * bullet_speed
	var b := 2.0 * rel_pos.dot(target_vel)
	var c := rel_pos.dot(rel_pos)

	var t := -1.0
	if absf(a) < 0.0001:
		if absf(b) > 0.0001:
			t = -c / b
	else:
		var discriminant := b * b - 4.0 * a * c
		if discriminant >= 0.0:
			var sqrt_d := sqrt(discriminant)
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


## A flat square (local XY plane, Z=0) — the whole node's rotation is set
## to match the camera each frame (see _update_lock_display), so this
## renders as a face-on bracket always, never a 12-edge cube.
func _build_targeting_box() -> Node3D:
	var box := Node3D.new()
	box.name = "TargetingBox"
	add_child(box)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.2, 0.15, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.2, 0.15, 1.0)
	mat.emission_energy_multiplier = 4.0

	var h := box_size * 0.5
	var corners := [
		Vector3(-h, -h, 0.0), Vector3(h, -h, 0.0),
		Vector3(h, h, 0.0), Vector3(-h, h, 0.0),
	]

	for edge in BOX_EDGES:
		var a: Vector3 = corners[edge[0]]
		var b: Vector3 = corners[edge[1]]
		var mid := (a + b) * 0.5
		var length := a.distance_to(b)
		var direction := (b - a).normalized()

		var mesh_instance := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size = Vector3(EDGE_THICKNESS, EDGE_THICKNESS, length)
		mesh_instance.mesh = box_mesh
		mesh_instance.material_override = mat
		box.add_child(mesh_instance)
		mesh_instance.position = mid

		var up_ref := Vector3.FORWARD if absf(direction.dot(Vector3.UP)) > 0.99 else Vector3.UP
		mesh_instance.basis = Basis.looking_at(direction, up_ref)

	return box


func _build_pip_ring() -> MeshInstance3D:
	var ring := MeshInstance3D.new()
	ring.name = "PipRing"
	add_child(ring)

	var torus := TorusMesh.new()
	torus.inner_radius = 0.0125  # half again, was 0.025
	torus.outer_radius = 0.0225  # half again, was 0.045

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mat.albedo_color = Color(1.0, 0.9, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.9, 0.1, 1.0)
	mat.emission_energy_multiplier = 5.0
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED

	ring.mesh = torus
	ring.material_override = mat
	return ring


func _build_info_label() -> Label3D:
	var label := Label3D.new()
	label.name = "InfoLabel"
	add_child(label)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	# Anchored from the TOP of the text block, not its center — so the
	# multi-line block only ever grows downward, away from the box, instead
	# of its center staying at label_offset while the top creeps back up
	# toward (and over) the target as line count/length changes.
	label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	label.font_size = 32
	label.pixel_size = 0.00125  # half again, was 0.0025
	label.outline_size = 12
	label.modulate = Color(1.0, 0.3, 0.2, 1.0)
	return label
