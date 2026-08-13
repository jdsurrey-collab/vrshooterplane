class_name CityGenerator
extends Node3D

## Procedurally builds a city across the WHOLE TERRAIN, wherever the ground
## is low enough (see max_building_terrain_height) — originally a single
## fixed block grid near the starting area, superseded by a map-wide,
## height-gated version (see that export's own header for the measured
## heightmap survey behind it). A lattice of streets (roads.tscn-free —
## built directly as GPU-instanced tiles, see _generate_roads) with
## skyscrapers from the "skyscraper_pack" asset set centered in each
## candidate block, facing the grid instead of randomly rotated. That grid
## alignment is what actually reads as "a city" from a distance — an
## earlier version scattered buildings with full random rotation and no
## street pattern, which just looked like debris from far away.
##
## Two building pools:
## - REGULAR_BUILDINGS (shorter base models, modest scale) — the bulk of
##   the skyline, roughly 75-250m tall.
## - LANDMARK_BUILDINGS (the tallest base models, scaled up hard) — a
##   scattered minority of supertall towers, 400m+.
##
## Building footprints/heights were measured directly from the imported
## meshes (bases run ~25-65m wide, 73-125m tall as authored) via a one-off
## headless AABB script, not guessed.
##
## Roads are a single MultiMeshInstance3D (GPU instancing) rather than one
## MeshInstance3D per tile — a 24-block grid works out to ~1,200 road
## segments, which would be 1,200 separate draw calls as individual nodes.
## Segmented per-block (not a few long strips) so each tile samples its own
## local terrain height and actually follows the ground instead of a long
## flat plane floating over/clipping through elevation changes.
##
## Buildings ARE solid — each gets a StaticBody3D + a CollisionShape3D
## auto-sized from the building's own measured mesh bounds (walked at
## instantiation time, not hand-maintained per type). BUILDING_COLLISION_LAYER
## is the single source of truth other scripts check against — see
## CrashEffects.check_building_collision(), used by crash_handler.gd (player)
## and enemy_ai.gd so flying into a building crashes you exactly like
## hitting the ground.
##
## Also places ONE deliberately colossal hand-tuned landmark at the
## terrain's true centre, entirely separate from the procedural population
## above — see the "Mega tower" export group and _place_mega_tower() for
## the full reasoning.

const BUILDING_COLLISION_LAYER := 10
const BUILDING_TEXTURE_DIR := "res://Assets/City/Textures/"

const REGULAR_BUILDINGS := [
	preload("res://Assets/City/Models/building_01.1.fbx"),
	preload("res://Assets/City/Models/building_01.2.fbx"),
	preload("res://Assets/City/Models/building_01.3.fbx"),
	preload("res://Assets/City/Models/building_01.4.fbx"),
	preload("res://Assets/City/Models/building_02.1.fbx"),
	preload("res://Assets/City/Models/building_02.2.fbx"),
	preload("res://Assets/City/Models/building_03.1.fbx"),
	preload("res://Assets/City/Models/building_03.2.fbx"),
	preload("res://Assets/City/Models/building_08.1.fbx"),
	preload("res://Assets/City/Models/building_08.2.fbx"),
]
const LANDMARK_BUILDINGS := [
	preload("res://Assets/City/Models/building_04.1.fbx"),
	preload("res://Assets/City/Models/building_04.2.fbx"),
	preload("res://Assets/City/Models/building_05.1.fbx"),
	preload("res://Assets/City/Models/building_05.2.fbx"),
	preload("res://Assets/City/Models/building_06.1.fbx"),
	preload("res://Assets/City/Models/building_06.2.fbx"),
	preload("res://Assets/City/Models/building_07.1.fbx"),
	preload("res://Assets/City/Models/building_07.2.fbx"),
]

@export var terrain_path: NodePath = ^"../Terrain"
## Still exported and still real — read by `FactionBattle.dome_center`
## (`if "city_center" in city: dome_center = city.city_center`), the
## Air Superiority contested-column anchor. Now DECOUPLED from building
## placement below, which covers the terrain's own full extent instead of
## a footprint centered here — this is deliberately left untouched so the
## dome/motherships/spawn coupling documented elsewhere in this project
## doesn't shift just because the buildings now cover more ground.
@export var city_center: Vector3 = Vector3(6000.0, 0.0, 0.0)
## MAP-WIDE, HEIGHT-GATED PLACEMENT, not a fixed footprint. Buildings and
## roads now cover the terrain's ENTIRE extent (`_terrain.world_size`,
## centred on `_terrain.global_position`) rather than a fixed
## `grid_size * block_pitch` block anchored on `city_center` — a candidate
## block is only actually built if the terrain underneath it is at or
## below `max_building_terrain_height`, so the city naturally pools into
## the lowlands and mountains stay bare. Direct request: "put a building
## everywhere that is [low enough]... that just makes it so buildings
## can't go on mountains."
##
## `block_pitch` is still the density dial (distance between street
## centerlines) — it just no longer has a fixed footprint to multiply
## against; the grid now spans the whole map, and MEASURED, not guessed,
## because this terrain's baseline elevation turned out far higher than
## assumed. A headless heightmap sample (40,401 points, 500m spacing)
## found only 0.06% of the map at or below 300m (the number first asked
## for) — the lowest point sampled anywhere was 239m, meaning the
## EXISTING city already sits in essentially the only pocket that low, and
## building strictly at 300m would have shrunk the city to ~80 buildings
## instead of expanding it. The measured table that came out of that
## survey (0.06% / 2.6% / 14% / 26% / 44% / 57% of the map qualifying at
## 300 / 500 / 750 / 1000 / 1500 / 2000m respectively) is what 750.0 (then
## the live default) was chosen against.
##
## DOUBLED to 1500.0 on direct request after the 750m version ran well —
## per the same survey table, 1500m qualifies ~44% of the map, an
## estimated ~54,500 buildings at this density, up from ~17,300 at 750m.
## Real new territory for this project's collision-body count (one
## StaticBody3D per building, unbatched, unlike the MultiMesh rendering) —
## worth re-measuring load time and physics cost live rather than assuming
## the previous 750m measurement still holds at 3x the building count.
@export var max_building_terrain_height: float = 1500.0
@export var block_pitch: float = 257.14  # distance between street centerlines
@export var road_width: float = 30.0
@export var building_jitter: float = 20.0  # reduced with the tighter 257m blocks so buildings stay off the streets
## Applies per CANDIDATE block, same as always — most of the actual
## thinning at map scale now comes from `max_building_terrain_height`
## rejecting mountain blocks outright, not from this. Left at its
## previous value rather than retuned, since the target was never an
## exact building count, just genuine density in the area that qualifies.
@export var skip_chance: float = 0.18  # leave some blocks empty (plazas/lots)
@export var landmark_chance: float = 0.08  # fraction of filled blocks that go supertall
## DOUBLE THE CEILING, KEEP THE FLOOR — the actual request was "double the
## height of all the buildings['] potential... I still want building sizes
## to range from a couple hundred meters to the max." A uniform doubling of
## `height_multiplier` alone would have doubled BOTH ends. Instead
## `height_multiplier` doubled (3.0 -> 6.0, doubling the ceiling) while
## both scale_min values were HALVED to exactly cancel that doubling at
## the floor — the algebra: final height = base * scale *
## height_multiplier, so halving scale while doubling height_multiplier
## leaves the MINIMUM unchanged while the MAXIMUM (scale_max, left
## untouched) doubles along with height_multiplier alone. Verified against
## the ACTUAL generated buildings, not the "~73-125m" base-height figure
## documented elsewhere (which turned out to describe only some models,
## not the true extremes across all 10 REGULAR_BUILDINGS): measured
## shortest building **111m**, tallest **3738m** — since the floor-side
## multiplier (`scale_min * height_multiplier`) is algebraically identical
## before and after (1.0*3.0 == 0.5*6.0 == 3.0), 111m is guaranteed to be
## exactly what the shortest building already measured before this change,
## whatever that model's true base height actually is; only the ceiling
## genuinely moved, and it moved by exactly 2x (measured old max ~1868m).
@export var regular_scale_min: float = 0.5
@export var regular_scale_max: float = 2.5
@export var landmark_scale_min: float = 1.75  # ~73m base * 1.75 * 6.0 height_multiplier = ~766m, unchanged floor
@export var landmark_scale_max: float = 5.0

## Applied to the Y axis ONLY, on top of the uniform scale above — so
## buildings get taller without getting wider, and the street grid and
## overall sprawl are untouched. Scaling all three axes would have widened
## every footprint to match, crowding the blocks and effectively growing the
## city.
##
## COUPLED TO faction_battle.gd's MAX_BUILDING_HEIGHT, which is the altitude
## above which its ships and bolts skip their building-collision physics
## query entirely. If the tallest building here can exceed that value,
## things fly through the tops of towers. Tallest right now: ~125m base *
## 5.0 landmark scale * 6.0 height multiplier = ~3750m measured — see the
## matching bump on MAX_BUILDING_HEIGHT itself.
@export var height_multiplier: float = 6.0

## Buildings are drawn as batched MultiMeshes, optionally split into a
## render_chunks x render_chunks grid. Higher values improve frustum culling
## but multiply draw calls (each chunk needs its own batch per mesh type);
## 1 means a single city-wide batch per mesh — fewest possible draw calls,
## no per-district culling.
##
## DEFAULT IS 1, and that was a measured decision, not a guess, back when
## the city was ~1470 buildings (~51,000 triangles at these models' ~35
## triangles/building average) — genuinely nothing for culling to save, and
## 4x4 chunking was costing ~215 draw calls to protect against a vertex
## cost that didn't exist.
##
## STALE SINCE THE MAP-WIDE REWORK (see max_building_terrain_height):
## ~17,300 buildings puts city geometry around ~605,000 triangles, ~12x
## what this default was validated against. Still likely fine for the same
## structural reason (draw-call cost has historically dominated vertex cost
## in this project at every scale tried so far), but that's now an
## extrapolation, not the original measurement — re-check before assuming
## render_chunks=1 is still clearly correct if this ever needs revisiting.
## Raise this only if the building models are ever replaced with something
## genuinely heavy, or if a live look says otherwise.
@export var render_chunks: int = 1

@export_group("Mega tower — one-off landmark")
## A single, deliberately colossal tower — direct request: "a one-off
## thing where this huge building is almost looming over the entire
## area... like a beacon or a tower," dramatically bigger than anything
## the procedural population above can produce. Genuinely hand-placed, not
## part of `_generate_buildings()`'s grid: NOT in the `buildings` array
## (so it's immune to `collapse_near()` — a permanent monument, not
## something a nearby tank explosion should be able to sink) and NOT
## folded into the batched building MultiMeshes (a true one-off doesn't
## need the batching machinery built for many identical-scale instances —
## one extra draw call is free). Reuses `LANDMARK_BUILDINGS[0]` so it
## matches the city's own visual language rather than introducing a new
## asset, textured through the same `_material_for_scene()` FBX-recovery
## path as everything else.
@export var mega_tower_enabled: bool = true
## World X/Z — "sits right in the middle of the ENTIRE map," i.e. the
## terrain's own true centre (world origin), not `city_center` (which is
## just where the original fixed-footprint city and the Air Superiority
## scoring column happen to be).
@export var mega_tower_position_xz: Vector2 = Vector2.ZERO
## Target height in metres. The request's own "fifty times bigger than
## any building" read literally against the current tallest building
## (~3746m) would be ~187km — longer than the entire 100km map, clearly
## not literally meant. Read instead against a TYPICAL building (median
## height ~520m at this density): 50x = ~26,000m, rounded to a clean
## 25,000m — nearly 7x the tallest procedural landmark and over 3x the
## tallest mountain (~6984m), genuinely towering above the cloud band
## (3200-3800m) as a real beacon visible from across the map.
@export var mega_tower_height: float = 25000.0
## Target base diameter in metres. Same reasoning against a typical
## building's diameter (median ~56m): 20x = ~1120m, rounded to 1200m.
@export var mega_tower_diameter: float = 1200.0
## Height and diameter are hit INDEPENDENTLY (unlike the procedural
## population's single uniform `s` plus `height_multiplier`) by computing
## separate X/Z and Y scale factors against the chosen model's own
## measured local AABB — this is a one-off hand-tuned landmark, not a
## member of a population that needs one shared scale law.
##
## NOT ADDED TO `landmark_rooftops`. That array feeds ground_flak.gd's
## cosmetic AA fire, which is tuned for towers reaching a few hundred
## metres (`SHELL_BURST_ALTITUDE_MIN/MAX` 3700-4700m) — flak launching
## from a 25,000m rooftop would be far outside anything that system was
## ever tuned against, so this tower is deliberately left out of it.

@export_group("Surface look")
## Buildings, roads and terrain are all deliberately on the smooth side of
## the roughness range — that specular response off the sun is what reads as
## rain-slicked rather than matte. Raise toward 1.0 for a dry city.
@export var building_roughness: float = 0.5
@export var road_roughness: float = 0.28  # wet asphalt is the shiniest thing down there

## World-space rooftop points for every LANDMARK building placed — read by
## ground_flak.gd as launch points for its cosmetic anti-aircraft fire, so
## flak bolts and SAM missiles appear to originate from real towers instead
## of arbitrary scattered points. Only landmarks are included (not the
## regular-building majority): the supertall towers read as plausible flak-
## battery positions from a flying altitude, and there are still ~100+ of
## them across the city (landmark_chance * filled blocks) — plenty of
## variety without tracking every one of ~1400 buildings.
var landmark_rooftops: Array[Vector3] = []

# ---------------------------------------------------------------------------
# Per-building records — what makes individual buildings destructible
# ---------------------------------------------------------------------------
#
# Buildings are drawn as batched MultiMeshes (see below), which is what keeps
# ~1400 of them at ~19 draw calls. The cost of that batching is that a
# building is not a node you can move — it is a transform at some index
# inside a shared instance buffer. So to make one collapse, its slot has to
# be remembered at placement time.
#
# Each entry is:
#   pos     Vector3  world position of the building's base
#   radius  float    horizontal footprint radius, for splash queries
#   height  float    world-space height — how far it must sink to vanish
#   body    StaticBody3D  its collision box (sinks with it, then freed)
#   parts   Array    one per mesh this building is built from:
#                      key   String        bucket it was batched into
#                      index int           its slot in that bucket
#                      mmi   MultiMeshInstance3D  resolved after batching
#                      xform Transform3D   its original, un-sunk transform
#   sink    float    metres descended so far
#   state   int      BuildingState below
var buildings: Array[Dictionary] = []

enum BuildingState { STANDING, COLLAPSING, GONE }

## Bounds handed to every building MultiMesh — see _build_building_multimeshes.
## Was a fixed const sized for the old ~10800m city footprint; now that
## buildings can land anywhere across the terrain's own extent, this has to
## track terrain.world_size instead of a hardcoded guess, so it's computed
## in _ready() (see _origin/_half_total) rather than a compile-time constant.
var _city_batch_aabb: AABB

## How long a doomed building takes to disappear, in SECONDS — deliberately a
## duration rather than a sink speed in metres/second. This city's buildings
## range from ~100m to ~1870m tall, so a fixed speed would drop a low block in
## four seconds while a supertall tower ground down for over a minute; each
## building instead descends at its own rate, `(height + extra) / duration`,
## so an entire condemned block goes under together and the effect has a
## predictable length regardless of what happened to be standing there.
## Sound of a city block coming down. Four variants so repeated demolitions
## across a match don't all sound identical — `_pick_collapse_sound()` also
## never plays the same one twice running, the rule this project already uses
## for damage hits and flak bursts.
##
## Each is a LAYERED composite rather than one recording, built once through
## ffmpeg from user-supplied sources that fell into three natural groups
## (structural groan, the crash itself, sliding rubble). They're mixed in
## that order with real offsets — metal groans, *then* the structure goes,
## *then* debris settles — which is the shape of an actual collapse and is
## what makes an 8-9s sound track a 7s `collapse_duration` instead of just
## being noise. Processed heavily muffled per request: highs gone above
## 850Hz, big bass lift, and a long two-stage reverb tail for a city
## bouncing it back. Mono, since AudioStreamPlayer3D can only position mono.
const COLLAPSE_SOUNDS: Array[AudioStream] = [
	preload("res://Assets/Audio/building_collapse_1.mp3"),
	preload("res://Assets/Audio/building_collapse_2.mp3"),
	preload("res://Assets/Audio/building_collapse_3.mp3"),
	preload("res://Assets/Audio/building_collapse_4.mp3"),
]

@export var collapse_duration: float = 7.0

@export_group("Collapse audio")
## Beyond this no voice is spawned at all — the range gate and the budget are
## the same thing, matching ground_flak.gd's burst audio.
@export var collapse_sound_range: float = 16000.0
## Buildings don't start falling at the instant of the blast; they groan and
## then go. This offset is what stops the collapse reading as part of the
## explosion rather than a consequence of it.
@export var collapse_sound_delay: float = 0.8
@export var collapse_sound_unit_size: float = 1600.0
## Godot's distance low-pass. Low, so a block coming down on the far side of
## the city is a dull rumble rather than audible rubble.
@export var collapse_sound_cutoff_hz: float = 750.0
@export var collapse_volume_db: float = -1.0
@export var player_path: NodePath = ^"../Player"

var _last_collapse_sound: int = -1
## Extra depth kept descending past the building's own height before it is
## hidden outright, so one on sloping ground can't leave a corner poking out
## of the hillside.
@export var collapse_extra_depth: float = 40.0

## Indices into `buildings` that are currently sinking. Kept as a separate
## list so _process() iterates only the handful actually collapsing rather
## than all ~1400 every frame.
var _collapsing: Array[int] = []

var _bucket_mmi: Dictionary = {}

var _terrain: Node

## Terrain-derived placement bounds, computed once in _ready() and shared by
## both generation passes — the whole point of the map-wide rework is that
## there is no longer a separate, independently-tunable footprint size, so
## these three values ARE the footprint now.
var _origin: Vector3
var _half_total: float
var _grid_count: int


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)
	if not _terrain:
		return

	_origin = _terrain.global_position
	_half_total = _terrain.world_size * 0.5
	_grid_count = int(_terrain.world_size / block_pitch)

	_generate_roads()
	_generate_buildings()

	# Batch bounds must cover the whole terrain footprint now, not the old
	# fixed 10800m city block — see CITY_BATCH_AABB's own note. Computed
	# from the ACTUAL placed buildings (pos.y + height) rather than a
	# formula guess against height_multiplier/scale exports — those moved
	# once already (doubled) and guessing a margin against them is exactly
	# the kind of number that silently goes stale the next time they do.
	# X/Z still come from the terrain extent directly, since building
	# placement is bounded by that regardless of any individual height.
	var max_top_y := 0.0
	for b in buildings:
		var pos: Vector3 = b["pos"]
		max_top_y = maxf(max_top_y, pos.y + float(b["height"]))
	var aabb_y_bottom := -2000.0
	var aabb_y_top := max_top_y + 1000.0
	_city_batch_aabb = AABB(
			Vector3(_origin.x - _half_total - 2000.0, aabb_y_bottom, _origin.z - _half_total - 2000.0),
			Vector3(_half_total * 2.0 + 4000.0, aabb_y_top - aabb_y_bottom, _half_total * 2.0 + 4000.0))

	# Buildings are only bucketed during placement; this turns the buckets
	# into the actual MultiMeshInstance3D nodes.
	_build_building_multimeshes()

	if mega_tower_enabled:
		_place_mega_tower()

	# Nothing is collapsing at match start, and a city of many thousands of
	# buildings has no other per-frame work at all — collapse_near()
	# switches this back on.
	set_process(false)


func _generate_roads() -> void:
	var road_material := StandardMaterial3D.new()
	road_material.albedo_color = Color(0.055, 0.058, 0.065)
	# Wet asphalt: dark and smooth, so the streets throw a long specular
	# streak back at the sun instead of reading as flat grey tape.
	road_material.roughness = road_roughness
	road_material.metallic = 0.0
	road_material.metallic_specular = 0.85

	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(1.0, 0.15, 1.0)  # unit size — scaled per-instance below
	tile_mesh.material = road_material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = tile_mesh

	var transforms: Array[Transform3D] = []

	# Streets running along Z, at each of the _grid_count+1 X-grid-lines —
	# one tile per block along the street's length, not one long strip.
	# Each tile is independently gated by max_building_terrain_height, same
	# as buildings — a road climbing partway up a mountain with no
	# buildings around it would look like a mistake, not a feature.
	for i in range(_grid_count + 1):
		var x := _origin.x - _half_total + i * block_pitch
		for j in _grid_count:
			var z := _origin.z - _half_total + j * block_pitch + block_pitch * 0.5
			var ground_height: float = _terrain.get_height_at(x, z)
			if ground_height > max_building_terrain_height:
				continue
			transforms.append(Transform3D(
					Basis().scaled(Vector3(road_width, 1.0, block_pitch)),
					Vector3(x, ground_height + 0.05, z)))

	# Streets running along X, at each of the _grid_count+1 Z-grid-lines.
	for j in range(_grid_count + 1):
		var z := _origin.z - _half_total + j * block_pitch
		for i in _grid_count:
			var x := _origin.x - _half_total + i * block_pitch + block_pitch * 0.5
			var ground_height: float = _terrain.get_height_at(x, z)
			if ground_height > max_building_terrain_height:
				continue
			transforms.append(Transform3D(
					Basis().scaled(Vector3(block_pitch, 1.0, road_width)),
					Vector3(x, ground_height + 0.05, z)))

	multimesh.instance_count = transforms.size()
	for idx in transforms.size():
		multimesh.set_instance_transform(idx, transforms[idx])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	# Street tiles are flat slabs lying on the ground — they receive the
	# buildings' shadows but have nothing meaningful to cast, so keeping
	# 1860+ of them out of the shadow pass is free savings.
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


func _generate_buildings() -> void:
	for gx in _grid_count:
		for gz in _grid_count:
			if randf() < skip_chance:
				continue

			# Block CENTER — midway between the road grid lines on either
			# side, not aligned to the roads themselves, so buildings sit
			# inside their block instead of straddling a street.
			var x := _origin.x - _half_total + gx * block_pitch + block_pitch * 0.5 \
					+ randf_range(-building_jitter, building_jitter)
			var z := _origin.z - _half_total + gz * block_pitch + block_pitch * 0.5 \
					+ randf_range(-building_jitter, building_jitter)
			var ground_height: float = _terrain.get_height_at(x, z)

			# THE actual "buildings can't go on mountains" gate — see
			# max_building_terrain_height's own header for the measured
			# heightmap survey behind the chosen value.
			if ground_height > max_building_terrain_height:
				continue

			var is_landmark := randf() < landmark_chance
			var pool := LANDMARK_BUILDINGS if is_landmark else REGULAR_BUILDINGS
			var scene: PackedScene = pool[randi() % pool.size()]
			var scale_min := landmark_scale_min if is_landmark else regular_scale_min
			var scale_max := landmark_scale_max if is_landmark else regular_scale_max

			var model: Dictionary = _model_for(scene)
			var local_aabb: AABB = model["aabb"]

			# Grid-aligned facing (0/90/180/270) — reads as a real city
			# block from a distance instead of randomly-strewn debris.
			var rot_y := float(randi() % 4) * (PI * 0.5)
			# Y-only stretch — see height_multiplier.
			var s := randf_range(scale_min, scale_max)
			var scale_vec := Vector3(s, s * height_multiplier, s)

			if is_landmark:
				var top_y := ground_height + (local_aabb.position.y + local_aabb.size.y) * scale_vec.y
				landmark_rooftops.append(Vector3(x, top_y, z))

			# R * S, matching how Node3D composes a transform (scale applied
			# in local space, then rotated). Basis.scaled() would left-
			# multiply and give S * R, which is NOT the same for a
			# non-uniform scale like this one.
			var basis := Basis.from_euler(Vector3(0.0, rot_y, 0.0)) * Basis.from_scale(scale_vec)
			var world_xform := Transform3D(basis, Vector3(x, ground_height, z))

			# --- collision (still one body per building) ---
			# Physics is unaffected by the rendering change below: a
			# StaticBody3D with a box and no visual child is cheap, and the
			# broadphase doesn't care that the mesh is drawn by a MultiMesh.
			# The scale is baked into the shape rather than applied to the
			# body, so the CollisionShape3D never carries a non-uniform
			# scale (which Godot flags as unsupported).
			var body := StaticBody3D.new()
			body.collision_layer = 1 << (BUILDING_COLLISION_LAYER - 1)
			body.collision_mask = 0
			add_child(body)
			body.position = Vector3(x, ground_height, z)
			body.rotation.y = rot_y

			var collision := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = local_aabb.size * scale_vec
			collision.shape = shape
			collision.position = (local_aabb.position + local_aabb.size * 0.5) * scale_vec
			body.add_child(collision)

			# --- rendering (batched) ---
			var chunk := _chunk_index(x, z)
			var parts_ref: Array = []
			for part in (model["parts"] as Array):
				var part_xform: Transform3D = world_xform * (part["xform"] as Transform3D)
				var slot := _bucket_instance(chunk, part, model["material"], part_xform)
				parts_ref.append({
					"key": slot[0],
					"index": slot[1],
					"mmi": null,  # resolved in _build_building_multimeshes()
					"xform": part_xform,
				})

			# Footprint radius from the measured mesh bounds rather than a
			# guess, so splash queries scale correctly with height_multiplier
			# and the landmark/regular scale split.
			var footprint: Vector3 = local_aabb.size * scale_vec
			buildings.append({
				"pos": Vector3(x, ground_height, z),
				"radius": maxf(footprint.x, footprint.z) * 0.5,
				"height": footprint.y,
				"body": body,
				"parts": parts_ref,
				"sink": 0.0,
				"state": BuildingState.STANDING,
			})


## Places the single hand-tuned landmark described in this file's own
## "Mega tower" export group — see that comment for the full reasoning
## behind the height/diameter targets. Reuses `_model_for()`'s cache (this
## exact model is already loaded regardless, since LANDMARK_BUILDINGS[0]
## is also in the procedural pool), but builds a plain MeshInstance3D per
## part and a standalone StaticBody3D rather than going through the
## batched-MultiMesh / buildings-array machinery built for a population of
## many same-scale instances — this is a genuine one-off, not a member of
## that population.
func _place_mega_tower() -> void:
	var scene: PackedScene = LANDMARK_BUILDINGS[0]
	var model: Dictionary = _model_for(scene)
	var local_aabb: AABB = model["aabb"]

	var ground_height: float = _terrain.get_height_at(
			mega_tower_position_xz.x, mega_tower_position_xz.y)

	# Height and diameter are independent targets (unlike the procedural
	# population's single uniform `s` plus height_multiplier) — this is a
	# hand-tuned one-off, not a member of a population sharing one scale
	# law, so each axis is solved directly against the model's own
	# measured AABB.
	var scale_y := mega_tower_height / maxf(local_aabb.size.y, 0.001)
	var base_diameter := maxf(local_aabb.size.x, local_aabb.size.z)
	var scale_xz := mega_tower_diameter / maxf(base_diameter, 0.001)
	var scale_vec := Vector3(scale_xz, scale_y, scale_xz)

	# Regular buildings place their transform ORIGIN at ground_height and
	# let local_aabb.position.y's own small offset (the model's pivot isn't
	# exactly at its true base) go unnoticed — at their scale (max ~30x)
	# that offset is a few metres, invisible against a building hundreds of
	# metres tall. At this tower's ~200x scale_y, the SAME small offset
	# amplifies into a real, measured 100m gap between the visible base and
	# the actual ground (caught by verification, not assumed fine). Correct
	# for it here: shift the transform origin so the mesh's true LOWER
	# bound — not its pivot — lands exactly on ground_height.
	var world_pos := Vector3(
			mega_tower_position_xz.x,
			ground_height - local_aabb.position.y * scale_y,
			mega_tower_position_xz.y)
	var world_xform := Transform3D(Basis.from_scale(scale_vec), world_pos)

	var material: Material = model["material"]
	for part in (model["parts"] as Array):
		var mi := MeshInstance3D.new()
		mi.mesh = part["mesh"]
		mi.transform = world_xform * (part["xform"] as Transform3D)
		var chosen: Material = material if material != null else part["override"]
		if chosen != null:
			mi.material_override = chosen
		add_child(mi)

	# Same collision convention as every procedural building (same layer,
	# scale baked into the shape rather than a non-uniform body scale) —
	# solid to the same building-collision code paths everything else
	# uses, just not tracked in `buildings`/collapse_near() (see the
	# export group header for why: a permanent monument, not something a
	# nearby tank explosion should sink).
	var body := StaticBody3D.new()
	body.collision_layer = 1 << (BUILDING_COLLISION_LAYER - 1)
	body.collision_mask = 0
	add_child(body)
	body.position = world_pos

	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = local_aabb.size * scale_vec
	collision.shape = shape
	collision.position = (local_aabb.position + local_aabb.size * 0.5) * scale_vec
	body.add_child(collision)


# ---------------------------------------------------------------------------
# Batched building rendering
# ---------------------------------------------------------------------------
#
# Buildings used to be one instantiated scene per building — 745 separate
# node trees, which is 745+ draw calls for a city built from only 18
# distinct meshes. (The street tiles were already batched: 1860 of them cost
# a single draw call through one MultiMeshInstance3D.) Buildings are now
# batched the same way, which is what makes density close to free: adding
# more buildings adds instances to an existing MultiMesh rather than adding
# draw calls.
#
# Measured result: 746 draw calls -> 19 for the entire city.
#
# WHY NOT CHUNKED BY DEFAULT. A MultiMeshInstance3D is frustum-culled as a
# single unit, so one city-wide batch per mesh means the whole city's
# geometry is submitted every frame regardless of where the player looks.
# That sounds bad, and the first version of this therefore split the city
# into a 4x4 grid to preserve culling — which cost ~215 draw calls instead
# of 19. Then the geometry was actually measured: the ENTIRE city is ~26,000
# triangles, because these building models average about 35 triangles each.
# There is nothing for culling to save. The chunking was paying 11x the draw
# calls to protect against a vertex cost that does not exist, so
# `render_chunks` defaults to 1 and the grid is kept only as an escape hatch
# for genuinely heavy building models.
#
# This is the general shape of the answer to "how do we add city density
# without hurting performance": density is now nearly free on the render
# side, because more buildings means more instances in an existing batch,
# not more draw calls. The remaining per-building cost is the collision
# StaticBody3D, which is static and broadphase-accelerated, plus the
# per-frame physics point-queries that faction_battle.gd already gates by
# altitude (see its MAX_BUILDING_HEIGHT).


## Per-scene extraction, cached — every building type is instantiated
## exactly once here regardless of how many copies get placed. Returns
## {"parts": [{"mesh", "xform", "override"}...], "aabb": AABB}, where each
## part's `xform` is that MeshInstance3D's transform relative to the scene
## root (buildings whose mesh is nested under an offset node still land in
## the right place).
func _model_for(scene: PackedScene) -> Dictionary:
	var key := scene.resource_path
	if _model_cache.has(key):
		return _model_cache[key]

	var instance := scene.instantiate()
	var model := {
		"parts": [],
		"aabb": _compute_local_aabb(instance),
		"material": _material_for_scene(scene),
	}
	_collect_parts(instance, Transform3D(), model["parts"])
	instance.free()

	_model_cache[key] = model
	return model


## THE FBX IMPORT DOES NOT BRING THE TEXTURES ACROSS. Every building model
## imports with a material whose albedo_texture is null and whose
## albedo_color is a flat off-white (0.906, 0.906, 0.906) — which is why the
## city rendered as untextured white blocks despite the textures being
## present in Assets/City/Textures the whole time. The meshes themselves do
## carry correct UVs; only the material link is missing. This is a common
## Godot FBX limitation (texture references in FBX are frequently embedded
## or absolute paths from the authoring tool and don't resolve on import).
##
## The filenames map one-to-one by family, so the texture is recovered from
## the model path rather than hand-maintained per building:
##   Models/building_04.2.fbx  ->  Textures/building_04.png
func _material_for_scene(scene: PackedScene) -> StandardMaterial3D:
	var family := scene.resource_path.get_file().split(".")[0]  # "building_04"
	var texture_path := BUILDING_TEXTURE_DIR + family + ".png"
	if not ResourceLoader.exists(texture_path):
		push_warning("CityGenerator: no texture found at %s" % texture_path)
		return null

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(texture_path)
	# Low roughness gives the wet, rain-slicked sheen — buildings catch a
	# specular highlight from the sun instead of reading as flat matte
	# cardboard. See building_roughness.
	mat.roughness = building_roughness
	mat.metallic = 0.0
	mat.metallic_specular = 0.6
	return mat


func _collect_parts(node: Node, xform: Transform3D, parts: Array) -> void:
	if node is Node3D:
		xform = xform * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh:
		var mi := node as MeshInstance3D
		parts.append({
			"mesh": mi.mesh,
			"xform": xform,
			# Carried across so a scene that overrode its mesh's material
			# still looks right once batched.
			"override": mi.material_override,
		})
	for child in node.get_children():
		_collect_parts(child, xform, parts)


## Chunk bucketing now keys off the terrain's own extent (_origin/_half_total)
## rather than city_center — city_center no longer bounds where buildings can
## land, so it stopped being the right origin for this even at the default
## render_chunks=1 (where the result is always chunk 0 regardless).
func _chunk_index(x: float, z: float) -> int:
	var span := _half_total * 2.0
	var cx := clampi(int((x - (_origin.x - _half_total)) / span * float(render_chunks)), 0, render_chunks - 1)
	var cz := clampi(int((z - (_origin.z - _half_total)) / span * float(render_chunks)), 0, render_chunks - 1)
	return cz * render_chunks + cx


## Returns the bucket key and the instance's index within that bucket, so
## _generate_buildings() can remember exactly which MultiMesh slot each part
## of each building ended up in — that pair is what makes a building
## individually movable (and therefore collapsible) later, even though it is
## drawn as part of a shared batch. See `buildings` / collapse_near().
func _bucket_instance(chunk: int, part: Dictionary, material: Material, xform: Transform3D) -> Array:
	var mesh: Mesh = part["mesh"]
	var key := "%d|%d" % [chunk, mesh.get_instance_id()]
	if not _instance_buckets.has(key):
		# The rebuilt textured material wins over whatever the FBX import
		# produced (a textureless white), falling back to any override the
		# source scene actually set.
		var chosen: Material = material if material != null else part["override"]
		_instance_buckets[key] = {
			"mesh": mesh,
			"override": chosen,
			"xforms": [],
		}
	var xforms: Array = (_instance_buckets[key] as Dictionary)["xforms"]
	xforms.append(xform)
	return [key, xforms.size() - 1]


## One MultiMeshInstance3D per (chunk, mesh) pair, built once after all
## buildings have been placed.
func _build_building_multimeshes() -> void:
	for key in _instance_buckets:
		var bucket: Dictionary = _instance_buckets[key]
		var xforms: Array = bucket["xforms"]

		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = bucket["mesh"]
		mm.instance_count = xforms.size()
		for i in xforms.size():
			mm.set_instance_transform(i, xforms[i])
		# Fixed bounds. These batches were write-once and so never dirtied
		# their AABB before, but collapse_near() now rewrites instance
		# transforms at runtime — and a dirty MultiMesh with no custom_aabb
		# recomputes its bounds by walking EVERY instance it owns, which for
		# a single map-wide batch is now many thousands of buildings per
		# frame while anything is sinking. Generous enough to cover the
		# whole terrain footprint including buildings on their way down.
		mm.custom_aabb = _city_batch_aabb

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		if bucket["override"] != null:
			mmi.material_override = bucket["override"]
		add_child(mmi)
		_bucket_mmi[key] = mmi

	_instance_buckets.clear()

	# Buildings recorded their parts as (bucket key, index) pairs during
	# placement, because the MultiMeshInstance3D nodes did not exist yet.
	# Now they do, so swap each reference over to the real node once, here,
	# rather than doing a Dictionary lookup per part on every collapse frame.
	for b in buildings:
		for part in (b["parts"] as Array):
			part["mmi"] = _bucket_mmi.get(part["key"])
	_bucket_mmi.clear()


# ---------------------------------------------------------------------------
# Collapse — buildings sinking into the earth
# ---------------------------------------------------------------------------
#
# Driven by tank_objective.gd: blowing up a fuel tank takes the block down
# with it. Rather than a fracture/physics simulation (which for ~1400 batched
# buildings would be enormous), a doomed building simply DESCENDS — it slides
# straight down into the terrain until it is buried, then stops being drawn.
# That reads as a controlled demolition/sinkhole from the air, costs one
# transform write per part per frame while it moves, and nothing at all once
# it's gone.
#
# Collision sinks WITH the mesh instead of being freed up front, so the
# building stays solid exactly as long as it is still visible — a half-sunk
# tower you can fly through would be worse than either extreme.


## Starts every standing building whose footprint is within `radius` of
## `center` (horizontal distance only — this is a ground blast) sinking.
## Returns how many were newly condemned.
func collapse_near(center: Vector3, radius: float) -> int:
	var started := 0
	for i in buildings.size():
		var b: Dictionary = buildings[i]
		if b["state"] != BuildingState.STANDING:
			continue
		var pos: Vector3 = b["pos"]
		var dx := pos.x - center.x
		var dz := pos.z - center.z
		if dx * dx + dz * dz > (radius + float(b["radius"])) * (radius + float(b["radius"])):
			continue
		b["state"] = BuildingState.COLLAPSING
		_collapsing.append(i)
		started += 1
	if started > 0:
		set_process(true)
		_play_collapse_sound(center)
	return started


## One layered collapse sound per demolition event, positioned at the blast
## centre. Lives here rather than in tank_objective.gd because collapse_near()
## is the general entry point — anything that brings a block down later (a
## bomb, another objective) gets the audio for free instead of each caller
## remembering to play it.
##
## No concurrency cap: this can only fire once per collapse event, and a
## collapse event means a fuel tank just went up. There are 20 of those in a
## whole match, so the natural rate is already the budget — the same
## reasoning tank_objective.gd's own detonation sound uses.
func _play_collapse_sound(at_position: Vector3) -> void:
	if COLLAPSE_SOUNDS.is_empty():
		return
	var player: Node3D = get_node_or_null(player_path) as Node3D
	if player and player.global_position.distance_to(at_position) > collapse_sound_range:
		return

	var stream: AudioStream = _pick_collapse_sound()
	# Deferred rather than immediate — see collapse_sound_delay.
	get_tree().create_timer(collapse_sound_delay).timeout.connect(
			func() -> void:
				if not is_inside_tree():
					return
				var sound := AudioStreamPlayer3D.new()
				get_tree().current_scene.add_child(sound)
				sound.global_position = at_position
				sound.stream = stream
				sound.volume_db = collapse_volume_db
				sound.unit_size = collapse_sound_unit_size
				sound.max_distance = collapse_sound_range
				sound.attenuation_filter_cutoff_hz = collapse_sound_cutoff_hz
				sound.attenuation_filter_db = -30.0
				sound.play()
				sound.finished.connect(sound.queue_free))


func _pick_collapse_sound() -> AudioStream:
	if COLLAPSE_SOUNDS.size() == 1:
		return COLLAPSE_SOUNDS[0]
	var i := randi() % COLLAPSE_SOUNDS.size()
	if i == _last_collapse_sound:
		i = (i + 1 + (randi() % (COLLAPSE_SOUNDS.size() - 1))) % COLLAPSE_SOUNDS.size()
	_last_collapse_sound = i
	return COLLAPSE_SOUNDS[i]


func _process(delta: float) -> void:
	if _collapsing.is_empty():
		set_process(false)
		return

	for n in range(_collapsing.size() - 1, -1, -1):
		var i: int = _collapsing[n]
		var b: Dictionary = buildings[i]
		var total_drop: float = float(b["height"]) + collapse_extra_depth
		b["sink"] = float(b["sink"]) + (total_drop / maxf(collapse_duration, 0.01)) * delta
		var sink: float = b["sink"]
		var buried: bool = sink >= total_drop

		for part in (b["parts"] as Array):
			var mmi: MultiMeshInstance3D = part["mmi"]
			if mmi == null:
				continue
			if buried:
				# Same technique faction_battle.gd uses to hide a dead ship:
				# MultiMesh has no per-instance visibility flag for an
				# arbitrary middle index, so a zero-scale basis is how an
				# instance is removed from view without disturbing anyone
				# else's index.
				mmi.multimesh.set_instance_transform(int(part["index"]),
						Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
			else:
				var xf: Transform3D = part["xform"]
				xf.origin.y -= sink
				mmi.multimesh.set_instance_transform(int(part["index"]), xf)

		var body: Node3D = b["body"]
		if is_instance_valid(body):
			if buried:
				body.queue_free()
			else:
				body.position.y = float((b["pos"] as Vector3).y) - sink

		if buried:
			b["state"] = BuildingState.GONE
			_collapsing.remove_at(n)


## True if (x, z) is clear of every standing building by at least
## `clearance` metres. Used by tank_objective.gd to scatter fuel tanks onto
## open ground/streets instead of inside a tower.
func is_ground_clear(x: float, z: float, clearance: float) -> bool:
	for b in buildings:
		if b["state"] == BuildingState.GONE:
			continue
		var pos: Vector3 = b["pos"]
		var dx := pos.x - x
		var dz := pos.z - z
		var need: float = float(b["radius"]) + clearance
		if dx * dx + dz * dz < need * need:
			return false
	return true


var _model_cache: Dictionary = {}
var _instance_buckets: Dictionary = {}


## Walks a freshly-instantiated (not-yet-reparented) building's mesh nodes
## and merges their AABBs into one, in the building's own local space — used
## to size each collision box automatically instead of hand-maintaining
## per-building-type dimensions that could drift from the actual meshes.
func _compute_local_aabb(node: Node) -> AABB:
	_aabb_accum = AABB()
	_aabb_has_value = false
	_walk_aabb(node, Transform3D())
	return _aabb_accum


var _aabb_accum: AABB
var _aabb_has_value: bool = false


func _walk_aabb(node: Node, xform: Transform3D) -> void:
	if node is Node3D:
		xform = xform * node.transform
	if node is MeshInstance3D and node.mesh:
		var global_aabb: AABB = xform * node.mesh.get_aabb()
		if not _aabb_has_value:
			_aabb_accum = global_aabb
			_aabb_has_value = true
		else:
			_aabb_accum = _aabb_accum.merge(global_aabb)
	for child in node.get_children():
		_walk_aabb(child, xform)
