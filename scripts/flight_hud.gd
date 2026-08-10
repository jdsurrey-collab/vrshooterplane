extends Node3D

## The ship's own glass-projected flight display — "a holographic image on
## the glass of the ship itself above the dashboard," distinct from the
## HELMET-anchored HUD (hud.gd/kill_feed_hud.gd/battle_hud.gd/
## player_health_hud.gd, all children of XRCamera3D). Everything here is a
## child of `Ship` instead, reusing the exact parenting convention
## weapon_system.gd's Crosshair already established: fixed in the ship's
## own 3D space, not the camera's, so it shows real parallax as the player
## moves their head — "like a reticle etched on the glass, not a HUD
## marker" — rather than staying centered on your view like the helmet HUD
## does. Built programmatically in _ready(), the same convention
## target_lock.gd and missile_system.gd's lock reticle use for HUD
## geometry, for the same reason: easier to tune from exported values than
## hand-authored scene sub-resources.
##
## SCOPE: only genuinely flight-dynamics telemetry lives here — speed,
## altitude, heading, thrust input, and the flight-path (velocity vector)
## marker. Kill feed and the Air Superiority/timer readout were explicitly
## kept on the helmet per direct instruction; hud.gd's FPS/PERF/GUN/MSL/CITY
## lines (debug info and weapon/objective status, not flight dynamics) stay
## there too.
##
## `hud_center` IS A FIRST-PASS PLACEHOLDER, unverified in the headset —
## seeded near GunMountLeft/GunMountRight's own established position
## (z=0.9, the same "in front of the pilot" depth those mounts already use;
## y raised above their 1.9 after live feedback that the first pass sat too
## low in view), but this cockpit's actual dashboard/glass geometry has
## never been measured, so — like ShipHull's placement and every other
## cockpit-relative placement in this project — it will likely still need
## live-in-VR correction.
##
## EVERYTHING HERE IS no_depth_test = true, deliberately, unlike the
## original far-away Crosshair sphere (which never needed it — 229m out is
## past any physical cockpit geometry regardless of depth testing). These
## elements sit close in front of the pilot instead, at roughly the same
## depth as the cockpit's own dashboard model, so ordinary depth testing let
## the dashboard mesh occlude them outright — reported live as "the
## elevation track and thrust are not visible anywhere." A real HUD
## combiner reflects light off glass in front of everything in the cockpit,
## so always-on-top is the physically correct behavior here, not a hack.
##
## LOCAL-SPACE CONVENTION: +Z is forward in Ship's local space (NOT
## Godot's usual -Z), because Ship carries a 180-degree flip basis to
## correct its glTF's backwards-authored forward direction (see
## Player.tscn / weapon_system.gd's own convergence-point math, which
## already uses +Z the same way). Every offset below follows that.
##
## LABELS NEED THEIR OWN 180-DEGREE Y ROTATION, separately from the above.
## A non-billboarded Label3D's readable front face points along its own
## local +Z by default. The pilot sits at a lower Z than hud_center looking
## toward +Z (the same direction the label itself faces, un-rotated) — so
## without correction the pilot only ever sees the BACK of the text, which
## renders mirrored. Reported live as "all the text is backwards." Rotating
## each label 180 degrees about Y (in _build_label()) turns its front face
## back toward the pilot — a real rotation, not a mirror, so the text reads
## correctly rather than just flipping which side looks wrong.

@export var flight_controller_path: NodePath = ^"../../FlightController"

@export_group("Placement (first-pass, needs live-VR correction)")
## NOT locked to the crosshair's Y coordinate — that was tried and was
## wrong. The crosshair sits 229m out and this cluster sits 0.9m out;
## matching raw local-Y values does NOT make two objects at such different
## depths appear vertically aligned on screen, because apparent angle
## depends on distance too (the same Y offset from the camera's real eye
## height subtends a far bigger angle up close than it does 229m away,
## which is exactly why the crosshair barely moves on screen across a wide
## range of Y values while the ladder is extremely sensitive to it).
## Direct visual tuning against live feedback is the only thing that
## actually works here — 1.9 (matched to the crosshair) put the ladder
## "into the dashboard"; 2.9 was "almost perfect, just needed to go down a
## couple inches" — so this settled on 2.8.
@export var hud_center: Vector3 = Vector3(0.0, 2.8, 0.9)
@export var element_scale: float = 0.5  # halved after live feedback that the whole cluster read as "way too big"

@export_group("Flight path marker")
@export var marker_distance: float = 1.6  # how far in front of hud_center, along the real velocity direction
@export var marker_min_speed: float = 2.0  # below this, direction is noisy/meaningless — hide instead of jittering
## Sized against how CLOSE this marker sits (only ~1.6m out) compared to the
## crosshair it shares the view with (229m out) — the same radius reads as
## a fine reticle far away but a huge ring up close. Reported live as "way
## too big... needs to be about ten percent of the size it currently is."
@export var marker_inner_radius: float = 0.009
@export var marker_outer_radius: float = 0.012

@export_group("Altitude ladder")
@export var ladder_half_span: float = 0.22  # local meters the tick can travel up/down from center
@export var altitude_range: float = 3000.0  # +/- meters mapped across ladder_half_span, clamped past that
## Horizontal offset of each bar from center — widened 50% (0.16 -> 0.24)
## after live feedback to open up clearance around the crosshair sitting
## between them.
@export var ladder_x_offset: float = 0.24

@export_group("Thrust gauge")
@export var gauge_height: float = 0.3

const NEON_CYAN := Color(0.0, 2.4, 2.6)  # pushed above 1.0 so the Environment's Glow pass actually blooms it
const NEON_AMBER := Color(2.6, 1.4, 0.0)
## Plain white, not tinted — the flight path marker's own color, per direct
## request. Real HUDs use a neutral velocity-vector symbol precisely so it
## reads as "true direction of travel" rather than being mistaken for
## another faction-tinted or weapon-status color.
const MARKER_WHITE := Color(2.2, 2.2, 2.2)

var _ship: Node3D
var _flight_controller: Node

var _speed_label: Label3D
var _heading_label: Label3D
var _altitude_label: Label3D
var _altitude_tick: MeshInstance3D
var _thrust_fill: MeshInstance3D
var _flight_path_marker: Node3D
var _font: Font


func _ready() -> void:
	_ship = get_parent()
	_flight_controller = get_node_or_null(flight_controller_path)
	_font = load("res://Assets/Fonts/Orbitron-Variable.ttf") as Font

	_build_altitude_ladder()
	_build_thrust_gauge()
	_flight_path_marker = _build_ring("FlightPathMarker", marker_inner_radius, marker_outer_radius, MARKER_WHITE)
	_speed_label = _build_label("SpeedLabel", hud_center + Vector3(-0.30, 0.16, 0.0) * element_scale, HORIZONTAL_ALIGNMENT_LEFT)
	_heading_label = _build_label("HeadingLabel", hud_center + Vector3(0.0, 0.24, 0.0) * element_scale, HORIZONTAL_ALIGNMENT_CENTER)


func _process(_delta: float) -> void:
	if not _flight_controller or not _ship:
		return

	if _speed_label:
		_speed_label.text = "SPD %d M/S" % roundi(_flight_controller.get_speed())

	if _heading_label:
		# NOT basis.get_euler() — Ship carries a baked-in 180-degree flip
		# basis (see this file's header), which would corrupt an
		# Euler-angle decomposition. Reading local +Z's actual WORLD
		# direction instead sidesteps that entirely: it's asking "where
		# does the ship's real forward point," not decomposing a rotation
		# that already has an unrelated correction folded into it.
		var world_forward: Vector3 = _ship.global_transform.basis * Vector3(0.0, 0.0, 1.0)
		var yaw_deg := fposmod(rad_to_deg(atan2(world_forward.x, -world_forward.z)), 360.0)
		_heading_label.text = "HDG %03d" % roundi(yaw_deg)

	var altitude: float = _ship.global_position.y
	if _altitude_label:
		_altitude_label.text = "ALT %d M" % roundi(altitude)
	if _altitude_tick:
		var frac: float = clampf(altitude / altitude_range, -1.0, 1.0)
		_altitude_tick.position.y = hud_center.y + frac * ladder_half_span * element_scale

	if _thrust_fill:
		var thrust: float = clampf(absf(_flight_controller.right_grip_value - _flight_controller.left_grip_value), 0.0, 1.0)
		var h: float = maxf(gauge_height * element_scale * thrust, 0.001)
		_thrust_fill.scale.y = h
		_thrust_fill.position.y = (hud_center.y - gauge_height * element_scale * 0.5) + h * 0.5

	_update_flight_path_marker()


## Positions the flight path marker along the REAL velocity direction, at a
## fixed apparent distance from hud_center — same "fixed distance along a
## real direction" technique target_lock.gd's PIP ring uses, just anchored
## to the ship's own local frame instead of the camera's, since this marker
## needs to sit fixed on the glass rather than track the player's view.
func _update_flight_path_marker() -> void:
	var world_vel: Vector3 = _flight_controller.get_velocity()
	if world_vel.length() < marker_min_speed:
		_flight_path_marker.visible = false
		return

	var local_dir: Vector3 = (_ship.global_transform.basis.inverse() * world_vel).normalized()
	_flight_path_marker.visible = true
	_flight_path_marker.position = hud_center + local_dir * marker_distance * element_scale
	# No manual look_at() here — the ring's OWN material is billboarded (see
	# _build_ring()), which is what a single-mesh ring should use instead of
	# a hand-computed facing basis: guaranteed correct from any viewing
	# angle, and it's the exact technique target_lock.gd's PIP ring already
	# uses for the identical shape. A wrong hand-rotated guess is exactly
	# what made the gun crosshair invisible (edge-on) before this fix.


func _build_altitude_ladder() -> void:
	var left := _build_line("LadderLeft", hud_center + Vector3(-ladder_x_offset, 0.0, 0.0) * element_scale, ladder_half_span * 2.0, NEON_CYAN)
	var right := _build_line("LadderRight", hud_center + Vector3(ladder_x_offset, 0.0, 0.0) * element_scale, ladder_half_span * 2.0, NEON_CYAN)
	add_child(left)
	add_child(right)

	_altitude_tick = MeshInstance3D.new()
	_altitude_tick.name = "AltitudeTick"
	var tick_mesh := BoxMesh.new()
	tick_mesh.size = Vector3(0.11, 0.014, 0.006) * element_scale
	_altitude_tick.mesh = tick_mesh
	_altitude_tick.material_override = _neon_material(NEON_CYAN)
	_altitude_tick.position = hud_center
	add_child(_altitude_tick)

	_altitude_label = _build_label("AltitudeLabel", hud_center + Vector3(-0.30, -0.05, 0.0) * element_scale, HORIZONTAL_ALIGNMENT_LEFT)


func _build_thrust_gauge() -> void:
	var track := MeshInstance3D.new()
	track.name = "ThrustTrack"
	var track_mesh := BoxMesh.new()
	track_mesh.size = Vector3(0.03, gauge_height, 0.006) * element_scale
	track.mesh = track_mesh
	var track_mat := _neon_material(NEON_AMBER)
	track_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA  # alpha alone does nothing without this
	track_mat.albedo_color.a = 0.25
	track_mat.emission_energy_multiplier = 0.6
	track.material_override = track_mat
	track.position = hud_center + Vector3(0.30, 0.0, 0.0) * element_scale
	add_child(track)

	_thrust_fill = MeshInstance3D.new()
	_thrust_fill.name = "ThrustFill"
	var fill_mesh := BoxMesh.new()
	fill_mesh.size = Vector3(0.026, 1.0, 0.007) * element_scale  # Y scaled per-frame, not baked into the mesh
	_thrust_fill.mesh = fill_mesh
	_thrust_fill.material_override = _neon_material(NEON_AMBER)
	_thrust_fill.position = hud_center + Vector3(0.30, -gauge_height * 0.5, 0.0) * element_scale
	_thrust_fill.scale.y = 0.001
	add_child(_thrust_fill)


func _build_line(node_name: String, local_pos: Vector3, length: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.006, length, 0.006) * element_scale
	mi.mesh = mesh
	mi.material_override = _neon_material(color)
	mi.position = local_pos
	return mi


func _build_ring(node_name: String, inner_radius: float, outer_radius: float, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var torus := TorusMesh.new()
	torus.inner_radius = inner_radius * element_scale
	torus.outer_radius = outer_radius * element_scale
	mi.mesh = torus
	# A static rotation, NOT billboard_mode. Billboarding rotates a mesh's
	# local Z axis to face the camera — correct for a flat quad/sprite, but
	# a TorusMesh lies flat with its hole/normal along local Y, not Z, so
	# billboarding one does nothing useful (it "always faces the camera"
	# along the wrong axis, which reads as the ring lying flat/edge-on no
	# matter which way the camera turns). Reported live: "the crosshair
	# right now is laying flat, it needs to be flipped ninety degrees up."
	# Rotating +90 degrees about X maps the mesh's own Y axis onto Z, so its
	# normal faces the same direction the pilot is looking — same fix
	# applied to weapon_system.gd's Crosshair in Player.tscn.
	mi.rotation.x = PI * 0.5
	mi.material_override = _neon_material(color)
	add_child(mi)
	return mi


func _build_label(node_name: String, local_pos: Vector3, alignment: HorizontalAlignment) -> Label3D:
	var label := Label3D.new()
	label.name = node_name
	label.position = local_pos
	label.rotation.y = PI  # see this file's header — un-rotated text faces away from the pilot and reads backwards
	label.pixel_size = 0.0011 * element_scale
	label.font_size = 30
	label.horizontal_alignment = alignment
	label.modulate = NEON_CYAN
	label.outline_size = 10
	label.outline_modulate = Color(0.0, 0.05, 0.05, 1.0)
	label.no_depth_test = true  # see this file's header — close-in HUD elements must not be occluded by cockpit geometry
	if _font:
		label.font = _font
	add_child(label)
	return label


func _neon_material(color: Color, billboard: bool = false) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true  # see this file's header — close-in HUD elements must not be occluded by cockpit geometry
	mat.albedo_color = Color(color.r, color.g, color.b, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(color.r, color.g, color.b, 1.0)
	mat.emission_energy_multiplier = 3.0
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	return mat
