class_name TankObjective
extends Node3D

## GROUND OBJECTIVE — attack/defend over the city's fuel tanks.
##
## The first of the three scoring tiers (ground / dogfight / air), and the
## first objective in this project that is not ship-vs-ship.
##
## THE MATCH SHAPE
##
## One faction is randomly the ATTACKER and the other the DEFENDER, rerolled
## every match so there is no fixed meta. `tank_count` (20) propane tanks
## belong to the DEFENDER and are scattered at random across the city floor,
## also rerolled every match. The attacker's job is to destroy them; the
## defender's job is to stop that happening.
##
## **Destroying every tank wins the match outright for the attacker**, via
## FactionBattle.declare_winner() — it does not merely add score. Partial
## progress still counts, though: each tank pays `air_superiority_per_tank`
## into the same `air_superiority` scalar everything else in this game feeds,
## signed toward whichever faction is attacking. That matters because the
## match can also end on the 10-minute timer, and without partial credit an
## attacker who destroyed 19 of 20 tanks would have nothing to show for it.
##
## Tanks take damage from the player's lasers and missiles through the same
## swept-segment path those weapons already use against ships — see
## check_hit() below, called from laser_bolt.gd and missile.gd.
##
## THE COLLAPSE
##
## A destroyed tank takes its block down with it: every building within
## `collapse_radius` sinks bodily into the earth and disappears (see
## city_generator.gd's collapse_near()). This is deliberately a slow descent
## rather than a fracture simulation — with ~1400 buildings drawn as batched
## MultiMesh instances, sliding a transform downward is affordable where
## real destruction geometry would not be, and from a cockpit at altitude it
## reads as the ground swallowing a city block.
##
## RENDERING
##
## All tanks live in one MultiMeshInstance3D, the same technique
## faction_battle.gd uses for its ships and city_generator.gd for its
## buildings. The source mesh is 268 triangles, so the entire objective costs
## one draw call and ~5,400 triangles. A destroyed tank is hidden by zeroing
## its instance transform — MultiMesh has no per-instance visibility flag for
## an arbitrary middle index.

const TANK_MESH_PATH := "res://Assets/Industrial/gas_tank.glb"
const SHIP_EXPLOSION := preload("res://scenes/ShipExplosion.tscn")

## Deliberately its OWN sound rather than one of ground_flak.gd's five
## burst variants: a fuel tank going up is the single biggest event on the
## ground, and it should not be mistakable for routine anti-aircraft fire.
## Longer (11.5s of rolling rumble against their 2-4s thumps) and processed
## with the same muffled-distance treatment, so it still reads as something
## heavy happening below rather than a crack in the cockpit.
const TANK_EXPLOSION_SOUND := preload("res://Assets/Audio/tank_explosion.mp3")

## The source model is a real-world propane tank, ~4m long — invisible from a
## fighter. Scaled up into a piece of city-scale industrial infrastructure:
## at 25x it is ~100m long and ~54m tall, which reads clearly from the air
## against buildings that run from ~100m to ~1870m.
@export var tank_scale: float = 25.0

## 20 tanks, all belonging to the defender. Exported because the right number
## depends entirely on how fast they can actually be cleared in a 10-minute
## match, which needs live play to judge.
@export var tank_count: int = 20

@export var tank_health: float = 60.0

## Partial credit per tank, signed toward the attacking faction. 20 tanks x
## 2.5 = 50 points, i.e. half the bar — deliberately comparable to what a
## whole match of dome presence generates at as_generation_multiplier 0.01,
## so the ground tier is a genuine "moneymaker" alongside the air war rather
## than a side activity. Destroying ALL of them ends the match regardless.
@export var air_superiority_per_tank: float = 2.5

## How far the ground shock reaches when a tank goes up. 400m is roughly a
## block and a half at the city's 257m block pitch, so a kill takes its
## immediate neighbourhood rather than a single building or half a district.
@export var collapse_radius: float = 400.0

## Half-width of the square area tanks scatter across, centred on
## `CityGenerator.city_center`. Used to read this from `_city.grid_size *
## _city.block_pitch * 0.5` — CityGenerator's own footprint math — but that
## broke the instant `city_generator.gd`'s buildings stopped having a fixed
## footprint at all (map-wide, height-gated placement now — see that
## script's own header). Kept as this project's OWN number instead,
## matching the OLD city footprint exactly (5400m = the previous
## 10800m-wide grid's own half-extent) so the fuel-tank objective's actual
## play area is UNCHANGED: tanks are a ground objective meant to sit inside
## the contested airspace the AI/player actually fight over
## (`FactionBattle.dome_radius`, sized against this same original
## footprint), not scattered anywhere across a 100km map most of which
## nobody ever flies over.
@export var scatter_radius: float = 5400.0

## Minimum spacing between tanks, and clearance from any standing building,
## when scattering them. Both are in metres.
@export var tank_min_spacing: float = 600.0
@export var tank_building_clearance: float = 120.0

@export_group("Detonation audio")
## A tank going up should carry much further than flak — it's a landmark
## event, and hearing one you didn't cause is real information about how the
## match is going.
@export var explosion_sound_range: float = 16000.0
@export var explosion_sound_unit_size: float = 1800.0
## Distance low-pass. Kept low so it stays a deep muffled rumble rather than
## a sharp bang, matching the rest of this project's distant-combat audio.
@export var explosion_sound_cutoff_hz: float = 800.0
@export var explosion_volume_db: float = 0.0

@export var city_path: NodePath = ^"../City"
@export var battle_path: NodePath = ^"../FactionBattle"
@export var terrain_path: NodePath = ^"../Terrain"

## Combatant.Faction value of whoever is attacking this match. Rerolled in
## start_objective(). Read by battle_hud.gd for the role readout.
var attacking_faction: int = 0
var tanks_remaining: int = 0
var active: bool = false

## Highest point any tank reaches, in absolute world Y — recomputed whenever
## the layout is rolled. This is a free, EXACT rejection gate for the mass
## battle's ambient-bolt-vs-tank test: tanks sit on the terrain and grow
## upward, so a bolt above this cannot possibly be intersecting one and the
## whole swept check is skipped. Combat here almost always happens thousands
## of metres up, so that rejects the overwhelming majority of bolts for the
## price of one float compare. -INF until a layout exists, which correctly
## rejects everything.
var max_tank_top_y: float = -INF

# Per tank: {"pos": Vector3, "alive": bool, "health": float}
var _tanks: Array[Dictionary] = []
var _mmi: MultiMeshInstance3D
var _city: Node
var _battle: Node
var _terrain: Node
var _tank_radius: float = 1.0


func _ready() -> void:
	_city = get_node_or_null(city_path)
	_battle = get_node_or_null(battle_path)
	_terrain = get_node_or_null(terrain_path)
	_build_renderer()


## Called by game_flow.gd when a match actually starts (NOT in _ready) — the
## whole point is that roles and tank positions are rerolled per match, and
## reset_battle()/returning to the menu has to be able to reroll them again.
func start_objective() -> void:
	if _city == null or _terrain == null:
		push_warning("TankObjective: no City/Terrain, ground objective disabled")
		return

	# Coin flip, every match. The player always flies for FRIENDLY, so this
	# is also what decides whether the player spends the match hunting tanks
	# or defending them.
	attacking_faction = Combatant.Faction.ENEMY if randf() < 0.5 else Combatant.Faction.FRIENDLY

	_scatter_tanks()
	tanks_remaining = _tanks.size()
	active = tanks_remaining > 0
	_write_transforms()


## Puts every tank back and rerolls both the roles and the layout — called
## from the same place FactionBattle.reset_battle() is.
func reset_objective() -> void:
	active = false
	_tanks.clear()
	tanks_remaining = 0
	max_tank_top_y = -INF
	if _mmi:
		_mmi.multimesh.visible_instance_count = 0


func _build_renderer() -> void:
	var mesh := _load_tank_mesh()
	if mesh == null:
		push_warning("TankObjective: could not load %s" % TANK_MESH_PATH)
		return
	var aabb := mesh.get_aabb()
	_tank_radius = maxf(aabb.size.x, aabb.size.z) * 0.5 * tank_scale

	_mmi = MultiMeshInstance3D.new()
	# Tanks sit on the ground under buildings that are already excluded from
	# the shadow pass; a shadow from one would cost a second pass over this
	# geometry for something nothing is looking at.
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = tank_count
	mm.visible_instance_count = 0
	# Fixed bounds, same reasoning as everywhere else in this project that
	# writes instance transforms at runtime — see city_generator.gd's
	# CITY_BATCH_AABB.
	mm.custom_aabb = AABB(Vector3(-24000.0, -10000.0, -24000.0), Vector3(48000.0, 24000.0, 48000.0))
	_mmi.multimesh = mm


## The .glb imports as a PackedScene, so the actual Mesh has to be dug out of
## its MeshInstance3D — unlike the city's .fbx models, this one DOES carry
## its albedo texture across the import, so no material rebuild is needed.
func _load_tank_mesh() -> Mesh:
	var packed: PackedScene = load(TANK_MESH_PATH)
	if packed == null:
		return null
	var root := packed.instantiate()
	var found: Mesh = _find_mesh(root)
	root.queue_free()
	return found


func _find_mesh(n: Node) -> Mesh:
	if n is MeshInstance3D:
		return (n as MeshInstance3D).mesh
	for c in n.get_children():
		var m := _find_mesh(c)
		if m != null:
			return m
	return null


## Random placement across the city footprint, rejecting anything that lands
## inside a building or too near another tank. Rejection sampling rather than
## a fixed layout is the whole point — "so there's not, like, a meta for
## this."
func _scatter_tanks() -> void:
	_tanks.clear()
	var half: float = scatter_radius
	var center: Vector3 = _city.city_center

	var attempts := 0
	var max_attempts := tank_count * 260
	while _tanks.size() < tank_count and attempts < max_attempts:
		attempts += 1
		var x := center.x + randf_range(-half, half)
		var z := center.z + randf_range(-half, half)

		if not _city.is_ground_clear(x, z, tank_building_clearance + _tank_radius):
			continue
		var too_close := false
		for t in _tanks:
			var p: Vector3 = t["pos"]
			if Vector2(p.x - x, p.z - z).length() < tank_min_spacing:
				too_close = true
				break
		if too_close:
			continue

		_tanks.append({
			"pos": Vector3(x, _terrain.get_height_at(x, z), z),
			"alive": true,
			"health": tank_health,
		})

	# Top of the tallest tank's COLLISION volume (not its visual mesh) — the
	# gate has to match what check_hit() can actually register, or a bolt could
	# be rejected on altitude while still being inside the sphere it tests.
	max_tank_top_y = -INF
	for t in _tanks:
		max_tank_top_y = maxf(max_tank_top_y, (t["pos"] as Vector3).y + _tank_radius * 1.5)

	if _tanks.size() < tank_count:
		push_warning("TankObjective: placed only %d/%d tanks in %d attempts"
				% [_tanks.size(), tank_count, attempts])


func _write_transforms() -> void:
	if _mmi == null:
		return
	_mmi.multimesh.visible_instance_count = _tanks.size()
	for i in _tanks.size():
		var t: Dictionary = _tanks[i]
		if t["alive"]:
			_mmi.multimesh.set_instance_transform(i, Transform3D(
					Basis().scaled(Vector3(tank_scale, tank_scale, tank_scale)), t["pos"]))
		else:
			_mmi.multimesh.set_instance_transform(i,
					Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))


# ---------------------------------------------------------------------------
# Weapon interface
# ---------------------------------------------------------------------------

## Swept segment test, matching how laser_bolt.gd and missile.gd already test
## against ships — a plain point check would let a 600 m/s bolt tunnel clean
## through a tank between two sampled positions. Returns the index of the
## first living tank the segment `from`->`to` passes within its radius of, or
## -1. Callers are responsible for only calling this when the shot's OWNER is
## the attacking faction (see can_be_damaged_by).
func check_hit(from: Vector3, to: Vector3) -> int:
	if not active:
		return -1
	var seg := to - from
	var seg_len_sq := seg.length_squared()
	for i in _tanks.size():
		var t: Dictionary = _tanks[i]
		if not t["alive"]:
			continue
		var body_center := _body_center(t["pos"])
		var closest: Vector3
		if seg_len_sq <= 0.0:
			closest = from
		else:
			var t_along := clampf((body_center - from).dot(seg) / seg_len_sq, 0.0, 1.0)
			closest = from + seg * t_along
		if closest.distance_squared_to(body_center) <= _tank_radius * _tank_radius:
			return i
	return -1


## Tanks sit ON the ground and the mesh grows upward from its base, so both
## the hit test and the AI's aim point work off the middle of the body rather
## than its foot. Shared so the two can't drift apart.
func _body_center(pos: Vector3) -> Vector3:
	return pos + Vector3(0.0, _tank_radius * 0.5, 0.0)


## Tanks belong to the DEFENDER, so only the attacking faction gets credit
## for blowing them up. Without this, a defending player could clear their
## own objective and hand the match to the other side.
func can_be_damaged_by(faction: int) -> bool:
	return active and faction == attacking_faction


func get_tank_position(index: int) -> Vector3:
	return _tanks[index]["pos"] if index >= 0 and index < _tanks.size() else Vector3.ZERO


# ---------------------------------------------------------------------------
# AI interface — faction_battle.gd's STRIKE / TANK_GUARD squads
# ---------------------------------------------------------------------------

func is_tank_alive(index: int) -> bool:
	return active and index >= 0 and index < _tanks.size() and _tanks[index]["alive"]


## Where a strike pilot actually aims and shoots — the body centre, so bolts
## converge on the tank rather than its footprint.
func get_tank_aim_point(index: int) -> Vector3:
	if index < 0 or index >= _tanks.size():
		return Vector3.ZERO
	return _body_center(_tanks[index]["pos"])


## Nearest living tank to `from`, or -1. Linear over at most `tank_count` (20)
## entries, and only ever called when a squad needs a NEW ground target — a
## handful of times a match, not per frame — so a spatial structure would be
## more bookkeeping than it saves.
func get_nearest_live_tank(from: Vector3) -> int:
	var best := -1
	var best_dist := INF
	for i in _tanks.size():
		if not _tanks[i]["alive"]:
			continue
		var d: float = from.distance_squared_to(_tanks[i]["pos"])
		if d < best_dist:
			best_dist = d
			best = i
	return best


## A random living tank, or -1. Used for TANK_GUARD patrol objectives rather
## than "nearest": guards picking nearest would all converge on whichever tank
## happens to be closest to the mothership, which is the same single-point
## clustering bug _make_rally_point() already had to be fixed for.
func get_random_live_tank() -> int:
	if tanks_remaining <= 0:
		return -1
	var live: Array[int] = []
	for i in _tanks.size():
		if _tanks[i]["alive"]:
			live.append(i)
	return live[randi() % live.size()] if not live.is_empty() else -1


func apply_damage(index: int, amount: float, cause: String = "destroyed by PLAYER") -> void:
	if not active or index < 0 or index >= _tanks.size():
		return
	var t: Dictionary = _tanks[index]
	if not t["alive"]:
		return
	t["health"] = float(t["health"]) - amount
	if t["health"] > 0.0:
		return

	t["alive"] = false
	tanks_remaining -= 1
	_write_transforms()
	_detonate(t["pos"], index, cause)

	if tanks_remaining <= 0:
		_attackers_win()


func _detonate(pos: Vector3, index: int, cause: String) -> void:
	# A fuel tank going up is the biggest single explosion in the game, so it
	# reuses the kill fireball rather than the small laser-impact effect —
	# and takes the same budgeted `enable_light` treatment, assigned BEFORE
	# add_child() per this project's standing rule.
	var boom := SHIP_EXPLOSION.instantiate()
	boom.enable_light = true
	get_tree().current_scene.add_child(boom)
	boom.global_position = pos + Vector3(0.0, _tank_radius * 0.5, 0.0)

	_play_explosion_sound(pos)

	if _city and _city.has_method("collapse_near"):
		_city.collapse_near(pos, collapse_radius)

	if _battle:
		# Signed toward whoever is attacking: air_superiority is +friendly /
		# -enemy, so an enemy attacker's progress drives it negative.
		var signed_gain: float = air_superiority_per_tank
		if attacking_faction == Combatant.Faction.ENEMY:
			signed_gain = -signed_gain
		if _battle.has_method("grant_air_superiority"):
			_battle.grant_air_superiority(signed_gain,
					"FUEL TANK %d/%d %s" % [tank_count - tanks_remaining, tank_count, cause])


## Positional rumble for a tank detonation. Needs no concurrency cap of its
## own the way flak does — there are only ever 20 tanks in a whole match and
## they cannot be destroyed faster than the player can fly between them, so
## the natural rate is already the budget. Spawned as a standalone
## short-lived player rather than a child of anything, since the tank itself
## is a MultiMesh instance with no node to attach to.
func _play_explosion_sound(at_position: Vector3) -> void:
	var listener: Node3D = get_tree().current_scene.get_node_or_null("Player") as Node3D
	if listener and listener.global_position.distance_to(at_position) > explosion_sound_range:
		return
	var sound := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(sound)
	sound.global_position = at_position
	sound.stream = TANK_EXPLOSION_SOUND
	sound.volume_db = explosion_volume_db
	sound.unit_size = explosion_sound_unit_size
	sound.max_distance = explosion_sound_range
	sound.attenuation_filter_cutoff_hz = explosion_sound_cutoff_hz
	sound.attenuation_filter_db = -30.0
	sound.play()
	sound.finished.connect(sound.queue_free)


func _attackers_win() -> void:
	active = false
	if _battle and _battle.has_method("declare_winner"):
		_battle.declare_winner(attacking_faction, "ALL FUEL TANKS DESTROYED")


## "ATTACK" / "DEFEND" from the player's point of view — the player always
## flies for FRIENDLY. Used by battle_hud.gd.
func player_role_text() -> String:
	if not active and tanks_remaining <= 0:
		return ""
	return "ATTACK" if attacking_faction == Combatant.Faction.FRIENDLY else "DEFEND"


## The same thing as a noun, for role_stamp.gd's match-opening announcement
## ("ATTACKER" / "DEFENDER"). Separate from player_role_text() rather than
## derived from it because the HUD wants the shortest label that fits on a
## status line while the stamp wants the word said properly.
func player_role_noun() -> String:
	if not active:
		return ""
	return "ATTACKER" if attacking_faction == Combatant.Faction.FRIENDLY else "DEFENDER"
