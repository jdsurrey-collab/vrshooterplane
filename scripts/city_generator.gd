class_name CityGenerator
extends Node3D

## Procedurally builds a city block grid near the starting area: a lattice
## of streets (roads.tscn-free — built directly as GPU-instanced tiles, see
## _generate_roads) with skyscrapers from the "skyscraper_pack" asset set
## centered in each block, facing the grid instead of randomly rotated.
## That grid alignment is what actually reads as "a city" from a distance —
## the previous version scattered buildings with full random rotation and
## no street pattern, which just looked like debris from far away.
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

const BUILDING_COLLISION_LAYER := 10

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
@export var city_center: Vector3 = Vector3(6000.0, 0.0, 0.0)
## DENSITY WITHOUT SPRAWL. grid_size and block_pitch are deliberately
## inverse to one another: the city's overall footprint is
## `grid_size * block_pitch` (10800m across, unchanged since the first
## version), so packing more blocks in means shrinking the block pitch by
## the same factor rather than extending the grid outward. 24 blocks at
## 450m and 30 blocks at 360m cover exactly the same ground.
##
## Changing either of these WITHOUT compensating the other changes the
## city's real size, which would move the goalposts for
## `FactionBattle.dome_radius` (8000m, sized against the city's ~7637m
## half-diagonal).
@export var grid_size: int = 30  # grid_size x grid_size city blocks
@export var block_pitch: float = 360.0  # distance between street centerlines
@export var road_width: float = 30.0
@export var building_jitter: float = 30.0  # small — buildings should still read as grid-aligned, and blocks are tighter now
## Tuned alongside grid_size so the actual building count lands on the
## intended increase rather than the raw block count: 30x30 at 0.18 skip
## gives ~738 buildings against the previous 24x24 at 0.15's ~490, i.e.
## +50%.
@export var skip_chance: float = 0.18  # leave some blocks empty (plazas/lots)
@export var landmark_chance: float = 0.08  # fraction of filled blocks that go supertall
@export var regular_scale_min: float = 1.0
@export var regular_scale_max: float = 2.5
@export var landmark_scale_min: float = 3.5  # ~125m base * 3.5 = 437m, comfortably 400m+
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
## 5.0 * 2.0 = ~1250m.
@export var height_multiplier: float = 2.0

## Buildings are drawn as batched MultiMeshes, optionally split into a
## render_chunks x render_chunks grid. Higher values improve frustum culling
## but multiply draw calls (each chunk needs its own batch per mesh type);
## 1 means a single city-wide batch per mesh — fewest possible draw calls,
## no per-district culling.
##
## DEFAULT IS 1, and that is a measured decision rather than a guess: the
## entire city's building geometry is only ~26,000 triangles (these models
## average ~35 triangles each — they are very low-poly boxes). Submitting
## all of it every frame costs essentially nothing, so there is nothing for
## culling to save, and 4x4 chunking was costing ~215 draw calls to protect
## against a vertex cost that doesn't exist. Raise this only if the building
## models are ever replaced with something genuinely heavy.
@export var render_chunks: int = 1

var _terrain: Node


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)
	if not _terrain:
		return

	_generate_roads()
	_generate_buildings()
	# Buildings are only bucketed during placement; this turns the buckets
	# into the actual MultiMeshInstance3D nodes.
	_build_building_multimeshes()


func _generate_roads() -> void:
	var half_total := grid_size * block_pitch * 0.5

	var road_material := StandardMaterial3D.new()
	road_material.albedo_color = Color(0.08, 0.08, 0.09)
	road_material.roughness = 0.9

	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(1.0, 0.15, 1.0)  # unit size — scaled per-instance below
	tile_mesh.material = road_material

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = tile_mesh

	var transforms: Array[Transform3D] = []

	# Streets running along Z, at each of the grid_size+1 X-grid-lines —
	# one tile per block along the street's length, not one long strip.
	for i in range(grid_size + 1):
		var x := city_center.x - half_total + i * block_pitch
		for j in grid_size:
			var z := city_center.z - half_total + j * block_pitch + block_pitch * 0.5
			var ground_height: float = _terrain.get_height_at(x, z)
			transforms.append(Transform3D(
					Basis().scaled(Vector3(road_width, 1.0, block_pitch)),
					Vector3(x, ground_height + 0.05, z)))

	# Streets running along X, at each of the grid_size+1 Z-grid-lines.
	for j in range(grid_size + 1):
		var z := city_center.z - half_total + j * block_pitch
		for i in grid_size:
			var x := city_center.x - half_total + i * block_pitch + block_pitch * 0.5
			var ground_height: float = _terrain.get_height_at(x, z)
			transforms.append(Transform3D(
					Basis().scaled(Vector3(block_pitch, 1.0, road_width)),
					Vector3(x, ground_height + 0.05, z)))

	multimesh.instance_count = transforms.size()
	for idx in transforms.size():
		multimesh.set_instance_transform(idx, transforms[idx])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = multimesh
	add_child(mmi)


func _generate_buildings() -> void:
	var half_total := grid_size * block_pitch * 0.5

	for gx in grid_size:
		for gz in grid_size:
			if randf() < skip_chance:
				continue

			# Block CENTER — midway between the road grid lines on either
			# side, not aligned to the roads themselves, so buildings sit
			# inside their block instead of straddling a street.
			var x := city_center.x - half_total + gx * block_pitch + block_pitch * 0.5 \
					+ randf_range(-building_jitter, building_jitter)
			var z := city_center.z - half_total + gz * block_pitch + block_pitch * 0.5 \
					+ randf_range(-building_jitter, building_jitter)
			var ground_height: float = _terrain.get_height_at(x, z)

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
			var chunk := _chunk_index(x, z, half_total)
			for part in (model["parts"] as Array):
				_bucket_instance(chunk, part, world_xform * (part["xform"] as Transform3D))


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
	}
	_collect_parts(instance, Transform3D(), model["parts"])
	instance.free()

	_model_cache[key] = model
	return model


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


func _chunk_index(x: float, z: float, half_total: float) -> int:
	var span := half_total * 2.0
	var cx := clampi(int((x - (city_center.x - half_total)) / span * float(render_chunks)), 0, render_chunks - 1)
	var cz := clampi(int((z - (city_center.z - half_total)) / span * float(render_chunks)), 0, render_chunks - 1)
	return cz * render_chunks + cx


func _bucket_instance(chunk: int, part: Dictionary, xform: Transform3D) -> void:
	var mesh: Mesh = part["mesh"]
	var key := "%d|%d" % [chunk, mesh.get_instance_id()]
	if not _instance_buckets.has(key):
		_instance_buckets[key] = {
			"mesh": mesh,
			"override": part["override"],
			"xforms": [],
		}
	((_instance_buckets[key] as Dictionary)["xforms"] as Array).append(xform)


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

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		if bucket["override"] != null:
			mmi.material_override = bucket["override"]
		add_child(mmi)

	_instance_buckets.clear()


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
