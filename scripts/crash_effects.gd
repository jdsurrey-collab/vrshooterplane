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


## Spawns the smoke/main-crater effect (permanent — never cleans itself up,
## see crash_effect.gd) plus scattered wreckage chunks, each in their own
## small scorch crater. The debris is added with no lifetime either — it's
## meant to persist for the rest of the session, a visible trail of every
## crash so far.
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

	var effect := CRASH_EFFECT.instantiate()
	scene_root.add_child(effect)
	effect.global_position = ground_impact

	var count := randi_range(DEBRIS_COUNT_MIN, DEBRIS_COUNT_MAX)
	for i in count:
		var angle := randf() * TAU
		var dist := randf_range(DEBRIS_SCATTER_MIN, DEBRIS_SCATTER_MAX)
		var x := impact.x + cos(angle) * dist
		var z := impact.z + sin(angle) * dist

		var piece := DEBRIS_PIECE.instantiate()
		scene_root.add_child(piece)
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
