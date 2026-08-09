extends Node3D

## Alien invasion: 200 friendly ships vs. 200 alien ships fighting for
## control of the city, plus the player. Replaces the old single wandering
## HOSTILE-1 (enemy_ai.gd/EnemyShip.tscn, left on disk unused, same
## convention as the retired map editor).
##
## ARCHITECTURE — one manager, not 400 nodes. 400 individual Node3D+script
## instances (the old enemy_ai.gd pattern) would mean 400x that per-instance
## overhead. Instead every combatant is a lightweight Combatant (RefCounted,
## see combatant.gd) held in a plain Array, and this single script updates
## all of them in tight loops every _physics_process, then writes the
## results into two MultiMeshInstance3D (one per faction, GPU-instanced —
## same technique city_generator.gd already uses for its ~1200 street
## tiles) instead of one draw call per ship.
##
## AIR SUPERIORITY — an invisible cylindrical "dome" over the city
## (city_center, dome_radius horizontally, dome_ceiling above terrain).
## Every physics frame, each side's count of living ships currently inside
## the dome (the player counts as one friendly) nets against the other:
## air_superiority += (friendly_in_dome - enemy_in_dome) * delta, clamped to
## [-100, 100] — one enemy in the dome cancels one friendly's contribution,
## exactly 1-for-1. Either side hitting +/-100, or the 10-minute match timer
## expiring (higher AS wins), ends the match.
##
## RETARGETING is staggered — only ~1/8 of the population re-evaluates its
## target each frame (round-robin by index), each doing a linear scan of the
## ~200 opposing living units (~10k comparisons/frame total, trivial). A
## combatant whose target just died force-retargets immediately regardless
## of stagger slot. Aliens additionally consider the player as a target
## candidate (gated by aggro_radius_player) — friendlies never do.
##
## BOLTS are two separate systems. Ambient unit-vs-unit fire ("lasers
## everywhere") uses a pooled, non-Node bolt array (Dictionaries), rendered
## via a third MultiMeshInstance3D, hit-checked with the same closest-point-
## on-segment swept test laser_bolt.gd already uses (a plain point/distance
## check would let bolts tunnel through targets at 900 m/s — this project
## already fixed that bug once for the player's own bolts). Hit checks are
## spatially bucketed into a per-frame grid keyed by
## city_generator.gd's own block_pitch (450m cells) — unstaggered bolt-vs-
## unit checks are the single biggest CPU cost in this system, dwarfing
## retargeting, so they're the one thing that gets bucketed instead of
## staggered (a bolt's hit check can't skip frames without reintroducing
## tunneling). Aliens shooting AT THE PLAYER specifically instead reuse the
## existing LaserBolt.tscn/laser_bolt.gd Node-based system
## (fired_by_player=false) — low volume by construction (aggro-gated), and
## it's what feeds player_damage.gd's already-built hit path.
##
## The PLAYER's own weapon damages aliens through this manager too —
## laser_bolt.gd's _check_enemy_hit() calls get_nearest_alive_alien() /
## apply_damage() below instead of the old hardcoded single-enemy node.
## Friendlies are a structurally separate array the player-facing API never
## touches, so they can never be targeted or damaged — not an explicit
## exclusion check, just a consequence of the split.

const LASER_BOLT := preload("res://scenes/LaserBolt.tscn")
const SHIP_MESH_PATH := "res://Assets/EnemyShip/ship1.obj"
const SHIP_SCALE := 2.0  # matches EnemyShip.tscn / Player.tscn's ShipHull

const MAX_HEALTH := 30.0  # ~3 player hits (10 dmg/bolt) to kill — visible, not one-shot
const BOLT_DAMAGE := 10.0
const BOLT_SPEED := 900.0  # matches laser_bolt.gd's speed, for a consistent laser feel
const BOLT_LIFETIME := 3.0
const BOLT_HIT_RADIUS := 4.0  # matches laser_bolt.gd's enemy_hit_radius

const RETARGET_STAGGER := 8
const GRID_CELL_SIZE := 450.0  # city_generator.gd's block_pitch — reused as the bolt-hit bucket size
const ENGAGE_RANGE := 700.0
const TURN_RATE := 0.6  # rad/s-ish steering response
const RESPAWN_DELAY := 8.0
const SPAWN_SCATTER_RADIUS := 1500.0
const SPAWN_ALT_MIN := 300.0
const SPAWN_ALT_MAX := 900.0

const FRIENDLY_COLOR := Color(0.25, 0.65, 1.0)
const ENEMY_COLOR := Color(0.85, 0.1, 0.85)

@export var friendly_count: int = 200
@export var enemy_count: int = 200
@export var dome_radius: float = 8000.0  # covers the city's ~7637m corner-to-corner footprint
@export var dome_ceiling: float = 3500.0  # above terrain
@export var match_duration: float = 600.0  # 10 minutes
@export var aggro_radius_player: float = 2500.0
@export var max_ambient_bolts: int = 180
@export var enable_building_collision_check: bool = true

## Live status, readable by battle_hud.gd / target_lock.gd / enemy_locator.gd.
var air_superiority: float = 0.0  # -100 (enemy control) .. +100 (friendly control)
var match_time_remaining: float = 0.0
var game_over: bool = false
var winning_faction: int = -1  # Combatant.Faction.FRIENDLY/ENEMY, or -1 for a draw
var dome_center: Vector3 = Vector3(6000.0, 0.0, 0.0)

var _friendlies: Array[Combatant] = []
var _enemies: Array[Combatant] = []
var _ambient_bolts: Array[Dictionary] = []
var _friendly_grid: Dictionary = {}
var _enemy_grid: Dictionary = {}
var _frame_counter: int = 0

var _friendly_spawn_center: Vector3
var _enemy_spawn_center: Vector3

var _terrain: Node
var _player: Node3D

var _friendly_mmi: MultiMeshInstance3D
var _enemy_mmi: MultiMeshInstance3D
var _bolt_mmi: MultiMeshInstance3D


func _ready() -> void:
	randomize()
	_terrain = get_node_or_null("../Terrain")
	_player = get_tree().current_scene.get_node_or_null("Player")

	var city := get_node_or_null("../City")
	if city and "city_center" in city:
		dome_center = city.city_center

	_friendly_spawn_center = dome_center + Vector3(-10000.0, 0.0, 0.0)
	_enemy_spawn_center = dome_center + Vector3(10000.0, 0.0, 0.0)
	match_time_remaining = match_duration

	_build_multimesh_nodes()
	_spawn_faction(_friendlies, friendly_count, _friendly_spawn_center, Combatant.Faction.FRIENDLY)
	_spawn_faction(_enemies, enemy_count, _enemy_spawn_center, Combatant.Faction.ENEMY)
	_friendly_mmi.multimesh.instance_count = friendly_count
	_enemy_mmi.multimesh.instance_count = enemy_count


func _physics_process(delta: float) -> void:
	if game_over:
		return

	_update_match_timer(delta)

	for i in _friendlies.size():
		_update_combatant(_friendlies[i], i, _enemies, false, delta)
	for i in _enemies.size():
		_update_combatant(_enemies[i], i, _friendlies, true, delta)

	_rebuild_spatial_grids()
	_update_ambient_bolts(delta)
	_update_air_superiority(delta)
	_write_multimesh_transforms()

	_frame_counter += 1


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _build_multimesh_nodes() -> void:
	var ship_mesh: Mesh = load(SHIP_MESH_PATH)
	_friendly_mmi = _make_ship_multimesh(ship_mesh, FRIENDLY_COLOR)
	_enemy_mmi = _make_ship_multimesh(ship_mesh, ENEMY_COLOR)

	var bolt_mesh := CylinderMesh.new()
	bolt_mesh.top_radius = 0.0
	bolt_mesh.bottom_radius = 0.06
	bolt_mesh.height = 2.5
	bolt_mesh.radial_segments = 8

	var bolt_mat := StandardMaterial3D.new()
	bolt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bolt_mat.albedo_color = Color(1.0, 0.15, 0.1, 1.0)
	bolt_mat.emission_enabled = true
	bolt_mat.emission = Color(1.0, 0.15, 0.1, 1.0)
	bolt_mat.emission_energy_multiplier = 8.0

	_bolt_mmi = MultiMeshInstance3D.new()
	add_child(_bolt_mmi)
	var bolt_multimesh := MultiMesh.new()
	bolt_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	bolt_multimesh.mesh = bolt_mesh
	bolt_multimesh.instance_count = max_ambient_bolts
	bolt_multimesh.visible_instance_count = 0
	_bolt_mmi.multimesh = bolt_multimesh
	_bolt_mmi.material_override = bolt_mat


func _make_ship_multimesh(mesh: Mesh, tint: Color) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	add_child(mmi)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.emission_enabled = true
	mat.emission = tint
	mat.emission_energy_multiplier = 0.6
	mmi.material_override = mat

	# transform_format must be set before instance_count — instance_count
	# allocates the multimesh buffer sized to whatever format is active at
	# that moment (set later in _ready(), once friendly/enemy_count are known).
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mmi.multimesh = mm
	return mmi


func _spawn_faction(target: Array, count: int, spawn_center: Vector3, faction: int) -> void:
	for i in count:
		var c := Combatant.new()
		c.faction = faction
		c.speed = randf_range(120.0, 200.0)
		_respawn_combatant(c, spawn_center)
		c.respawn_time_remaining = 0.0
		target.append(c)


# ---------------------------------------------------------------------------
# Per-combatant update
# ---------------------------------------------------------------------------

func _update_combatant(c: Combatant, my_index: int, opposing: Array, can_target_player: bool, delta: float) -> void:
	if not c.alive:
		c.respawn_time_remaining -= delta
		if c.respawn_time_remaining <= 0.0:
			var spawn_center := _friendly_spawn_center if c.faction == Combatant.Faction.FRIENDLY else _enemy_spawn_center
			_respawn_combatant(c, spawn_center)
		return

	_retarget_if_needed(c, my_index, opposing, can_target_player)

	var has_target := false
	var target_pos := Vector3.ZERO
	if c.targeting_player and _player:
		has_target = true
		target_pos = _player.global_position
	elif c.target_index >= 0 and c.target_index < opposing.size() and opposing[c.target_index].alive:
		has_target = true
		target_pos = opposing[c.target_index].position

	var desired_dir: Vector3 = (target_pos - c.position) if has_target else _wander_or_advance_direction(c)

	if desired_dir.length() > 0.01:
		var new_heading := c.heading.slerp(desired_dir.normalized(), clampf(TURN_RATE * delta, 0.0, 1.0))
		if new_heading.length() > 0.01:
			c.heading = new_heading.normalized()

	c.position += c.heading * c.speed * delta

	if _check_ground_or_building(c):
		_kill_combatant(c)
		return

	c.fire_cooldown -= delta
	if has_target and c.fire_cooldown <= 0.0 and c.position.distance_to(target_pos) <= ENGAGE_RANGE:
		c.fire_cooldown = randf_range(0.6, 1.4)
		if c.targeting_player:
			_fire_at_player(c, target_pos)
		else:
			_spawn_ambient_bolt(c, c.faction, target_pos)


func _retarget_if_needed(c: Combatant, my_index: int, opposing: Array, can_target_player: bool) -> void:
	var target_invalid := true
	if c.targeting_player:
		target_invalid = not _player
	elif c.target_index >= 0:
		target_invalid = c.target_index >= opposing.size() or not opposing[c.target_index].alive

	var is_stagger_turn := (my_index % RETARGET_STAGGER) == (_frame_counter % RETARGET_STAGGER)
	if not target_invalid and not is_stagger_turn:
		return

	var best_index := -1
	var best_dist := INF
	for j in opposing.size():
		var o: Combatant = opposing[j]
		if not o.alive:
			continue
		var d := c.position.distance_squared_to(o.position)
		if d < best_dist:
			best_dist = d
			best_index = j

	var use_player := false
	if can_target_player and _player:
		var pd := c.position.distance_squared_to(_player.global_position)
		if pd <= aggro_radius_player * aggro_radius_player and pd < best_dist:
			use_player = true

	if use_player:
		c.target_index = -1
		c.targeting_player = true
	elif best_index >= 0:
		c.target_index = best_index
		c.targeting_player = false
	else:
		c.target_index = -1
		c.targeting_player = false


## No opposing/player target in range: outside the dome, advance toward it
## ("both teams fly toward the city"); inside with nothing to fight, loiter
## around a slowly-refreshed random point within the dome rather than
## wandering back out — "AI wants to be in the dome always."
func _wander_or_advance_direction(c: Combatant) -> Vector3:
	var horiz := Vector2(c.position.x - dome_center.x, c.position.z - dome_center.z).length()
	if horiz > dome_radius:
		return Vector3(dome_center.x, c.position.y, dome_center.z) - c.position

	if c.position.distance_to(c.wander_point) < 300.0:
		c.wander_point = _random_point_in_dome()
	return c.wander_point - c.position


func _random_point_in_dome() -> Vector3:
	var angle := randf() * TAU
	var dist := randf_range(0.0, dome_radius * 0.8)
	var x := dome_center.x + cos(angle) * dist
	var z := dome_center.z + sin(angle) * dist
	var ground: float = _terrain.get_height_at(x, z) if _terrain else 0.0
	var altitude := randf_range(SPAWN_ALT_MIN, dome_ceiling * 0.7)
	return Vector3(x, ground + altitude, z)


func _check_ground_or_building(c: Combatant) -> bool:
	if _terrain:
		var ground_height: float = _terrain.get_height_at(c.position.x, c.position.z)
		if c.position.y <= ground_height:
			return true
	if enable_building_collision_check:
		if CrashEffects.check_building_collision(get_world_3d().direct_space_state, c.position):
			return true
	return false


func _respawn_combatant(c: Combatant, spawn_center: Vector3) -> void:
	var angle := randf() * TAU
	var dist := randf_range(0.0, SPAWN_SCATTER_RADIUS)
	var x := spawn_center.x + cos(angle) * dist
	var z := spawn_center.z + sin(angle) * dist
	var ground: float = _terrain.get_height_at(x, z) if _terrain else 0.0
	var altitude := randf_range(SPAWN_ALT_MIN, SPAWN_ALT_MAX)

	c.position = Vector3(x, ground + altitude, z)
	c.heading = (dome_center - c.position).normalized()
	c.wander_point = c.position + c.heading * 500.0
	c.health = MAX_HEALTH
	c.alive = true
	c.target_index = -1
	c.targeting_player = false
	c.fire_cooldown = randf_range(0.6, 1.4)
	c.respawn_time_remaining = RESPAWN_DELAY


func _kill_combatant(c: Combatant) -> void:
	c.alive = false
	c.target_index = -1
	c.targeting_player = false
	c.respawn_time_remaining = RESPAWN_DELAY
	CrashEffects.spawn_laser_impact(get_tree().current_scene, c.position)


# ---------------------------------------------------------------------------
# Bolts
# ---------------------------------------------------------------------------

func _fire_at_player(c: Combatant, target_pos: Vector3) -> void:
	var dir := (target_pos - c.position).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP

	var bolt := LASER_BOLT.instantiate()
	get_tree().current_scene.add_child(bolt)
	bolt.global_transform = Transform3D(Basis.looking_at(dir, up_ref), c.position)
	bolt.fired_by_player = false


func _spawn_ambient_bolt(c: Combatant, faction: int, target_pos: Vector3) -> void:
	if _ambient_bolts.size() >= max_ambient_bolts:
		return
	var dir := (target_pos - c.position).normalized()
	_ambient_bolts.append({
		"position": c.position,
		"velocity": dir * BOLT_SPEED,
		"faction": faction,
		"life": BOLT_LIFETIME,
	})


func _update_ambient_bolts(delta: float) -> void:
	var i := 0
	while i < _ambient_bolts.size():
		var b: Dictionary = _ambient_bolts[i]
		var prev_pos: Vector3 = b["position"]
		var new_pos: Vector3 = prev_pos + (b["velocity"] as Vector3) * delta
		b["position"] = new_pos
		b["life"] = (b["life"] as float) - delta

		var hit := _check_ambient_bolt_hit(b, prev_pos, new_pos)
		var expired: bool = (b["life"] as float) <= 0.0
		var hit_environment := false
		if not hit and not expired:
			hit_environment = _check_bolt_environment(new_pos)

		if hit or expired or hit_environment:
			var last := _ambient_bolts.size() - 1
			_ambient_bolts[i] = _ambient_bolts[last]
			_ambient_bolts.remove_at(last)
		else:
			i += 1


## Ambient bolt misses (terrain/building) despawn silently — no impact
## effect. At 100-200+ concurrent bolts, spawning CrashEffects.
## spawn_laser_impact()'s full Node3D+GPUParticles3D tree per miss would
## recreate the exact "hundreds of piling-up effects" problem that function
## was built to avoid, just at 10-40x the scale it was tuned for. The
## travelling bolts themselves are already the "lasers everywhere" visual;
## only kills (bounded by population size, not bolt volume) get an effect —
## see _kill_combatant().
func _check_bolt_environment(pos: Vector3) -> bool:
	if _terrain:
		var ground_height: float = _terrain.get_height_at(pos.x, pos.z)
		if pos.y <= ground_height:
			return true
	return CrashEffects.check_building_collision(get_world_3d().direct_space_state, pos)


func _check_ambient_bolt_hit(b: Dictionary, prev_pos: Vector3, new_pos: Vector3) -> bool:
	var owner_faction: int = b["faction"]
	var opposing: Array = _enemies if owner_faction == Combatant.Faction.FRIENDLY else _friendlies
	var grid: Dictionary = _enemy_grid if owner_faction == Combatant.Faction.FRIENDLY else _friendly_grid

	for idx in _grid_candidates(grid, new_pos):
		var o: Combatant = opposing[idx]
		if not o.alive:
			continue
		var closest := _closest_point_on_segment(o.position, prev_pos, new_pos)
		if closest.distance_to(o.position) <= BOLT_HIT_RADIUS:
			_apply_damage_internal(opposing, idx, BOLT_DAMAGE)
			return true
	return false


func _closest_point_on_segment(p: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return a
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return a + ab * t


func _rebuild_spatial_grids() -> void:
	_friendly_grid.clear()
	_enemy_grid.clear()
	_bucket_faction(_friendlies, _friendly_grid)
	_bucket_faction(_enemies, _enemy_grid)


func _bucket_faction(units: Array, grid: Dictionary) -> void:
	for i in units.size():
		var c: Combatant = units[i]
		if not c.alive:
			continue
		var key := Vector2i(int(floor(c.position.x / GRID_CELL_SIZE)), int(floor(c.position.z / GRID_CELL_SIZE)))
		if not grid.has(key):
			grid[key] = []
		(grid[key] as Array).append(i)


func _grid_candidates(grid: Dictionary, pos: Vector3) -> Array:
	var result: Array = []
	var cx := int(floor(pos.x / GRID_CELL_SIZE))
	var cz := int(floor(pos.z / GRID_CELL_SIZE))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := Vector2i(cx + dx, cz + dz)
			if grid.has(key):
				result.append_array(grid[key])
	return result


func _apply_damage_internal(units: Array, index: int, amount: float) -> void:
	var c: Combatant = units[index]
	if not c.alive:
		return
	c.health -= amount
	if c.health <= 0.0:
		_kill_combatant(c)


# ---------------------------------------------------------------------------
# Air Superiority / match state
# ---------------------------------------------------------------------------

func _update_match_timer(delta: float) -> void:
	match_time_remaining = maxf(0.0, match_time_remaining - delta)
	if match_time_remaining <= 0.0 and not game_over:
		_end_game()


func _update_air_superiority(delta: float) -> void:
	var friendly_in_dome := _count_in_dome(_friendlies)
	if _player and _is_in_dome(_player.global_position):
		friendly_in_dome += 1
	var enemy_in_dome := _count_in_dome(_enemies)

	var net_rate := float(friendly_in_dome - enemy_in_dome)
	air_superiority = clampf(air_superiority + net_rate * delta, -100.0, 100.0)

	if absf(air_superiority) >= 100.0 and not game_over:
		_end_game()


func _count_in_dome(units: Array) -> int:
	var count := 0
	for c in units:
		if (c as Combatant).alive and _is_in_dome((c as Combatant).position):
			count += 1
	return count


func _is_in_dome(pos: Vector3) -> bool:
	var horiz := Vector2(pos.x - dome_center.x, pos.z - dome_center.z).length()
	if horiz > dome_radius:
		return false
	var ground: float = _terrain.get_height_at(pos.x, pos.z) if _terrain else 0.0
	return (pos.y - ground) <= dome_ceiling


func _end_game() -> void:
	game_over = true
	if air_superiority > 0.0:
		winning_faction = Combatant.Faction.FRIENDLY
	elif air_superiority < 0.0:
		winning_faction = Combatant.Faction.ENEMY
	else:
		winning_faction = -1


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _write_multimesh_transforms() -> void:
	for i in _friendlies.size():
		_friendly_mmi.multimesh.set_instance_transform(i, _combatant_transform(_friendlies[i]))
	for i in _enemies.size():
		_enemy_mmi.multimesh.set_instance_transform(i, _combatant_transform(_enemies[i]))

	_bolt_mmi.multimesh.visible_instance_count = _ambient_bolts.size()
	for i in _ambient_bolts.size():
		_bolt_mmi.multimesh.set_instance_transform(i, _bolt_transform(_ambient_bolts[i]))


## Dead combatants are scaled to zero rather than removed from the array
## (their slot is reused on respawn) — MultiMesh has no per-instance
## visibility flag other than trimming the buffer's tail via
## visible_instance_count, which can't hide an arbitrary middle index.
func _combatant_transform(c: Combatant) -> Transform3D:
	if not c.alive:
		return Transform3D(Basis().scaled(Vector3.ZERO), c.position)
	var up_ref := Vector3.FORWARD if absf(c.heading.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var basis := Basis.looking_at(c.heading, up_ref).scaled(Vector3(SHIP_SCALE, SHIP_SCALE, SHIP_SCALE))
	return Transform3D(basis, c.position)


## LaserBolt.tscn's own mesh child carries a fixed -90 deg X rotation
## (its CylinderMesh's long axis is Y by default; the bolt travels along
## -Z), baked in here too so the pooled ambient bolts match the player's
## bolt visually.
func _bolt_transform(b: Dictionary) -> Transform3D:
	var dir: Vector3 = (b["velocity"] as Vector3).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var mesh_correction := Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	return Transform3D(Basis.looking_at(dir, up_ref) * mesh_correction, b["position"] as Vector3)


# ---------------------------------------------------------------------------
# Public API — laser_bolt.gd (player shooting aliens) / target_lock.gd
# ---------------------------------------------------------------------------

func get_nearest_alive_alien(from_position: Vector3) -> int:
	var best_index := -1
	var best_dist := INF
	for i in _enemies.size():
		var c: Combatant = _enemies[i]
		if not c.alive:
			continue
		var d := from_position.distance_squared_to(c.position)
		if d < best_dist:
			best_dist = d
			best_index = i
	return best_index


func is_alive(index: int) -> bool:
	return index >= 0 and index < _enemies.size() and _enemies[index].alive


func get_alien_position(index: int) -> Vector3:
	if index < 0 or index >= _enemies.size():
		return Vector3.ZERO
	return _enemies[index].position


func get_velocity(index: int) -> Vector3:
	if index < 0 or index >= _enemies.size():
		return Vector3.ZERO
	var c: Combatant = _enemies[index]
	return c.heading * c.speed


func apply_damage(index: int, amount: float) -> void:
	if index < 0 or index >= _enemies.size():
		return
	_apply_damage_internal(_enemies, index, amount)
