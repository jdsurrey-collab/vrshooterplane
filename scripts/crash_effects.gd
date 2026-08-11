class_name CrashEffects
extends RefCounted

## Shared "spawn a crash site" helper — used by the player (crash_handler.gd),
## enemy AI (enemy_ai.gd), and laser bolts (laser_bolt.gd) so crater/debris
## tuning only needs to change in one place, and by the same three callers
## for detecting whether something has hit a building.

const CRASH_EFFECT := preload("res://scenes/CrashEffect.tscn")
const DEBRIS_PIECE := preload("res://scenes/DebrisPiece.tscn")
const LASER_IMPACT_EFFECT := preload("res://scenes/LaserImpactEffect.tscn")
const DEBRIS_COUNT_MIN := 7
const DEBRIS_COUNT_MAX := 8
const DEBRIS_SCATTER_MIN := 4.0  # meters from impact point
const DEBRIS_SCATTER_MAX := 25.0

## How many crash sites may exist at once. Crash markers are deliberately
## PERMANENT (see crash_effect.gd) — they never dissipate — so without a cap
## their cost is cumulative and monotonic for the whole session: every crash
## adds a looping smoke column plus ~8 wreck meshes that are re-simulated
## and re-drawn on every frame from then on, forever. Bounding the count
## keeps the "visible trail of where you've died" idea intact while giving
## it a fixed ceiling, the same budgeted-pool convention this project already
## applies to kill fireballs (max_concurrent_explosions), battle audio
## (max_battle_sounds), thruster trails (trail_count) and flak bursts.
const MAX_CRASH_SITES := 3

## Crash sites used to be genuinely PERMANENT — "a visible trail of every
## crash so far" — and were only ever bounded (to 5) because that permanence
## made a session's frame rate degrade monotonically.
##
## Reported from the headset: "I don't ever see any crash sites. It's almost
## overkill to have them at all." That is correct, and there is a concrete
## reason the original design stopped paying off: it predates the motherships.
## The player used to respawn a few kilometres from where they died, so a
## permanent smoke column was something they would fly back past. Respawn now
## puts them on a flight deck **22km away** (see spawn_distance_from_city), so
## they never return to the site at all — and the column is behind them,
## already out of sight, before the death screen has even faded.
##
## So the permanence was pure cost against an effect nobody was looking at: 5
## concurrent 420-particle smoke columns, each large and alpha-blended,
## re-simulated and re-drawn every frame for the rest of the session. What
## still earns its keep is the moment of impact itself, which the player
## definitely does see — they are frozen in the wreck for a couple of seconds
## before the death screen. That is preserved exactly; only the "forever"
## part is gone.
const CRASH_SITE_LIFETIME := 60.0

## Live crash sites, oldest first. Each entry is the Array of nodes that
## make up one site (its smoke column plus every debris piece), so recycling
## the oldest removes the whole site together rather than leaving orphaned
## wreckage standing around a column that has been freed.
static var _crash_sites: Array[Array] = []


## Frees the oldest crash sites until at most `MAX_CRASH_SITES - 1` remain,
## making room for one about to be spawned. Also drops any entry whose nodes
## have already been freed by something else (a scene reload, say), so the
## static list can't accumulate stale records across a session.
static func _retire_oldest_sites() -> void:
	for i in range(_crash_sites.size() - 1, -1, -1):
		var still_live := false
		for n in _crash_sites[i]:
			if is_instance_valid(n):
				still_live = true
				break
		if not still_live:
			_crash_sites.remove_at(i)

	while _crash_sites.size() >= MAX_CRASH_SITES:
		for n in _crash_sites[0]:
			if is_instance_valid(n):
				n.queue_free()
		_crash_sites.remove_at(0)


## Spawns the smoke/main-crater effect plus scattered wreckage chunks, each in
## their own small scorch crater. The whole site is freed together after
## CRASH_SITE_LIFETIME — see that constant for why this stopped being
## permanent.
##
## Debris does NOT spawn pre-settled on the ground — a ship's gravity
## compensator (flight_controller.gd's GRAVITY COMPENSATOR STANDARD) is
## what's been holding it up all along, and that dies with the ship. Each
## piece spawns at `impact.y` (the ship's actual altitude at the moment it
## died — high in the air for a mid-flight kill, right at the ground for a
## terrain/building crash) and genuinely falls to the surface under gravity
## — see falling_debris.gd, which every DebrisPiece carries.
##
## The crater/smoke itself is always placed at GROUND level for its (x, z),
## not `impact.y` directly — `impact` is the ship's exact death position,
## which for a mid-air kill is up in the sky. A crater floating where the
## ship happened to be shot down would make no sense; it belongs on the
## surface below, with debris raining down around/into it as it falls.
static func spawn(scene_root: Node, terrain: Node, impact: Vector3) -> void:
	var ground_y: float = terrain.get_height_at(impact.x, impact.z) if terrain else impact.y
	var ground_impact := Vector3(impact.x, ground_y, impact.z)

	# Make room before adding, so the live-site count is a true ceiling
	# rather than a ceiling plus one.
	_retire_oldest_sites()
	var site: Array = []

	var effect := CRASH_EFFECT.instantiate()
	scene_root.add_child(effect)
	effect.global_position = ground_impact
	site.append(effect)

	var count := randi_range(DEBRIS_COUNT_MIN, DEBRIS_COUNT_MAX)
	for i in count:
		var angle := randf() * TAU
		var dist := randf_range(DEBRIS_SCATTER_MIN, DEBRIS_SCATTER_MAX)
		var x := impact.x + cos(angle) * dist
		var z := impact.z + sin(angle) * dist

		var piece := DEBRIS_PIECE.instantiate()
		scene_root.add_child(piece)
		site.append(piece)
		piece.global_position = Vector3(x, impact.y, z)
		piece.rotation.y = randf() * TAU
		piece.terrain = terrain
		piece.tumble_speed = Vector3(randf_range(-3.0, 3.0), randf_range(-3.0, 3.0), randf_range(-3.0, 3.0))

		var chunk := piece.get_node_or_null("Chunk")
		if chunk:
			chunk.rotation.x = randf_range(-0.5, 0.5)
			chunk.rotation.z = randf_range(-0.5, 0.5)
			var s := randf_range(0.6, 1.6)
			chunk.scale = Vector3(s, s, s)
			chunk.position.y = s * 0.5  # rest roughly on the ground, not half-buried

	_crash_sites.append(site)

	# Self-cleaning now rather than permanent — see CRASH_SITE_LIFETIME. The
	# cap above still exists as a hard ceiling for the case where a player
	# crashes several times inside one lifetime window; this timer is what
	# stops a site outliving the player's interest in it.
	scene_root.get_tree().create_timer(CRASH_SITE_LIFETIME).timeout.connect(
			func() -> void:
				for n in site:
					if is_instance_valid(n):
						n.queue_free()
				_crash_sites.erase(site))


## Small, self-cleaning explosion/crater/smoke for a single laser hit —
## intentionally much smaller and temporary compared to spawn() above (see
## laser_impact_effect.gd for why it can't be permanent at this fire rate).
static func spawn_laser_impact(scene_root: Node, impact: Vector3) -> void:
	var effect := LASER_IMPACT_EFFECT.instantiate()
	scene_root.add_child(effect)
	effect.global_position = impact


## True if `position` is inside any building's collision shape — buildings
## are on CityGenerator.BUILDING_COLLISION_LAYER (see city_generator.gd).
## Used for a single-point check (the ship/bolt's current position), same
## approximate philosophy as the terrain-height ground check elsewhere in
## this project — no full collision hull, just a reference point.
static func check_building_collision(space_state: PhysicsDirectSpaceState3D, position: Vector3) -> bool:
	if not space_state:
		return false
	var query := PhysicsPointQueryParameters3D.new()
	query.position = position
	query.collision_mask = 1 << (CityGenerator.BUILDING_COLLISION_LAYER - 1)
	query.collide_with_bodies = true
	query.collide_with_areas = false
	var result := space_state.intersect_point(query, 1)
	return result.size() > 0
