extends Node3D

## Alien invasion: two fleets of squadrons fighting for control of the city,
## plus the player. Replaces the old single wandering HOSTILE-1
## (enemy_ai.gd/EnemyShip.tscn, left on disk unused, same convention as the
## retired map editor).
##
## ARCHITECTURE — one manager, not hundreds of nodes. Individual
## Node3D+script instances (the old enemy_ai.gd pattern) would mean that
## per-instance overhead multiplied by the whole population. Instead every
## combatant is a lightweight Combatant (RefCounted, see combatant.gd) held
## in a plain Array, grouped into Squads (RefCounted too, see squad.gd), and
## this single script updates all of them in tight loops every
## _physics_process, then writes the results into two MultiMeshInstance3D
## (one per faction, GPU-instanced — the same technique city_generator.gd
## already uses for its ~1200 street tiles) instead of one draw call per
## ship.
##
## SQUADS, not one big cloud. The first version had every ship independently
## spawn in one cluster and fly at one shared dome_center, which produced
## exactly what it sounds like: two enormous undifferentiated packs. Now the
## population is cut into squads of 1-5 (SQUAD_SIZE_MIN/MAX), each with its
## OWN spawn point spread along a wide front, its OWN objective inside the
## dome, formation-keeping on a leader, focus fire on the leader's target,
## and its own morale state. Combined with the separation steering below,
## that's what breaks the fleet up into readable individual fights.
##
## AI BEHAVIOURS, modelled on how modern combat-flight AI actually reads:
##   * FORMATION — wingmen hold a station offset from their leader, with a
##     throttle that speeds up/slows down to close on that station instead
##     of flying at one fixed speed (which strings a squad out or piles it
##     up).
##   * PURSUE — run in on a target using a real lead/intercept solution
##     (_lead_point), not a straight chase of where the target is *now*.
##   * BREAK_OFF — after closing inside BREAK_OFF_RANGE, the attacker flies
##     THROUGH and past its target for a couple of seconds before turning
##     back, instead of gluing itself to the target's tail forever. This is
##     the single biggest readability win: fights become a series of
##     recognisable passes rather than two dots stuck together.
##   * RETREAT — a hurt pilot (health under RETREAT_HEALTH_FRACTION) may
##     break off entirely; a squad that has lost enough of its members
##     (Squad.losses) breaks off as a unit, runs to a rally point, REGROUPs
##     and comes back. "They may pull off if they are hurt, or if too many
##     of their squad mates die."
##   * SEPARATION — every ship pushes away from nearby friendly ships, which
##     is what actually stops squads from collapsing into a single point.
##   * Reaction delay + per-pilot accuracy — ships don't fire the instant
##     they acquire (Combatant.reaction_timer), and their aim is displaced
##     from the true firing solution by an amount scaled by their own
##     `accuracy` and the range. This is the "threatening but not unfair"
##     knob.
##
## AIR SUPERIORITY — an invisible cylindrical "dome" over the city
## (city_center, dome_radius horizontally, dome_ceiling above terrain).
## Every physics frame, each side's count of living ships currently inside
## the dome (the player counts as one friendly) nets against the other:
## air_superiority += (friendly_in_dome - enemy_in_dome) * delta * the
## as_generation_multiplier, clamped to [-100, 100] — one enemy in the dome
## cancels one friendly's contribution, exactly 1-for-1. Either side hitting
## +/-100, or the 10-minute match timer expiring (higher AS wins), ends it.
##
## BOLTS are two separate systems. Ambient unit-vs-unit fire ("lasers
## everywhere") uses a pooled, non-Node bolt array (Dictionaries), rendered
## via a third MultiMeshInstance3D, hit-checked with the same closest-point-
## on-segment swept test laser_bolt.gd already uses (a plain point/distance
## check would let bolts tunnel through targets — this project already fixed
## that bug once for the player's own bolts). Hit checks are spatially
## bucketed into a per-frame grid keyed by city_generator.gd's own
## block_pitch (450m cells) — unstaggered bolt-vs-unit checks are the single
## biggest CPU cost in this system, dwarfing retargeting, so they're the one
## thing that gets bucketed instead of staggered (a bolt's hit check can't
## skip frames without reintroducing tunneling). Aliens shooting AT THE
## PLAYER specifically instead reuse the existing
## LaserBolt.tscn/laser_bolt.gd Node-based system (fired_by_player=false) —
## low volume by construction (aggro-gated), and it's what feeds
## player_damage.gd's already-built hit path.
##
## SPAWN-TIME PROPERTY GOTCHA (a real bug this cost us): add_child() runs the
## child's _ready() immediately, so any exported/plain property a scene's
## _ready() reads MUST be assigned BEFORE add_child(), not after. Both
## _fire_at_player() and _fire_missile_at_player() originally set
## `fired_by_player = false` / `target_is_player = true` after add_child,
## so those scripts' _ready() saw the defaults, never resolved their player
## references, and the player could not be damaged by aliens AT ALL — while
## still hearing the missile's own impact sound, which is exactly what
## "I hear the hull taking hits but I'm not getting hurt" was.
##
## EFFECT BUDGETS. Now that the AI actually fights, kills happen constantly,
## and every kill used to spawn an unconditional ShipExplosion (a particle
## tree plus a 6000m-range OmniLight3D). At battle scale that is a real
## frame-budget problem, so kill effects are now budgeted three ways: a hard
## cap on concurrent explosions, no light beyond explosion_light_range, and
## nothing at all beyond explosion_cull_range. Battle audio is budgeted the
## same way — see _play_battle_sound().
##
## The PLAYER's own weapon damages aliens through this manager too —
## laser_bolt.gd's _check_enemy_hit() calls get_nearest_alive_alien() /
## apply_damage() below. Friendlies are a structurally separate array the
## player-facing API never touches, so they can never be targeted or damaged
## — not an explicit exclusion check, just a consequence of the split.

const LASER_BOLT := preload("res://scenes/LaserBolt.tscn")
const SHIP_EXPLOSION := preload("res://scenes/ShipExplosion.tscn")
const FLARE := preload("res://scenes/Flare.tscn")
const MISSILE := preload("res://scenes/Missile.tscn")
const HIT_SPARK := preload("res://scenes/HitSpark.tscn")
const BATTLE_EXPLOSION_SOUND := preload("res://Assets/Audio/battle_explosion.mp3")
const BATTLE_LASER_SOUND := preload("res://Assets/Audio/battle_laser.mp3")

const SHIP_MESH_PATH := "res://Assets/EnemyShip/ship1.obj"
const SHIP_SCALE := 2.0  # matches EnemyShip.tscn / Player.tscn's ShipHull

const MAX_HEALTH := 30.0  # ~3 player hits (10 dmg/bolt) to kill — visible, not one-shot
const BOLT_DAMAGE := 10.0

## Dropped from 900 m/s. At 900 an ambient bolt crossed a whole engagement
## in a couple of frames — individually invisible, so a battle of hundreds
## of simultaneous shots read as nothing at all. Slower + much longer/
## brighter bolt geometry (see _build_multimesh_nodes) is what turns the
## fighting into something you can actually watch from a distance. It also
## means the AI's lead/intercept solution has real work to do.
const BOLT_SPEED := 520.0
const BOLT_LIFETIME := 3.0
const BOLT_HIT_RADIUS := 6.0  # a little wider than laser_bolt.gd's, since ambient bolts are bucketed one frame stale

const MISSILE_ENGAGE_RANGE := 2500.0  # longer stand-off than ENGAGE_RANGE — missiles are a real threat, not routine
const MISSILE_COOLDOWN_MIN := 15.0
const MISSILE_COOLDOWN_MAX := 30.0

const RETARGET_STAGGER := 8
## Bolt-hit / separation spatial-hash cell size. Originally chosen to match
## city_generator.gd's `block_pitch`; that has since dropped to 360m for
## density, and this is deliberately NOT following it — 450m is a good cell
## size for this workload on its own, and there's no requirement that the
## two agree.
const GRID_CELL_SIZE := 450.0
const ENGAGE_RANGE := 800.0  # inside this a pilot will actually shoot
const MAX_ACQUISITION_RANGE := 3000.0  # targets beyond this aren't acquired at all — see _retarget_if_needed
const FIRE_CONE := deg_to_rad(14.0)  # must have the target roughly ahead, not abeam, to fire
const MIN_GROUND_CLEARANCE := 200.0  # meters; pull up if under this, same convention as enemy_ai.gd
const LOOKAHEAD_TIME := 3.0  # seconds ahead to also check clearance for
const LOOKAHEAD_STAGGER := 4  # only 1/4 of the population re-runs the lookahead terrain sample per frame
const RESPAWN_DELAY := 8.0

## PERFORMANCE GATES. The physics building point-query and the terrain
## sampler are called per ship AND per bolt, every frame, which at battle
## scale was measured (headless, 100v100) at ~8ms of physics per frame on
## its own — more than an entire 90Hz VR frame budget, and the most likely
## explanation for the live FPS collapse this project has been chasing.
##
## Anything flying more than MAX_BUILDING_HEIGHT above the terrain
## underneath it cannot possibly be intersecting a building, so the physics
## query is skipped outright. The ground height is already sampled for the
## terrain check, so the gate itself is free.
##
## MUST STAY ABOVE THE TALLEST BUILDING city_generator.gd can produce, or
## ships and bolts silently pass through the tops of towers. That is
## `LANDMARK_BUILDINGS` base height (~125m) * `landmark_scale_max` (5.0) *
## `height_multiplier` (2.0) = ~1250m, hence 1400m with margin. This value
## was 700m while buildings were half their current height — if the city's
## height settings change again, this has to move with them.
const MAX_BUILDING_HEIGHT := 2000.0

## Air Superiority is a slow scalar (as_generation_multiplier is 0.01) and
## counting every ship in the dome costs a terrain sample each. Recomputing
## it 60x/second was pure waste, so it runs every AS_UPDATE_INTERVAL frames
## and integrates the accumulated delta — mathematically identical, ~6x
## fewer samples.
const AS_UPDATE_INTERVAL := 6

## Squadron organisation.
const SQUAD_SIZE_MIN := 1
const SQUAD_SIZE_MAX := 5
const FORMATION_SPACING := 75.0  # meters between formation stations
const FORMATION_SPEED_GAIN := 0.45  # how hard a wingman throttles to close on its station

## Attack-run shaping.
const BREAK_OFF_RANGE := 140.0  # closing inside this ends the run — fly through, then turn back
const BREAK_OFF_TIME_MIN := 1.8
const BREAK_OFF_TIME_MAX := 3.4
const REACTION_TIME_MIN := 0.35
const REACTION_TIME_MAX := 1.1
const AIM_ERROR_SCALE := 0.055  # aim offset = (1 - accuracy) * range * this

## Morale.
const RETREAT_HEALTH_FRACTION := 0.35
const RETREAT_ROLL_CHANCE := 0.55  # a hurt pilot only sometimes breaks — not every one, every time
const RETREAT_TIME_MIN := 7.0
const RETREAT_TIME_MAX := 14.0
const SQUAD_RETREAT_TIME := 14.0
const SQUAD_REGROUP_TIME := 10.0

## Separation — the actual fix for "the AI clusters together in huge packs".
const SEPARATION_RADIUS := 130.0
const SEPARATION_WEIGHT := 2.2
const MAX_SEPARATION_NEIGHBORS := 6

const SPAWN_ALT_MIN := 300.0
const SPAWN_ALT_MAX := 1400.0

## Motherships — one stationary capital ship per faction, hovering at that
## faction's spawn point. Every ship starts the match parked on its deck and
## launches off the top of it, and dead ships respawn back onto it.
const MOTHERSHIP := preload("res://scenes/MotherShip.tscn")
const LAUNCH_CLEAR_HEIGHT := 420.0  # meters above the deck before a launching ship resumes normal flight
const LAUNCH_CLIMB_BIAS := 2.6  # how hard a launching ship prioritises "up" over "toward the objective"
## Squads leave the deck in waves. The whole fleet lifting simultaneously
## looks like a swarm rather than a carrier launch, and dumps the entire
## population into one volume of air at once — which the separation steering
## then has to fight. Staggering also spreads the spawn cost over ~30s.
const LAUNCH_WAVE_INTERVAL := 0.85  # seconds between squads at match start
const LAUNCH_RESPAWN_DELAY_MAX := 2.5  # mid-match respawns don't queue behind the whole fleet

const FRIENDLY_COLOR := Color(0.25, 0.65, 1.0)
const ENEMY_COLOR := Color(0.85, 0.1, 0.85)
const FRIENDLY_BOLT_COLOR := Color(0.35, 0.8, 1.0)
const ENEMY_BOLT_COLOR := Color(1.0, 0.25, 0.15)

const KILL_FEED_MAX_ENTRIES := 6
const KILL_FEED_ENTRY_LIFETIME := 8.0

## The SAME performance definition the player's own ship flies by (see
## flight_controller.gd, scripts/omega_motion.gd and
## docs/omega-flight-model.md). Every combatant's cruise speed, throttle
## response and turn rate is derived from this resource, so "the player
## flies the same ship as the AI" holds in code — retuning
## standard_fighter.tres retunes the player and all 200 ships together
## instead of letting the two drift apart, which is exactly what had
## happened before (the AI cruised at 140-210 m/s against the player's 300,
## and turned at an unbounded slerp rate with no relation to the player's
## pitch/yaw limit).
@export var flight_profile: ShipFlightProfile = preload("res://Assets/ShipProfiles/standard_fighter.tres")

@export var friendly_count: int = 100
@export var enemy_count: int = 100
@export var dome_radius: float = 8000.0  # covers the city's ~7637m corner-to-corner footprint
@export var dome_ceiling: float = 3500.0  # above terrain
@export var match_duration: float = 600.0  # 10 minutes
@export var aggro_radius_player: float = 2500.0
@export var max_ambient_bolts: int = 320  # raised with the slower bolts — they live longer on screen
@export var enable_building_collision_check: bool = true
@export var as_generation_multiplier: float = 0.01

## How many aliens may hunt the player at once. An "attacker cap" is a
## standard modern-combat-AI pacing device: without it, every alien inside
## aggro_radius_player converges on the player at the same time and the
## fight stops being winnable or readable.
@export var max_aliens_targeting_player: int = 3

## The player is weighted as if this much closer than it really is when an
## alien picks a target, so the player actually gets hunted instead of
## always losing out to whichever friendly ship happens to be marginally
## nearer (the player flies with the friendly fleet, so that was almost
## always the case).
@export var player_target_bias: float = 0.55

@export_group("Effect budget")
@export var max_concurrent_explosions: int = 14
@export var explosion_light_range: float = 4000.0  # past this, the kill fireball spawns without its OmniLight3D
@export var explosion_cull_range: float = 15000.0  # past this, no kill effect at all
@export var max_concurrent_sparks: int = 10
@export var spark_range: float = 2500.0  # non-lethal hit sparks only spawn this close to the player
@export var max_battle_sounds: int = 12
@export var explosion_sound_range: float = 7000.0
@export var laser_sound_range: float = 1500.0
@export_group("Motherships")
## Length in meters. The mesh is normalised so this IS the length — width
## and deck height are fixed ratios of it (see mothership.gd). 2000m makes
## it read as a capital ship against a city whose tallest towers are ~625m.
## Unverified in VR, like every other asset scale in this project.
@export var mothership_length: float = 4000.0
## Height of the mothership's underside above the terrain below it.
@export var mothership_altitude: float = 3000.0
## How far out from dome_center each faction's mothership (and therefore its
## whole fleet, since everything launches from the deck) sits. Raising this
## lengthens the opening transit — roughly 6 seconds per extra 1000m at
## cruise — before the fleets meet. At 22000m that opening approach is
## multiple minutes long; see the measured figures in CLAUDE.md.
@export var spawn_distance_from_city: float = 22000.0
@export var laser_sound_chance: float = 0.07  # only this fraction of nearby shots get a sound — the rest would be a wall of noise

## Live status, readable by battle_hud.gd / target_lock.gd / enemy_locator.gd.
var air_superiority: float = 0.0  # -100 (enemy control) .. +100 (friendly control)
var match_time_remaining: float = 0.0
var game_over: bool = false
var winning_faction: int = -1  # Combatant.Faction.FRIENDLY/ENEMY, or -1 for a draw
var dome_center: Vector3 = Vector3(6000.0, 0.0, 0.0)

## Gated by game_flow.gd — false until the player confirms the start menu,
## so ships spawn and sit visibly (frozen) rather than fighting/scoring
## before the match has actually begun.
var simulation_active: bool = false

## Pre-joined recent-kills text ("who died and how"), read directly by
## kill_feed_hud.gd — see _add_kill_feed_entry()/_update_kill_feed().
var kill_feed_text: String = ""

var _kill_feed_entries: Array = []  # Array of {"text": String, "age": float}

var _friendlies: Array[Combatant] = []
var _enemies: Array[Combatant] = []
var _friendly_squads: Array[Squad] = []
var _enemy_squads: Array[Squad] = []
var _ambient_bolts: Array[Dictionary] = []
var _friendly_grid: Dictionary = {}
var _enemy_grid: Dictionary = {}
var _frame_counter: int = 0
var _aliens_on_player: int = 0
var _as_accumulated_delta: float = 0.0

var _friendly_spawn_center: Vector3
var _enemy_spawn_center: Vector3

var _terrain: Node
var _player: Node3D

var _friendly_mmi: MultiMeshInstance3D
var _enemy_mmi: MultiMeshInstance3D
var _bolt_mmi: MultiMeshInstance3D

var _friendly_mothership: Node3D
var _enemy_mothership: Node3D

var _live_explosions: Array = []
var _live_sounds: Array = []
var _live_sparks: Array = []


func _ready() -> void:
	randomize()
	_terrain = get_node_or_null("../Terrain")
	_player = get_tree().current_scene.get_node_or_null("Player")

	var city := get_node_or_null("../City")
	if city and "city_center" in city:
		dome_center = city.city_center

	_friendly_spawn_center = dome_center + Vector3(-spawn_distance_from_city, 0.0, 0.0)
	_enemy_spawn_center = dome_center + Vector3(spawn_distance_from_city, 0.0, 0.0)
	match_time_remaining = match_duration

	_build_multimesh_nodes()
	_build_motherships()
	_spawn_faction(_friendlies, friendly_count, Combatant.Faction.FRIENDLY)
	_spawn_faction(_enemies, enemy_count, Combatant.Faction.ENEMY)
	_build_squads(_friendlies, _friendly_squads, Combatant.Faction.FRIENDLY, _friendly_spawn_center)
	_build_squads(_enemies, _enemy_squads, Combatant.Faction.ENEMY, _enemy_spawn_center)
	_place_all_at_spawn()

	_friendly_mmi.multimesh.instance_count = friendly_count
	_enemy_mmi.multimesh.instance_count = enemy_count


func _physics_process(delta: float) -> void:
	if simulation_active and not game_over:
		_update_match_timer(delta)

		# Grids are rebuilt at the TOP of the frame so separation steering
		# below can use them. Only the bucketing is a frame stale by the time
		# the bolt checks run (positions themselves are read live), and at
		# 450m cells a frame of movement can't move anything meaningfully
		# between buckets.
		_rebuild_spatial_grids()
		_aliens_on_player = 0

		for sq in _friendly_squads:
			_update_squad(sq, _friendlies, delta)
		for sq in _enemy_squads:
			_update_squad(sq, _enemies, delta)

		for i in _friendlies.size():
			_update_combatant(_friendlies[i], i, _enemies, _friendlies, _friendly_grid, _friendly_squads, false, delta)
		for i in _enemies.size():
			_update_combatant(_enemies[i], i, _friendlies, _enemies, _enemy_grid, _enemy_squads, true, delta)

		_update_ambient_bolts(delta)
		_update_air_superiority(delta)
		_update_kill_feed(delta)
		_frame_counter += 1

	# Always write transforms, even while paused (pre-match menu / post-match
	# summary) — ships stay visibly present, just frozen, instead of vanishing
	# because their MultiMesh instances were never given a transform.
	_write_multimesh_transforms()


## Called by game_flow.gd once the player confirms the start menu.
func start_battle() -> void:
	simulation_active = true


## Called by game_flow.gd on "return to main menu" — puts the battle back
## in its pre-match state (everyone alive and repositioned, AS/timer reset)
## without a real scene reload.
func reset_battle() -> void:
	simulation_active = false
	game_over = false
	winning_faction = -1
	air_superiority = 0.0
	match_time_remaining = match_duration
	_ambient_bolts.clear()
	_kill_feed_entries.clear()
	kill_feed_text = ""
	for sq in _friendly_squads:
		_reset_squad(sq)
	for sq in _enemy_squads:
		_reset_squad(sq)
	_place_all_at_spawn()


# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

func _build_multimesh_nodes() -> void:
	var ship_mesh: Mesh = load(SHIP_MESH_PATH)
	_friendly_mmi = _make_ship_multimesh(ship_mesh, FRIENDLY_COLOR)
	_enemy_mmi = _make_ship_multimesh(ship_mesh, ENEMY_COLOR)

	# Long and fat compared to the player's own bolt. These are being viewed
	# from hundreds or thousands of meters away across a whole battle, where
	# the original 2.5m x 0.06m sliver was far below one pixel. Vertex colour
	# carries the per-bolt faction tint (see _bolt_transform / set_instance_color).
	var bolt_mesh := CylinderMesh.new()
	bolt_mesh.top_radius = 0.15
	bolt_mesh.bottom_radius = 0.55
	bolt_mesh.height = 26.0
	bolt_mesh.radial_segments = 6

	var bolt_mat := StandardMaterial3D.new()
	bolt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bolt_mat.vertex_color_use_as_albedo = true
	bolt_mat.albedo_color = Color(1.0, 1.0, 1.0, 1.0)
	bolt_mat.emission_enabled = true
	bolt_mat.emission = Color(1.0, 1.0, 1.0, 1.0)
	bolt_mat.emission_energy_multiplier = 6.0

	_bolt_mmi = MultiMeshInstance3D.new()
	# Bolts are unshaded emissive tracers — a shadow from one would be both
	# wrong and a per-frame cost on hundreds of moving instances.
	_bolt_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_bolt_mmi)
	var bolt_multimesh := MultiMesh.new()
	bolt_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	bolt_multimesh.use_colors = true
	bolt_multimesh.mesh = bolt_mesh
	bolt_multimesh.instance_count = max_ambient_bolts
	bolt_multimesh.visible_instance_count = 0
	_bolt_mmi.multimesh = bolt_multimesh
	_bolt_mmi.material_override = bolt_mat


## One stationary capital ship per faction, hovering at that faction's spawn
## point. Built here rather than placed in Town.tscn so the visual and the
## spawn logic can never drift apart — this project already carries a
## documented multi-place coupling for the player's own spawn coordinate and
## does not need another one.
func _build_motherships() -> void:
	_friendly_mothership = _make_mothership(_friendly_spawn_center, FRIENDLY_COLOR)
	_enemy_mothership = _make_mothership(_enemy_spawn_center, ENEMY_COLOR)


func _make_mothership(at_xz: Vector3, tint: Color) -> Node3D:
	var ship := MOTHERSHIP.instantiate()
	# Assigned before add_child(), since mothership.gd's _ready() applies
	# both of these — the same ordering rule documented in this file's header.
	ship.length = mothership_length
	ship.tint = tint
	add_child(ship)
	var ground: float = _terrain.get_height_at(at_xz.x, at_xz.z) if _terrain else 0.0
	ship.global_position = Vector3(at_xz.x, ground + mothership_altitude, at_xz.z)
	return ship


func _mothership_for(faction: int) -> Node3D:
	return _friendly_mothership if faction == Combatant.Faction.FRIENDLY else _enemy_mothership


func _make_ship_multimesh(mesh: Mesh, tint: Color) -> MultiMeshInstance3D:
	var mmi := MultiMeshInstance3D.new()
	# 200 small, fast-moving ships would re-render into the shadow map every
	# frame for shadows that are a few pixels across from any distance the
	# player actually sees them at. Not worth the pass.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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


func _spawn_faction(target: Array, count: int, faction: int) -> void:
	for i in count:
		var c := Combatant.new()
		c.faction = faction
		# Cruise as a FRACTION of the shared profile's top speed, so raising
		# the ship's performance carries the whole fleet with it rather than
		# leaving the AI behind at stale absolute numbers.
		c.base_speed = randf_range(
				flight_profile.ai_cruise_fraction_min,
				flight_profile.ai_cruise_fraction_max) * flight_profile.max_forward_speed
		c.speed = c.base_speed
		c.accuracy = randf_range(0.55, 0.95)
		c.health = MAX_HEALTH
		c.alive = true
		target.append(c)


## Cuts a faction's flat array into squads of 1-5, each with its own spawn
## point along a wide front and its own objective inside the dome. Squad
## membership is fixed for the whole match — a dead member respawns back
## into the same slot, matching the MultiMesh instance buffer's fixed
## indexing.
func _build_squads(units: Array, squads: Array[Squad], faction: int, base_center: Vector3) -> void:
	var i := 0
	while i < units.size():
		var size: int = mini(randi_range(SQUAD_SIZE_MIN, SQUAD_SIZE_MAX), units.size() - i)
		var sq := Squad.new()
		sq.faction = faction
		sq.spawn_center = base_center
		sq.objective = _random_point_in_dome()
		sq.rally_point = _make_rally_point(base_center)
		for k in size:
			var idx: int = i + k
			var c: Combatant = units[idx]
			c.squad_id = squads.size()
			c.squad_slot = k
			sq.members.append(idx)
		sq.leader = sq.members[0]
		squads.append(sq)
		i += size


## Parks the whole fleet on its mothership's deck, in launch order. Squads
## previously spawned scattered over a 7km front, which was the original fix
## for "the AI clusters in huge packs" — that spread is now provided instead
## by the launch waves (squads leave one at a time), each squad's own
## objective inside the dome, and the separation steering, none of which
## depend on where they started.
func _place_all_at_spawn() -> void:
	_park_faction(_friendlies, _friendly_squads)
	_park_faction(_enemies, _enemy_squads)


func _park_faction(units: Array, squads: Array[Squad]) -> void:
	for s in squads.size():
		var sq: Squad = squads[s]
		for idx in sq.members:
			var c: Combatant = units[idx]
			_respawn_combatant(c, sq)
			c.respawn_time_remaining = 0.0
			# Launch order runs down the deck, so the fleet leaves in a
			# readable procession instead of a scramble.
			c.launch_delay = float(s) * LAUNCH_WAVE_INTERVAL + randf_range(0.0, 0.4)


func _reset_squad(sq: Squad) -> void:
	sq.state = Squad.State.ADVANCE
	sq.state_timer = 0.0
	sq.losses = 0
	sq.focus_target = -1
	sq.focus_is_player = false
	sq.objective = _random_point_in_dome()
	sq.rally_point = _make_rally_point(sq.spawn_center)
	sq.leader = sq.members[0] if not sq.members.is_empty() else -1


# ---------------------------------------------------------------------------
# Squad-level orders
# ---------------------------------------------------------------------------

func _update_squad(sq: Squad, units: Array, delta: float) -> void:
	sq.state_timer -= delta

	# Leadership succession — a squad whose leader is dead has no formation
	# anchor, so promote the first living member.
	var leader: Combatant = units[sq.leader] if sq.leader >= 0 else null
	if leader == null or not leader.alive:
		sq.leader = -1
		for idx in sq.members:
			if (units[idx] as Combatant).alive:
				sq.leader = idx
				break
		if sq.leader < 0:
			return
		leader = units[sq.leader]

	# The leader's target becomes the squad's focus, so wingmen concentrate
	# on one ship instead of each independently chasing its own nearest.
	sq.focus_target = leader.target_index
	sq.focus_is_player = leader.targeting_player

	match sq.state:
		Squad.State.ADVANCE:
			if leader.position.distance_to(sq.objective) < 600.0:
				sq.objective = _random_point_in_dome()
			if sq.focus_target >= 0 or sq.focus_is_player:
				sq.state = Squad.State.ENGAGE
		Squad.State.ENGAGE:
			if sq.losses >= _squad_break_threshold(sq):
				sq.state = Squad.State.RETREAT
				sq.state_timer = SQUAD_RETREAT_TIME
			elif sq.focus_target < 0 and not sq.focus_is_player:
				sq.state = Squad.State.ADVANCE
		Squad.State.RETREAT:
			if sq.state_timer <= 0.0:
				sq.state = Squad.State.REGROUP
				sq.state_timer = SQUAD_REGROUP_TIME
		Squad.State.REGROUP:
			if sq.state_timer <= 0.0:
				sq.losses = 0
				sq.objective = _random_point_in_dome()
				sq.state = Squad.State.ADVANCE


## Half the squad (rounded up) is what it takes to break them. A single-ship
## "squad" is governed by its own health instead — it's dead before this
## could ever fire.
func _squad_break_threshold(sq: Squad) -> int:
	return maxi(1, ceili(float(sq.members.size()) * 0.5))


## Somewhere back toward the squad's own side of the map, well away from the
## dome — where a broken squad runs to before re-forming. Assigned ONCE per
## squad at build time and never recomputed.
##
## Each squad gets its own point, spread widely across its side of the map.
## This matters more than it looks: every squad in a faction used to derive
## its rally point from `spawn_center`, which was fine while squads spawned
## scattered across a 7000m front, but became a real bug when the
## motherships took over spawning and every squad's `spawn_center` became
## the same single point. Every retreating squad then ran to the *identical*
## location — and with a dozen squads typically in RETREAT at once, that is
## a large, permanent pack forming off to one side. It was the AI "grouping
## again" after the mothership change.
func _make_rally_point(base_center: Vector3) -> Vector3:
	var away := base_center - dome_center
	away.y = 0.0
	if away.length() < 1.0:
		away = Vector3.RIGHT * 1000.0
	away = away.normalized()
	# Lateral spread perpendicular to the away-from-city axis, so squads
	# rally along a broad line rather than at a single dot.
	var lateral := away.cross(Vector3.UP).normalized()
	var base := dome_center + away * (dome_radius + randf_range(2000.0, 5000.0))
	return base \
			+ lateral * randf_range(-6000.0, 6000.0) \
			+ Vector3(0.0, randf_range(900.0, 2400.0), 0.0)


# ---------------------------------------------------------------------------
# Per-combatant update
# ---------------------------------------------------------------------------

func _update_combatant(c: Combatant, my_index: int, opposing: Array, own_units: Array,
		own_grid: Dictionary, squads: Array[Squad], can_target_player: bool, delta: float) -> void:
	if not c.alive:
		c.respawn_time_remaining -= delta
		if c.respawn_time_remaining <= 0.0:
			_respawn_combatant(c, squads[c.squad_id])
		return

	c.state_timer -= delta
	c.reaction_timer -= delta

	var sq: Squad = squads[c.squad_id]

	# Parked on the mothership deck, waiting for its launch slot. Doesn't
	# move, steer, retarget or shoot — it's sitting on a flight deck.
	if c.state == Combatant.State.PARKED:
		c.launch_delay -= delta
		if c.launch_delay <= 0.0:
			c.state = Combatant.State.LAUNCHING
			c.speed = c.base_speed * 0.5  # rolls off the deck rather than leaving at cruise
		return

	# Sampled once and reused by both the ground-avoidance test and the
	# terrain/building crash test below — they used to sample independently.
	var ground_here: float = _terrain.get_height_at(c.position.x, c.position.z) if _terrain else 0.0
	_retarget_if_needed(c, my_index, opposing, sq, can_target_player)

	var has_target := false
	var target_pos := Vector3.ZERO
	var target_vel := Vector3.ZERO
	if c.targeting_player and _player:
		has_target = true
		target_pos = _player.global_position
	elif c.target_index >= 0 and c.target_index < opposing.size() and (opposing[c.target_index] as Combatant).alive:
		has_target = true
		var t: Combatant = opposing[c.target_index]
		target_pos = t.position
		target_vel = t.heading * t.speed

	_update_pilot_state(c, sq, has_target, target_pos)

	var desired_dir := _steering_direction(c, sq, own_units, has_target, target_pos, target_vel)
	desired_dir += _separation(c, own_units, own_grid) * SEPARATION_WEIGHT

	# Ground avoidance overrides everything else when low or about to be low —
	# same reactive-pull-up pattern enemy_ai.gd used. Ships fly a straight
	# line at a fixed altitude offset from their own spawn point's ground
	# height, and this map's mountains reach into the thousands of meters, so
	# flying level is not automatically safe here.
	if _needs_pull_up(c, my_index, ground_here):
		var level_forward := desired_dir if desired_dir.length() > 0.01 else c.heading
		desired_dir = level_forward.normalized() + Vector3.UP * 1.5

	_turn_toward(c, desired_dir, delta)

	_update_throttle(c, sq, own_units, has_target, target_pos, delta)
	c.position += c.heading * c.speed * delta

	if _check_ground_or_building(c, ground_here):
		_kill_combatant(c, my_index, sq, "crashed")
		return

	c.fire_cooldown -= delta
	if has_target and c.state != Combatant.State.RETREAT and c.state != Combatant.State.LAUNCHING \
			and c.reaction_timer <= 0.0 and c.fire_cooldown <= 0.0:
		_try_fire(c, my_index, target_pos, target_vel)

	# Rare, longer-range, longer-cooldown missile shot at the player
	# specifically — independent of the ambient laser cooldown above, so a
	# player-targeting alien fires both its routine lasers and, much less
	# often, an actual homing missile (see missile.gd's target_is_player
	# mode). This is what gives flare_system.gd's X button a real target.
	c.missile_cooldown -= delta
	if c.targeting_player and c.state != Combatant.State.RETREAT and c.missile_cooldown <= 0.0 \
			and c.position.distance_to(target_pos) <= MISSILE_ENGAGE_RANGE:
		c.missile_cooldown = randf_range(MISSILE_COOLDOWN_MIN, MISSILE_COOLDOWN_MAX)
		_fire_missile_at_player(c, target_pos)


## Rotates a ship's nose toward `desired_dir` under the SAME bounded turn
## rate the player's ship obeys (flight_profile.ai_turn_max_rate, which is
## the profile's real pitch/yaw limit), ramping that rate up and braking it
## back down through OmegaMotion rather than snapping.
##
## This replaced a flat `heading.slerp(desired, TURN_RATE * delta)`. That
## form has two problems this fixes: its effective angular speed was
## proportional to how far off the target was (a 180-degree reversal swung
## faster than a small correction — the opposite of how an airframe
## behaves), and it had no acceleration at all, so a ship changed from
## flying straight to turning at full rate within a single frame.
##
## Steering is a POSITIONAL problem — "close this angle to zero" — which is
## why it uses step_position rather than step_velocity: the controller has
## to invent the whole ramp-up/cruise/brake rate profile itself. The player
## never needs this because their stick input already IS a rate command.
func _turn_toward(c: Combatant, desired_dir: Vector3, delta: float) -> void:
	if desired_dir.length() <= 0.01:
		# Nothing commanded — bleed any residual turn rate off so the ship
		# doesn't keep rotating on a stale rate from a previous frame.
		c.turn_rate = move_toward(c.turn_rate, 0.0, flight_profile.ai_turn_max_accel * delta)
		return

	var goal_dir := desired_dir.normalized()
	var angle_off := c.heading.angle_to(goal_dir)
	if angle_off < 0.0001:
		c.turn_rate = move_toward(c.turn_rate, 0.0, flight_profile.ai_turn_max_accel * delta)
		return

	var step := OmegaMotion.step_position(
			angle_off, c.turn_rate, 0.0,
			flight_profile.ai_turn_max_rate, flight_profile.ai_turn_max_accel, delta)
	# step.y is signed toward closing the angle (i.e. negative, since the
	# error runs from angle_off down to 0); only its magnitude matters here
	# because the slerp below already carries the direction.
	c.turn_rate = step.y
	var swept: float = absf(step.y) * delta
	# Rotate the heading by AT MOST `swept` radians toward the goal, as a
	# fraction of the total angle — the same bounded-slerp pattern missile.gd
	# uses for its own turn-rate limiting.
	var new_heading := c.heading.slerp(goal_dir, clampf(swept / angle_off, 0.0, 1.0))
	if new_heading.length() > 0.01:
		c.heading = new_heading.normalized()


## Pilot-level state machine, layered under the squad's orders. A squad that
## has broken drags all its members into RETREAT; individually, a hurt pilot
## may break off on its own while the rest of its squad keeps fighting.
func _update_pilot_state(c: Combatant, sq: Squad, has_target: bool, target_pos: Vector3) -> void:
	# Climbing off the deck. Nothing else applies until it's clear of the
	# ship — no combat, no formation, no squad orders. Throttles up to cruise
	# as it goes, so a takeoff looks like a takeoff.
	if c.state == Combatant.State.LAUNCHING:
		if c.position.y - c.launch_deck_y >= LAUNCH_CLEAR_HEIGHT:
			c.state = Combatant.State.FORMATION
		return

	if sq.state == Squad.State.RETREAT or sq.state == Squad.State.REGROUP:
		c.state = Combatant.State.RETREAT
		return

	if c.state == Combatant.State.RETREAT:
		if c.state_timer > 0.0:
			return
		c.state = Combatant.State.FORMATION

	# Hurt enough to think about leaving — rolled once per crossing, not
	# every frame, via the health check plus the state guard above.
	if c.health <= MAX_HEALTH * RETREAT_HEALTH_FRACTION and randf() < RETREAT_ROLL_CHANCE * 0.02:
		c.state = Combatant.State.RETREAT
		c.state_timer = randf_range(RETREAT_TIME_MIN, RETREAT_TIME_MAX)
		return

	if c.state == Combatant.State.BREAK_OFF:
		if c.state_timer > 0.0:
			return
		c.state = Combatant.State.PURSUE

	if not has_target:
		c.state = Combatant.State.FORMATION
		return

	if c.state == Combatant.State.FORMATION:
		c.state = Combatant.State.PURSUE

	# The attack run ends when the attacker gets close — it flies through and
	# past its target rather than sticking to its tail, then turns back for
	# another pass. This is what makes the battle read as dogfighting.
	if c.state == Combatant.State.PURSUE and c.position.distance_to(target_pos) < BREAK_OFF_RANGE:
		c.state = Combatant.State.BREAK_OFF
		c.state_timer = randf_range(BREAK_OFF_TIME_MIN, BREAK_OFF_TIME_MAX)


func _steering_direction(c: Combatant, sq: Squad, own_units: Array, has_target: bool,
		target_pos: Vector3, target_vel: Vector3) -> Vector3:
	match c.state:
		Combatant.State.LAUNCHING:
			# Mostly straight up, leaned toward the squad's objective so the
			# fleet fans out in the right direction as it climbs instead of
			# forming one vertical column above the deck.
			var outbound := Vector3(sq.objective.x - c.position.x, 0.0, sq.objective.z - c.position.z)
			if outbound.length() > 0.01:
				outbound = outbound.normalized()
			return Vector3.UP * LAUNCH_CLIMB_BIAS + outbound

		Combatant.State.RETREAT:
			return sq.rally_point - c.position

		Combatant.State.BREAK_OFF:
			# Keep flying the heading it already had, pulled slightly off-axis
			# and up so the pass separates cleanly instead of driving straight
			# through the target's position.
			return c.heading * 3.0 + Vector3.UP * 0.6 + c.heading.cross(Vector3.UP) * 0.8

		Combatant.State.PURSUE:
			if has_target:
				return _lead_point(c.position, target_pos, target_vel, BOLT_SPEED) - c.position
			return _formation_or_objective(c, sq, own_units)

		_:
			return _formation_or_objective(c, sq, own_units)


## Leaders fly the squad's objective; wingmen hold a station on the leader.
func _formation_or_objective(c: Combatant, sq: Squad, own_units: Array) -> Vector3:
	if sq.leader < 0 or c.squad_slot == 0 or sq.leader >= own_units.size():
		return _advance_direction(c, sq)
	var leader: Combatant = own_units[sq.leader]
	if not leader.alive:
		return _advance_direction(c, sq)
	return _formation_station(leader, c.squad_slot) - c.position


func _advance_direction(c: Combatant, sq: Squad) -> Vector3:
	var horiz := Vector2(c.position.x - dome_center.x, c.position.z - dome_center.z).length()
	if horiz > dome_radius:
		# Head for the dome at this ship's OWN altitude, not dome_center's
		# raw y (which is sea level while this terrain is mountainous).
		return Vector3(sq.objective.x, c.position.y, sq.objective.z) - c.position
	return sq.objective - c.position


## Staggered V/echelon: odd slots to the right, even slots to the left,
## stepping further back and out with each rank.
func _formation_station(leader: Combatant, slot: int) -> Vector3:
	var fwd := leader.heading
	var up_ref := Vector3.FORWARD if absf(fwd.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var right := fwd.cross(up_ref).normalized()
	var up := right.cross(fwd).normalized()
	var side := 1.0 if (slot % 2) == 1 else -1.0
	var rank := float((slot + 1) / 2)
	return leader.position \
			- fwd * (FORMATION_SPACING * rank) \
			+ right * (side * FORMATION_SPACING * rank * 0.85) \
			+ up * (side * 15.0)


## Wingmen throttle up to close on their station and back off when they
## overshoot it — flying at one fixed speed either strings a squad out
## behind its leader or piles it into them.
func _update_throttle(c: Combatant, sq: Squad, own_units: Array, has_target: bool, target_pos: Vector3, delta: float) -> void:
	var wanted := c.base_speed
	if c.state == Combatant.State.LAUNCHING:
		# Accelerating off the deck to cruise, not leaving at full speed.
		wanted = c.base_speed
	elif c.state == Combatant.State.RETREAT:
		wanted = c.base_speed * 1.15
	elif has_target and c.state == Combatant.State.PURSUE:
		wanted = c.base_speed * 1.1
	elif c.squad_slot > 0 and sq.leader >= 0 and sq.leader < own_units.size():
		var leader: Combatant = own_units[sq.leader]
		if leader.alive:
			var gap := c.position.distance_to(_formation_station(leader, c.squad_slot))
			wanted = clampf(leader.speed + gap * FORMATION_SPEED_GAIN, c.base_speed * 0.6, c.base_speed * 1.6)
	var step := OmegaMotion.step_velocity(
			c.speed, c.speed_accel, wanted,
			flight_profile.forward_max_accel, flight_profile.forward_accel_time, delta)
	c.speed = step.x
	c.speed_accel = step.y


## Pushes away from nearby same-faction ships. Without this, formation and
## objective steering alone let whole squadrons converge onto identical
## points and fly as one solid mass — the "huge packs" problem. Capped at
## MAX_SEPARATION_NEIGHBORS and read from the 3x3 grid neighbourhood so the
## cost stays bounded no matter how dense the local traffic gets.
func _separation(c: Combatant, units: Array, grid: Dictionary) -> Vector3:
	var push := Vector3.ZERO
	var counted := 0
	var cx := int(floor(c.position.x / GRID_CELL_SIZE))
	var cz := int(floor(c.position.z / GRID_CELL_SIZE))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := Vector2i(cx + dx, cz + dz)
			if not grid.has(key):
				continue
			for idx in (grid[key] as Array):
				var o: Combatant = units[idx]
				if o == c or not o.alive:
					continue
				var away := c.position - o.position
				var dist := away.length()
				if dist > SEPARATION_RADIUS or dist < 0.01:
					continue
				push += (away / dist) * (1.0 - dist / SEPARATION_RADIUS)
				counted += 1
				if counted >= MAX_SEPARATION_NEIGHBORS:
					return push
	return push


func _retarget_if_needed(c: Combatant, my_index: int, opposing: Array, sq: Squad, can_target_player: bool) -> void:
	var target_invalid := true
	if c.targeting_player:
		target_invalid = not _player
	elif c.target_index >= 0:
		target_invalid = c.target_index >= opposing.size() or not (opposing[c.target_index] as Combatant).alive

	var is_stagger_turn := (my_index % RETARGET_STAGGER) == (_frame_counter % RETARGET_STAGGER)
	if not target_invalid and not is_stagger_turn:
		if c.targeting_player:
			_aliens_on_player += 1
		return

	var previous_target := c.target_index
	var was_targeting_player := c.targeting_player

	var best_index := -1
	var best_dist := INF
	var max_acquisition_sq := MAX_ACQUISITION_RANGE * MAX_ACQUISITION_RANGE
	for j in opposing.size():
		var o: Combatant = opposing[j]
		if not o.alive:
			continue
		var d := c.position.distance_squared_to(o.position)
		if d > max_acquisition_sq:
			continue
		# Squad focus fire: the leader's target is treated as substantially
		# closer than it is, so a squad concentrates rather than fragmenting
		# onto five separate targets the moment it arrives.
		if j == sq.focus_target and not sq.focus_is_player:
			d *= 0.35
		if d < best_dist:
			best_dist = d
			best_index = j

	var use_player := false
	if can_target_player and _player and _aliens_on_player < max_aliens_targeting_player:
		var pd := c.position.distance_squared_to(_player.global_position)
		if pd <= aggro_radius_player * aggro_radius_player and pd * player_target_bias < best_dist:
			use_player = true

	if use_player:
		c.target_index = -1
		c.targeting_player = true
		_aliens_on_player += 1
	elif best_index >= 0:
		c.target_index = best_index
		c.targeting_player = false
	else:
		c.target_index = -1
		c.targeting_player = false

	# Acquiring something NEW costs a reaction beat before it can shoot.
	if (c.targeting_player and not was_targeting_player) or (c.target_index >= 0 and c.target_index != previous_target):
		c.reaction_timer = randf_range(REACTION_TIME_MIN, REACTION_TIME_MAX)


func _random_point_in_dome() -> Vector3:
	var angle := randf() * TAU
	var dist := randf_range(0.0, dome_radius * 0.85)
	var x := dome_center.x + cos(angle) * dist
	var z := dome_center.z + sin(angle) * dist
	var ground: float = _terrain.get_height_at(x, z) if _terrain else 0.0
	var altitude := randf_range(SPAWN_ALT_MIN, dome_ceiling * 0.7)
	return Vector3(x, ground + altitude, z)


## Reactive pull-up check — true if current or projected (LOOKAHEAD_TIME
## ahead, along the current heading) ground clearance is under
## MIN_GROUND_CLEARANCE. Deliberately simple compared to enemy_ai.gd's
## version (no ground_avoidance_enabled toggle, no engine-health gating —
## nothing here has engine damage) but the same core current+lookahead
## check, since that's the part that actually matters.
func _needs_pull_up(c: Combatant, my_index: int, ground_here: float) -> bool:
	if not _terrain:
		return false
	# Immediate clearance is checked every frame — this is the one that
	# actually saves a ship's life.
	if c.position.y - ground_here < MIN_GROUND_CLEARANCE:
		return true

	# The lookahead sample is staggered and its result latched on the
	# Combatant — see Combatant.pull_up_latched for why that's accurate.
	if (my_index % LOOKAHEAD_STAGGER) != (_frame_counter % LOOKAHEAD_STAGGER):
		return c.pull_up_latched

	var lookahead_pos := c.position + c.heading * c.speed * LOOKAHEAD_TIME
	var ground_ahead: float = _terrain.get_height_at(lookahead_pos.x, lookahead_pos.z)
	c.pull_up_latched = lookahead_pos.y - ground_ahead < MIN_GROUND_CLEARANCE
	return c.pull_up_latched


func _check_ground_or_building(c: Combatant, ground_here: float) -> bool:
	if _terrain and c.position.y <= ground_here:
		return true
	# Altitude gate — see MAX_BUILDING_HEIGHT. Nothing flying this far above
	# the terrain can be inside a building, so the physics query is skipped.
	if enable_building_collision_check and (c.position.y - ground_here) <= MAX_BUILDING_HEIGHT:
		return CrashEffects.check_building_collision(get_world_3d().direct_space_state, c.position)
	return false


## Puts a ship back on its faction's mothership deck, parked and waiting for
## a launch slot.
func _respawn_combatant(c: Combatant, sq: Squad) -> void:
	var mothership := _mothership_for(c.faction)
	var deck_point: Vector3
	if mothership:
		deck_point = mothership.squad_deck_point(maxi(c.squad_id, 0), _squad_count_for(c.faction))
		# Spread a squad's own members across their slot rather than stacking
		# them on one point.
		deck_point += Vector3(randf_range(-60.0, 60.0), 0.0, randf_range(-60.0, 60.0))
	else:
		# No mothership (shouldn't happen, but the sim must not depend on it)
		# — fall back to the old airborne spawn.
		var ground: float = _terrain.get_height_at(sq.spawn_center.x, sq.spawn_center.z) if _terrain else 0.0
		deck_point = Vector3(sq.spawn_center.x, ground + randf_range(SPAWN_ALT_MIN, SPAWN_ALT_MAX), sq.spawn_center.z)

	c.position = deck_point
	c.launch_deck_y = deck_point.y
	# Horizontal-only heading toward the objective — NOT `(objective -
	# position)` directly, since a ship sitting on a deck 1400m up aiming at
	# a point near sea level would nose straight down off the bow.
	var level_target := Vector3(sq.objective.x, c.position.y, sq.objective.z)
	c.heading = (level_target - c.position).normalized()
	c.wander_point = c.position + c.heading * 500.0
	c.health = MAX_HEALTH
	c.alive = true
	c.speed = c.base_speed
	c.speed_accel = 0.0
	c.turn_rate = 0.0
	c.state = Combatant.State.PARKED
	c.state_timer = 0.0
	# Mid-match respawns don't queue behind the whole fleet the way the
	# opening launch does — see _park_faction for the match-start ordering.
	c.launch_delay = randf_range(0.0, LAUNCH_RESPAWN_DELAY_MAX)
	c.target_index = -1
	c.targeting_player = false
	c.reaction_timer = randf_range(REACTION_TIME_MIN, REACTION_TIME_MAX)
	c.fire_cooldown = randf_range(0.4, 1.0)
	c.missile_cooldown = randf_range(MISSILE_COOLDOWN_MIN, MISSILE_COOLDOWN_MAX)
	c.respawn_time_remaining = RESPAWN_DELAY


func _squad_count_for(faction: int) -> int:
	return _friendly_squads.size() if faction == Combatant.Faction.FRIENDLY else _enemy_squads.size()


func _kill_combatant(c: Combatant, index: int, sq: Squad, cause: String) -> void:
	c.alive = false
	c.target_index = -1
	c.targeting_player = false
	c.respawn_time_remaining = RESPAWN_DELAY
	if sq:
		sq.losses += 1

	_spawn_kill_effect(c.position)
	_add_kill_feed_entry("%s %s" % [_combatant_label(c.faction, index), cause])


## Budgeted three ways, because now that the AI actually fights, kills are
## constant and each unbudgeted ShipExplosion is a particle tree plus a
## 6000m-range OmniLight3D: nothing at all beyond explosion_cull_range, no
## light beyond explosion_light_range, and a hard cap on how many can be
## live at once.
func _spawn_kill_effect(at_position: Vector3) -> void:
	_purge_freed(_live_explosions)
	if _live_explosions.size() >= max_concurrent_explosions:
		return

	var player_dist := INF
	if _player:
		player_dist = _player.global_position.distance_to(at_position)
	if player_dist > explosion_cull_range:
		return

	var explosion := SHIP_EXPLOSION.instantiate()
	# Assigned BEFORE add_child — add_child() runs _ready() immediately, and
	# ship_explosion.gd reads this there. See this file's header for the bug
	# that taught us to be careful about this ordering.
	explosion.enable_light = player_dist <= explosion_light_range
	get_tree().current_scene.add_child(explosion)
	explosion.global_position = at_position
	_live_explosions.append(explosion)

	_play_battle_sound(BATTLE_EXPLOSION_SOUND, at_position, explosion_sound_range, 900.0, -30.0)


func _combatant_label(faction: int, index: int) -> String:
	return ("FRIENDLY-%03d" % index) if faction == Combatant.Faction.FRIENDLY else ("HOSTILE-%03d" % index)


func _add_kill_feed_entry(text: String) -> void:
	_kill_feed_entries.append({"text": text, "age": 0.0})
	if _kill_feed_entries.size() > KILL_FEED_MAX_ENTRIES:
		_kill_feed_entries.pop_front()
	_rebuild_kill_feed_text()


func _update_kill_feed(delta: float) -> void:
	var changed := false
	var i := 0
	while i < _kill_feed_entries.size():
		var entry: Dictionary = _kill_feed_entries[i]
		entry["age"] = (entry["age"] as float) + delta
		if (entry["age"] as float) > KILL_FEED_ENTRY_LIFETIME:
			_kill_feed_entries.remove_at(i)
			changed = true
		else:
			i += 1
	if changed:
		_rebuild_kill_feed_text()


func _rebuild_kill_feed_text() -> void:
	var lines: Array = []
	for entry in _kill_feed_entries:
		lines.append(entry["text"])
	kill_feed_text = "\n".join(lines)


# ---------------------------------------------------------------------------
# Firing
# ---------------------------------------------------------------------------

## Shoots only if the target is in range AND roughly ahead (FIRE_CONE) —
## ships used to fire at anything within range regardless of where their nose
## was pointed, which is both unreadable and free damage from impossible
## angles.
func _try_fire(c: Combatant, my_index: int, target_pos: Vector3, target_vel: Vector3) -> void:
	var range_to_target := c.position.distance_to(target_pos)
	if range_to_target > ENGAGE_RANGE:
		return

	var aim := _aim_point(c, target_pos, target_vel, range_to_target)
	var to_aim := aim - c.position
	if to_aim.length() < 0.01 or c.heading.angle_to(to_aim.normalized()) > FIRE_CONE:
		return

	c.fire_cooldown = randf_range(0.35, 0.9)
	if c.targeting_player:
		_fire_at_player(c, aim)
	else:
		_spawn_ambient_bolt(c, my_index, c.faction, aim)


## True intercept solution, displaced by this pilot's own inaccuracy. The
## error grows with range, so a distant AI sprays and a close one is
## genuinely dangerous — the standard way to make combat AI feel skilled
## without being impossible.
func _aim_point(c: Combatant, target_pos: Vector3, target_vel: Vector3, range_to_target: float) -> Vector3:
	var solution := _lead_point(c.position, target_pos, target_vel, BOLT_SPEED)
	c.aim_jitter = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5).normalized()
	return solution + c.aim_jitter * ((1.0 - c.accuracy) * range_to_target * AIM_ERROR_SCALE)


## Where to shoot so a bolt at `bolt_speed` meets a target moving at
## `target_vel`. Same quadratic firing solution target_lock.gd's PIP ring
## uses for the player — see docs/gunnery-reference.md. Falls back to the
## target's current position when there's no valid positive-time solution.
func _lead_point(shooter_pos: Vector3, target_pos: Vector3, target_vel: Vector3, bolt_speed: float) -> Vector3:
	var rel := target_pos - shooter_pos
	var a := target_vel.dot(target_vel) - bolt_speed * bolt_speed
	var b := 2.0 * rel.dot(target_vel)
	var cc := rel.dot(rel)

	var t := -1.0
	if absf(a) < 0.0001:
		if absf(b) > 0.0001:
			t = -cc / b
	else:
		var disc := b * b - 4.0 * a * cc
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


func _fire_at_player(c: Combatant, aim_point: Vector3) -> void:
	var dir := (aim_point - c.position).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP

	var bolt := LASER_BOLT.instantiate()
	# MUST be set before add_child(): add_child() runs laser_bolt.gd's
	# _ready(), which only resolves its Player/PlayerDamage references when
	# this is already false. Setting it afterwards (as this originally did)
	# left those references null, so alien fire could never damage the player.
	bolt.fired_by_player = false
	get_tree().current_scene.add_child(bolt)
	bolt.global_transform = Transform3D(Basis.looking_at(dir, up_ref), c.position)

	_play_battle_sound(BATTLE_LASER_SOUND, c.position, laser_sound_range, 2400.0, -18.0)


## Rare, longer-range shot — see the missile_cooldown gate in
## _update_combatant(). Reuses missile.gd's target_is_player mode exactly as
## the player's own missile_system.gd uses it for aliens, just aimed the
## other way.
func _fire_missile_at_player(c: Combatant, target_pos: Vector3) -> void:
	if not _player:
		return
	var dir := (target_pos - c.position).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP

	var missile := MISSILE.instantiate()
	# Same before-add_child rule as _fire_at_player above — missile.gd's
	# _ready() joins the "player_seeking_missiles" group and resolves
	# PlayerDamage/FlareSystem only when target_is_player is already true.
	# Setting these afterwards meant alien missiles did no damage and never
	# triggered missile_alert.gd.
	missile.target_is_player = true
	missile.player = _player
	missile.battle = self
	get_tree().current_scene.add_child(missile)
	missile.global_transform = Transform3D(Basis.looking_at(dir, up_ref), c.position)


func _spawn_ambient_bolt(c: Combatant, shooter_index: int, faction: int, aim_point: Vector3) -> void:
	if _ambient_bolts.size() >= max_ambient_bolts:
		return
	var dir := (aim_point - c.position).normalized()
	_ambient_bolts.append({
		"position": c.position,
		"velocity": dir * BOLT_SPEED,
		"faction": faction,
		"shooter_index": shooter_index,
		"life": BOLT_LIFETIME,
	})

	if randf() < laser_sound_chance:
		_play_battle_sound(BATTLE_LASER_SOUND, c.position, laser_sound_range, 2400.0, -18.0)


# ---------------------------------------------------------------------------
# Bolts
# ---------------------------------------------------------------------------

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
## effect. At hundreds of concurrent bolts, spawning
## CrashEffects.spawn_laser_impact()'s full Node3D+GPUParticles3D tree per
## miss would recreate the exact "hundreds of piling-up effects" problem
## that function was built to avoid, just at far greater scale. The
## travelling bolts themselves are the "lasers everywhere" visual; only
## kills (bounded by population, not bolt volume, and budgeted further in
## _spawn_kill_effect) get an effect.
func _check_bolt_environment(pos: Vector3) -> bool:
	var ground_height := 0.0
	if _terrain:
		ground_height = _terrain.get_height_at(pos.x, pos.z)
		if pos.y <= ground_height:
			return true
	# Same altitude gate as the ships use — see MAX_BUILDING_HEIGHT. Most
	# bolts fly well above the city, so this removes the large majority of
	# the per-bolt physics queries.
	if (pos.y - ground_height) > MAX_BUILDING_HEIGHT:
		return false
	return CrashEffects.check_building_collision(get_world_3d().direct_space_state, pos)


## Iterates the 3x3 grid neighbourhood inline rather than building a
## candidate Array per bolt per frame — at hundreds of bolts that allocation
## was pure garbage churn in the hottest loop in the system.
func _check_ambient_bolt_hit(b: Dictionary, prev_pos: Vector3, new_pos: Vector3) -> bool:
	var owner_faction: int = b["faction"]
	var opposing: Array = _enemies if owner_faction == Combatant.Faction.FRIENDLY else _friendlies
	var grid: Dictionary = _enemy_grid if owner_faction == Combatant.Faction.FRIENDLY else _friendly_grid

	var cx := int(floor(new_pos.x / GRID_CELL_SIZE))
	var cz := int(floor(new_pos.z / GRID_CELL_SIZE))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var key := Vector2i(cx + dx, cz + dz)
			if not grid.has(key):
				continue
			for idx in (grid[key] as Array):
				var o: Combatant = opposing[idx]
				if not o.alive:
					continue
				var closest := _closest_point_on_segment(o.position, prev_pos, new_pos)
				if closest.distance_to(o.position) <= BOLT_HIT_RADIUS:
					var shooter_label := _combatant_label(owner_faction, b["shooter_index"])
					_apply_damage_internal(opposing, idx, BOLT_DAMAGE, "shot down by %s" % shooter_label)
					# Only for hits the target SURVIVED — a kill already spawns
					# the far bigger ShipExplosion at the same spot.
					if o.alive:
						_spawn_hit_spark(closest)
					return true
	return false


## Budgeted the same way kill effects are: capped concurrently and only
## spawned near the player. At full battle intensity ships are being hit
## many times a second across the whole map, and an unbudgeted particle
## burst per hit is exactly the kind of thing that quietly eats a VR frame
## budget.
func _spawn_hit_spark(at_position: Vector3) -> void:
	if not _player or _player.global_position.distance_to(at_position) > spark_range:
		return
	_purge_freed(_live_sparks)
	if _live_sparks.size() >= max_concurrent_sparks:
		return
	var spark := HIT_SPARK.instantiate()
	get_tree().current_scene.add_child(spark)
	spark.global_position = at_position
	_live_sparks.append(spark)


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


func _apply_damage_internal(units: Array, index: int, amount: float, cause: String) -> void:
	var c: Combatant = units[index]
	if not c.alive:
		return
	c.health -= amount
	if c.health <= 0.0:
		var squads: Array[Squad] = _friendly_squads if c.faction == Combatant.Faction.FRIENDLY else _enemy_squads
		var sq: Squad = squads[c.squad_id] if c.squad_id >= 0 and c.squad_id < squads.size() else null
		_kill_combatant(c, index, sq, cause)


# ---------------------------------------------------------------------------
# Battle ambience
# ---------------------------------------------------------------------------

## A short-lived positional sound for something happening out in the battle,
## budgeted against max_battle_sounds and distance-gated so a fight on the
## other side of the city doesn't spend a voice. `cutoff`/`filter_db` drive
## Godot's built-in distance low-pass, which is what makes far-off fighting
## read as muffled rather than merely quiet.
func _play_battle_sound(stream: AudioStream, at_position: Vector3, max_range: float,
		cutoff: float, filter_db: float) -> void:
	if not _player:
		return
	if _player.global_position.distance_to(at_position) > max_range:
		return
	_purge_freed(_live_sounds)
	if _live_sounds.size() >= max_battle_sounds:
		return

	var sound := AudioStreamPlayer3D.new()
	get_tree().current_scene.add_child(sound)
	sound.global_position = at_position
	sound.stream = stream
	sound.max_distance = max_range
	sound.attenuation_filter_cutoff_hz = cutoff
	sound.attenuation_filter_db = filter_db
	sound.play()
	sound.finished.connect(sound.queue_free)
	_live_sounds.append(sound)


func _purge_freed(list: Array) -> void:
	var i := 0
	while i < list.size():
		if is_instance_valid(list[i]):
			i += 1
		else:
			list.remove_at(i)


# ---------------------------------------------------------------------------
# Air Superiority / match state
# ---------------------------------------------------------------------------

func _update_match_timer(delta: float) -> void:
	match_time_remaining = maxf(0.0, match_time_remaining - delta)
	if match_time_remaining <= 0.0 and not game_over:
		_end_game()


## Staggered — see AS_UPDATE_INTERVAL. The accumulated delta is integrated
## on the frames it does run, so the scoring rate is exactly what it would
## have been running every frame.
func _update_air_superiority(delta: float) -> void:
	_as_accumulated_delta += delta
	if (_frame_counter % AS_UPDATE_INTERVAL) != 0:
		return
	var scoring_delta := _as_accumulated_delta
	_as_accumulated_delta = 0.0

	var friendly_in_dome := _count_in_dome(_friendlies)
	if _player and _is_in_dome(_player.global_position):
		friendly_in_dome += 1
	var enemy_in_dome := _count_in_dome(_enemies)

	var net_rate := float(friendly_in_dome - enemy_in_dome) * as_generation_multiplier
	air_superiority = clampf(air_superiority + net_rate * scoring_delta, -100.0, 100.0)

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
		var b: Dictionary = _ambient_bolts[i]
		_bolt_mmi.multimesh.set_instance_transform(i, _bolt_transform(b))
		_bolt_mmi.multimesh.set_instance_color(i,
				FRIENDLY_BOLT_COLOR if b["faction"] == Combatant.Faction.FRIENDLY else ENEMY_BOLT_COLOR)


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


## LaserBolt.tscn's own mesh child carries a fixed -90 deg X rotation (its
## CylinderMesh's long axis is Y by default; the bolt travels along -Z),
## baked in here too so the pooled ambient bolts match the player's bolt
## visually.
func _bolt_transform(b: Dictionary) -> Transform3D:
	var dir: Vector3 = (b["velocity"] as Vector3).normalized()
	var up_ref := Vector3.FORWARD if absf(dir.dot(Vector3.UP)) > 0.99 else Vector3.UP
	var mesh_correction := Basis(Vector3.RIGHT, deg_to_rad(-90.0))
	return Transform3D(Basis.looking_at(dir, up_ref) * mesh_correction, b["position"] as Vector3)


# ---------------------------------------------------------------------------
# Public API — laser_bolt.gd (player shooting aliens) / target_lock.gd /
# missile_system.gd / missile.gd
# ---------------------------------------------------------------------------

# --- Ship audio keys ------------------------------------------------------
#
# ship_engine_audio.gd holds a stable reference to one specific ship while a
# pooled emitter is attached to it. Combatants live in two separate arrays,
# so a plain index is ambiguous — these pack faction and index into a single
# int so a voice can keep tracking "that ship over there" across frames.

const SHIP_KEY_ENEMY_OFFSET := 100000


func _ship_key(faction: int, index: int) -> int:
	return index + (SHIP_KEY_ENEMY_OFFSET if faction == Combatant.Faction.ENEMY else 0)


func _ship_for_key(key: int) -> Combatant:
	if key < 0:
		return null
	if key >= SHIP_KEY_ENEMY_OFFSET:
		var ei := key - SHIP_KEY_ENEMY_OFFSET
		return _enemies[ei] if ei < _enemies.size() else null
	return _friendlies[key] if key < _friendlies.size() else null


## Keys of the living ships nearest to `from` within `radius`, nearest
## first, capped at `max_count`. Called on a slow timer by
## ship_engine_audio.gd (a few times a second, not per frame) — a linear
## scan of both factions at that rate is nothing.
func get_ships_near(from: Vector3, radius: float, max_count: int) -> Array:
	var radius_sq := radius * radius
	var candidates: Array = []
	for i in _friendlies.size():
		var c: Combatant = _friendlies[i]
		if not c.alive:
			continue
		var d := from.distance_squared_to(c.position)
		if d <= radius_sq:
			candidates.append([d, i])
	for i in _enemies.size():
		var c: Combatant = _enemies[i]
		if not c.alive:
			continue
		var d := from.distance_squared_to(c.position)
		if d <= radius_sq:
			candidates.append([d, i + SHIP_KEY_ENEMY_OFFSET])

	candidates.sort_custom(func(a, b): return a[0] < b[0])

	var out: Array = []
	for entry in candidates:
		if out.size() >= max_count:
			break
		out.append(entry[1])
	return out


func is_ship_alive_by_key(key: int) -> bool:
	var c := _ship_for_key(key)
	return c != null and c.alive


func get_ship_position_by_key(key: int) -> Vector3:
	var c := _ship_for_key(key)
	return c.position if c else Vector3.ZERO


func get_ship_velocity_by_key(key: int) -> Vector3:
	var c := _ship_for_key(key)
	return c.heading * c.speed if c else Vector3.ZERO


## Where the player starts the match and respawns: parked on the friendly
## mothership's deck with the rest of the fleet. Returned as a world
## position so game_flow.gd / crash_handler.gd don't have to re-derive the
## mothership's altitude or deck height themselves — this is the single
## source of truth, replacing the hand-synced (-4000, 0) coordinate that
## previously lived in three separate exported values.
func get_player_spawn_position() -> Vector3:
	if _friendly_mothership:
		var deck: Vector3 = _friendly_mothership.random_deck_point()
		return deck + Vector3(0.0, 12.0, 0.0)  # sat on the deck, not embedded in it
	var ground: float = _terrain.get_height_at(_friendly_spawn_center.x, _friendly_spawn_center.z) if _terrain else 0.0
	return Vector3(_friendly_spawn_center.x, ground + 102.0, _friendly_spawn_center.z)


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


## All living aliens' indices, nearest-to-farthest from `from_position` —
## used by target_lock.gd's Y-button cycling (each press steps to the next
## entry in this order, wrapping around).
func get_alive_aliens_sorted_by_distance(from_position: Vector3) -> Array:
	var alive_indices: Array = []
	for i in _enemies.size():
		if _enemies[i].alive:
			alive_indices.append(i)
	alive_indices.sort_custom(func(a, b):
		return from_position.distance_squared_to(_enemies[a].position) < from_position.distance_squared_to(_enemies[b].position))
	return alive_indices


## Nearest living alien within `max_angle` (radians) of `direction` from
## `origin`, and within `max_range` — used by missile_system.gd's
## hold-trigger lock to pick what the player is actually pointing at, as
## opposed to get_nearest_alive_alien()'s pure nearest-by-distance (used for
## gun hits and target_lock.gd's Y-button cycling).
func get_nearest_alive_alien_in_cone(origin: Vector3, direction: Vector3, max_angle: float, max_range: float) -> int:
	var dir := direction.normalized()
	var max_range_sq := max_range * max_range
	var best_index := -1
	var best_dist := INF
	for i in _enemies.size():
		var c: Combatant = _enemies[i]
		if not c.alive:
			continue
		var to_target := c.position - origin
		var dist_sq := to_target.length_squared()
		if dist_sq < 0.0001 or dist_sq > max_range_sq:
			continue
		if to_target.normalized().angle_to(dir) > max_angle:
			continue
		if dist_sq < best_dist:
			best_dist = dist_sq
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


func apply_damage(index: int, amount: float, cause: String = "destroyed by PLAYER") -> void:
	if index < 0 or index >= _enemies.size():
		return
	_apply_damage_internal(_enemies, index, amount, cause)


## Spawns a flare at the given alien's current position — called by
## missile.gd the first time an incoming player missile enters the flare
## countermeasure window, since aliens have no button to press themselves
## (flare_system.gd is the equivalent player-side control). Always spawns
## (no limited flare supply was specified) — the missile itself owns the
## redirect-chance roll.
func try_deploy_alien_flare(index: int) -> Node3D:
	if index < 0 or index >= _enemies.size() or not _enemies[index].alive:
		return null
	var flare := FLARE.instantiate()
	get_tree().current_scene.add_child(flare)
	flare.global_position = _enemies[index].position
	return flare
