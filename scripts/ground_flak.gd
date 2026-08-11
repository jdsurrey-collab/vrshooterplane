extends Node3D

## Purely cosmetic ground-to-air fire from the city — neutral (not faction-
## attributed), does zero damage to the player or any AI combatant, exists
## only to make the city read as an active warzone from a distance. Direct
## request: "neutral firepower... anti aircraft... blue and purple laser
## light... maybe some SM two style missiles... won't do any damage... just
## for show cosmetics... the more action packed it looks, the cooler."
## Followed by a second request for WWII-style flak bursts specifically:
## "mortar shells that shoot above the cloud line and explode into... a
## persistent fog of dark cloud."
##
## THREE independent sub-systems, all launched from real landmark-tower
## rooftops (CityGenerator.landmark_rooftops) rather than arbitrary points:
##
## 1. TRACER BOLTS — the routine background fire. Fast, thin, blue/purple.
##    Pure data (position/velocity/age), rendered through one
##    MultiMeshInstance3D exactly like faction_battle.gd's own ambient
##    bolts — just without any of the per-bolt collision work, since
##    nothing here can hit anything. Cheaper than that system despite being
##    entirely additive to it.
## 2. SAM MISSILES — a rarer, bigger event. Real (but simple) Nodes, since
##    only a handful exist at once — see flak_missile.gd.
## 3. FLAK SHELLS — mortar-style projectiles that arc up past the cloud
##    deck's own altitude (see atmosphere.gd's cloud_base_y/cloud_thickness)
##    and detonate into a FlakBurst (flak_burst.gd): a brief flash plus a
##    dark smoke puff that genuinely lingers (~20s), unlike every other
##    effect in this project, which is deliberately short-lived. Shells are
##    pooled data like tracer bolts (their own small MultiMesh); bursts are
##    real Nodes, budgeted the same way missiles are.
##
## BUDGETED AND RANGE-GATED, same discipline as every other spectacle
## system in this project (kill fireballs, hit sparks, battle audio,
## thruster trails): capped concurrent counts for all three sub-systems,
## and only rooftops within `spawn_range` of the player are eligible launch
## points, so cost doesn't scale with how much of the city technically
## exists, only with how much of it the player could plausibly see.

const FLAK_MISSILE := preload("res://scenes/FlakMissile.tscn")
const FLAK_BURST := preload("res://scenes/FlakBurst.tscn")

# --- Tracer bolts -----------------------------------------------------------
const MAX_BOLTS := 90
const BOLT_SPEED := 650.0
const BOLT_LIFETIME := 3.5
const BOLT_LENGTH := 20.0
const BOLT_RADIUS := 0.35
const BOLT_SPAWN_INTERVAL_MIN := 0.05
const BOLT_SPAWN_INTERVAL_MAX := 0.16
const BOLT_CONE_DEGREES := 14.0  # off straight-up, for visual variety

# --- SAM missiles -------------------------------------------------------
const MAX_MISSILES := 5
const MISSILE_SPAWN_INTERVAL_MIN := 2.5
const MISSILE_SPAWN_INTERVAL_MAX := 6.0
## Off straight-up, so launches run between 70 and 90 degrees of elevation —
## a direct request, to make the city read as throwing ballistic missiles out
## on visibly varied trajectories rather than firing everything dead vertical.
##
## Note the cone was already 22 degrees and the variance still was not
## visible: flak_missile.gd used to slerp its heading back toward vertical
## over the first 2.5s, which erased the launch angle before it could be seen.
## Removing that (see its header) is what actually makes this constant matter.
const MISSILE_CONE_DEGREES := 20.0

# --- Flak shells + bursts ----------------------------------------------
const MAX_SHELLS := 12
const SHELL_SPEED := 380.0
const SHELL_LENGTH := 3.0
const SHELL_RADIUS := 0.45
const SHELL_SPAWN_INTERVAL_MIN := 0.8
const SHELL_SPAWN_INTERVAL_MAX := 2.2
const SHELL_CONE_DEGREES := 10.0
## Straddles the cloud deck's own top (atmosphere.cloud_base_y +
## cloud_thickness, 3800m by default) — "shoot above the cloud line."
const SHELL_BURST_ALTITUDE_MIN := 3700.0
const SHELL_BURST_ALTITUDE_MAX := 4700.0
const MAX_BURSTS := 10

## Distant-explosion pool for flak detonations. Five variants rather than one
## because these fire constantly over the city and a single repeating sample
## is instantly recognisable as a loop; `_pick_burst_sound()` also never
## plays the same one twice in a row, the same rule
## player_damage_audio.gd already follows for hit sounds.
##
## All five are user-supplied recordings cut down and processed once through
## ffmpeg into deliberately MUFFLED distant explosions — highs rolled off
## hard at 1150Hz (rolling off the top end is what actually reads as
## "far away", far more than volume does), low end pushed for body, and a
## short echo for the city bouncing it back. Two of the source files turned
## out to contain several distinct explosions each, so the pool is wider
## than the number of files supplied.
const BURST_SOUNDS: Array[AudioStream] = [
	preload("res://Assets/Audio/city_explosion_1.mp3"),
	preload("res://Assets/Audio/city_explosion_2.mp3"),
	preload("res://Assets/Audio/city_explosion_3.mp3"),
	preload("res://Assets/Audio/city_explosion_4.mp3"),
	preload("res://Assets/Audio/city_explosion_5.mp3"),
]

@export var spawn_range: float = 9000.0  # only rooftops this close to the player are eligible launch points
@export var city_path: NodePath = ^"../City"
@export var player_path: NodePath = ^"../Player"

@export_group("Burst audio")
## How far a flak detonation can be heard. Generous, because hearing the city
## being shelled from a distance is the entire point — but past this the
## sound isn't spawned at all, which is also the budget gate.
@export var burst_sound_range: float = 9000.0
## Concurrent voice cap. Flak fires constantly; a heavy barrage would
## otherwise stack dozens of players at once.
@export var max_burst_sounds: int = 8
## Distance at which attenuation begins — larger means the sound stays at
## full strength further out before it starts falling off.
@export var burst_sound_unit_size: float = 900.0
## Godot's built-in distance low-pass. Low on purpose: these should read as
## muffled thuds through a canopy, not sharp cracks.
@export var burst_sound_cutoff_hz: float = 900.0
## Trim if flak ends up competing with the dogfight; raise if it's too shy.
@export var burst_volume_db: float = -4.0

var _city: Node
var _player: Node3D

var _bolts: Array = []  # {"position", "velocity", "age", "color"}
var _bolt_timer: float = 0.0
var _bolt_mmi: MultiMeshInstance3D

var _missile_timer: float = randf_range(1.0, 4.0)
var _missile_count: int = 0

var _shells: Array = []  # {"position", "velocity", "target_altitude"}
var _shell_timer: float = 0.0
var _shell_mmi: MultiMeshInstance3D
var _burst_count: int = 0
var _burst_sounds: Array = []
var _last_burst_sound: int = -1


func _ready() -> void:
	_city = get_node_or_null(city_path)
	_player = get_node_or_null(player_path)
	_bolt_mmi = _build_multimesh_renderer(BOLT_LENGTH, BOLT_RADIUS, MAX_BOLTS, true)
	_shell_mmi = _build_multimesh_renderer(SHELL_LENGTH, SHELL_RADIUS, MAX_SHELLS, false)
	_reset_bolt_timer()
	_reset_shell_timer()


func _physics_process(delta: float) -> void:
	if not _city or not _player:
		return

	_update_bolts(delta)
	_update_bolt_spawn(delta)
	_update_missile_spawn(delta)
	_update_shells(delta)
	_update_shell_spawn(delta)


# ---------------------------------------------------------------------------
# Tracer bolts
# ---------------------------------------------------------------------------

func _update_bolts(delta: float) -> void:
	var i := 0
	while i < _bolts.size():
		var b: Dictionary = _bolts[i]
		b["age"] += delta
		if b["age"] >= BOLT_LIFETIME:
			_bolts.remove_at(i)
			continue
		b["position"] += (b["velocity"] as Vector3) * delta
		i += 1

	_bolt_mmi.multimesh.visible_instance_count = _bolts.size()
	for j in _bolts.size():
		var rec: Dictionary = _bolts[j]
		_bolt_mmi.multimesh.set_instance_transform(j, _flying_transform(rec["position"], rec["velocity"]))
		_bolt_mmi.multimesh.set_instance_color(j, rec["color"])


func _update_bolt_spawn(delta: float) -> void:
	_bolt_timer -= delta
	if _bolt_timer > 0.0 or _bolts.size() >= MAX_BOLTS:
		return
	_reset_bolt_timer()

	var launch := _pick_launch_point()
	if not launch["found"]:
		return
	var dir := _cone_direction(Vector3.UP, BOLT_CONE_DEGREES)
	_bolts.append({
		"position": launch["position"],
		"velocity": dir * BOLT_SPEED,
		"age": 0.0,
		"color": _flak_color(),
	})


func _reset_bolt_timer() -> void:
	_bolt_timer = randf_range(BOLT_SPAWN_INTERVAL_MIN, BOLT_SPAWN_INTERVAL_MAX)


# ---------------------------------------------------------------------------
# SAM missiles
# ---------------------------------------------------------------------------

func _update_missile_spawn(delta: float) -> void:
	_missile_timer -= delta
	if _missile_timer > 0.0 or _missile_count >= MAX_MISSILES:
		return
	_missile_timer = randf_range(MISSILE_SPAWN_INTERVAL_MIN, MISSILE_SPAWN_INTERVAL_MAX)

	var launch := _pick_launch_point()
	if not launch["found"]:
		return
	var dir := _cone_direction(Vector3.UP, MISSILE_CONE_DEGREES)
	# Every direction this system generates is a tight cone around UP (see
	# _cone_direction), so unlike faction_battle.gd's own up_ref logic
	# (which has to handle a heading pointing literally anywhere, including
	# straight up during a dive/climb), FORWARD is ALWAYS a safe up
	# reference here — it can never be colinear with a near-vertical dir.
	# A conditional UP/FORWARD switch (copied from that other convention
	# initially) was actually the wrong tool for this specific case: cone
	# angles under Basis.looking_at()'s own colinearity tolerance still
	# triggered "Target and up vectors are colinear" warnings even with a
	# 0.99 dot-product guard, because the guard's threshold didn't match
	# Godot's internal one. Always using FORWARD sidesteps needing to
	# guess that threshold at all.
	var up_ref := Vector3.FORWARD

	var missile := FLAK_MISSILE.instantiate()
	# Transform set before add_child(), matching missile.gd's own
	# convention (and the before-add_child() rule documented in
	# faction_battle.gd) — the missile's _ready() reads its facing directly
	# from this basis.
	missile.global_transform = Transform3D(Basis.looking_at(dir, up_ref), launch["position"])
	missile.tree_exited.connect(func(): _missile_count -= 1)
	_missile_count += 1
	get_tree().current_scene.add_child(missile)


# ---------------------------------------------------------------------------
# Flak shells + bursts
# ---------------------------------------------------------------------------

func _update_shells(delta: float) -> void:
	var i := 0
	while i < _shells.size():
		var s: Dictionary = _shells[i]
		s["position"] += (s["velocity"] as Vector3) * delta
		if s["position"].y >= s["target_altitude"]:
			_spawn_burst(s["position"])
			_shells.remove_at(i)
			continue
		i += 1

	_shell_mmi.multimesh.visible_instance_count = _shells.size()
	for j in _shells.size():
		var rec: Dictionary = _shells[j]
		_shell_mmi.multimesh.set_instance_transform(j, _flying_transform(rec["position"], rec["velocity"]))


func _update_shell_spawn(delta: float) -> void:
	_shell_timer -= delta
	if _shell_timer > 0.0 or _shells.size() >= MAX_SHELLS:
		return
	_reset_shell_timer()

	var launch := _pick_launch_point()
	if not launch["found"]:
		return
	var dir := _cone_direction(Vector3.UP, SHELL_CONE_DEGREES)
	_shells.append({
		"position": launch["position"],
		"velocity": dir * SHELL_SPEED,
		"target_altitude": randf_range(SHELL_BURST_ALTITUDE_MIN, SHELL_BURST_ALTITUDE_MAX),
	})


func _reset_shell_timer() -> void:
	_shell_timer = randf_range(SHELL_SPAWN_INTERVAL_MIN, SHELL_SPAWN_INTERVAL_MAX)


func _spawn_burst(at_position: Vector3) -> void:
	if _burst_count >= MAX_BURSTS:
		return
	var burst := FLAK_BURST.instantiate()
	burst.tree_exited.connect(func(): _burst_count -= 1)
	_burst_count += 1
	get_tree().current_scene.add_child(burst)
	burst.global_position = at_position
	_play_burst_sound(at_position)


## Positional thump for a flak detonation. Budgeted and distance-gated the
## same way faction_battle.gd's own battle audio is — flak fires constantly,
## so without a cap a heavy barrage would spawn dozens of concurrent voices.
##
## `attenuation_filter_cutoff_hz` is doing most of the work here: it is
## Godot's built-in distance low-pass, so a burst on the far side of the city
## arrives not merely quieter but genuinely duller, which is what sells
## distance far better than volume alone. Set aggressively low, because these
## are meant to read as muffled thuds heard through a cockpit rather than
## sharp cracks.
func _play_burst_sound(at_position: Vector3) -> void:
	if _player == null or BURST_SOUNDS.is_empty():
		return
	if _player.global_position.distance_to(at_position) > burst_sound_range:
		return

	for i in range(_burst_sounds.size() - 1, -1, -1):
		if not is_instance_valid(_burst_sounds[i]):
			_burst_sounds.remove_at(i)
	if _burst_sounds.size() >= max_burst_sounds:
		return

	var sound := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(sound)
	sound.global_position = at_position
	sound.stream = _pick_burst_sound()
	sound.volume_db = burst_volume_db
	sound.unit_size = burst_sound_unit_size
	sound.max_distance = burst_sound_range
	sound.attenuation_filter_cutoff_hz = burst_sound_cutoff_hz
	sound.attenuation_filter_db = -32.0
	sound.play()
	sound.finished.connect(sound.queue_free)
	_burst_sounds.append(sound)


## Random pick that never repeats the immediately-previous one — with bursts
## going off every couple of seconds, back-to-back repeats are the thing that
## makes a small pool sound small.
func _pick_burst_sound() -> AudioStream:
	if BURST_SOUNDS.size() == 1:
		return BURST_SOUNDS[0]
	var i := randi() % BURST_SOUNDS.size()
	if i == _last_burst_sound:
		i = (i + 1 + (randi() % (BURST_SOUNDS.size() - 1))) % BURST_SOUNDS.size()
	_last_burst_sound = i
	return BURST_SOUNDS[i]


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

## A random point within `cone_degrees` of `axis` — used for the tracer
## bolts' slight scatter, the missiles' wider post-launch arc, and the
## shells' own gentle spread.
func _cone_direction(axis: Vector3, cone_degrees: float) -> Vector3:
	var max_rad := deg_to_rad(cone_degrees)
	var arbitrary := Vector3.RIGHT if absf(axis.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
	var perp := axis.cross(arbitrary).normalized()
	var tilted := axis.rotated(perp, randf_range(0.0, max_rad))
	return tilted.rotated(axis, randf_range(0.0, TAU)).normalized()


## Random landmark rooftop within spawn_range of the player, or "found":
## false if none qualify (e.g. the player is far from the city, or the city
## hasn't finished building yet). A Dictionary return rather than a nullable
## Vector3, since GDScript can't type a Vector3-returning function to also
## return null.
func _pick_launch_point() -> Dictionary:
	if not (_city and "landmark_rooftops" in _city):
		return {"found": false}
	var roofs: Array = _city.landmark_rooftops
	if roofs.is_empty():
		return {"found": false}
	var listener: Vector3 = _player.global_position
	for _attempt in 6:
		var candidate: Vector3 = roofs[randi() % roofs.size()]
		if listener.distance_to(candidate) <= spawn_range:
			return {"found": true, "position": candidate}
	return {"found": false}


func _flak_color() -> Color:
	# Random blend between a blue and a purple endpoint, pushed above 1.0
	# per channel so Town.tscn's Glow pass actually blooms it — the same
	# "neon" convention this project's other emissive HUD/laser elements
	# already use.
	var blue := Color(0.25, 0.65, 2.4)
	var purple := Color(1.3, 0.35, 2.5)
	return blue.lerp(purple, randf())


## Shared by both the tracer-bolt and flak-shell MultiMeshInstance3Ds — a
## thin tapered cylinder, the same visual language laser_bolt.gd already
## established for this project's other bolts. `tinted` controls whether
## per-instance color is enabled (bolts get random blue/purple variety;
## shells stay a flat warm tracer color, so they read as visually distinct
## from the AA fire around them).
func _build_multimesh_renderer(length: float, radius: float, max_instances: int, tinted: bool) -> MultiMeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * 0.3
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 6

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if tinted:
		mat.vertex_color_use_as_albedo = true
		mat.albedo_color = Color(1, 1, 1, 1)
	else:
		mat.albedo_color = Color(2.2, 1.6, 1.0)  # warm tracer, pushed for bloom

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = tinted
	mm.mesh = mesh
	mm.instance_count = max_instances
	mm.visible_instance_count = 0
	# Fixed bounds instead of letting the renderer re-derive them from every
	# instance each frame — these pools are rewritten wholesale every frame,
	# which would otherwise mark the AABB dirty every frame and force that
	# walk. Sized to cover the city and the airspace above it. Same reasoning
	# and same constant shape as faction_battle.gd's MULTIMESH_WORLD_AABB.
	mm.custom_aabb = AABB(Vector3(-60000.0, -20000.0, -60000.0), Vector3(120000.0, 40000.0, 120000.0))

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	return mmi


## CylinderMesh's long axis is local Y by default; the projectile travels
## along `velocity`. Same -90-degree-about-X correction faction_battle.gd's
## own ambient bolts already use for the identical reason.
##
## up_ref is unconditionally FORWARD, not the conditional UP/FORWARD switch
## faction_battle.gd uses for ship headings — see the comment on the
## identical choice in _update_missile_spawn() above for why that pattern
## doesn't fit here (every dir this system produces is a tight cone around
## UP, so FORWARD is always safely non-colinear with it).
func _flying_transform(position: Vector3, velocity: Vector3) -> Transform3D:
	var dir := velocity.normalized()
	var mesh_correction := Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	return Transform3D(Basis.looking_at(dir, Vector3.FORWARD) * mesh_correction, position)
