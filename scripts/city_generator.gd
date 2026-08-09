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
@export var grid_size: int = 24  # grid_size x grid_size city blocks
@export var block_pitch: float = 450.0  # distance between street centerlines
@export var road_width: float = 30.0
@export var building_jitter: float = 40.0  # small — buildings should still read as grid-aligned
@export var skip_chance: float = 0.15  # leave some blocks empty (plazas/lots)
@export var landmark_chance: float = 0.08  # fraction of filled blocks that go supertall
@export var regular_scale_min: float = 1.0
@export var regular_scale_max: float = 2.5
@export var landmark_scale_min: float = 3.5  # ~125m base * 3.5 = 437m, comfortably 400m+
@export var landmark_scale_max: float = 5.0

var _terrain: Node


func _ready() -> void:
	_terrain = get_node_or_null(terrain_path)
	if not _terrain:
		return

	_generate_roads()
	_generate_buildings()


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

			var building := scene.instantiate()
			var local_aabb := _compute_local_aabb(building)

			var body := StaticBody3D.new()
			body.collision_layer = 1 << (BUILDING_COLLISION_LAYER - 1)
			body.collision_mask = 0
			add_child(body)
			body.position = Vector3(x, ground_height, z)
			# Grid-aligned facing (0/90/180/270) — reads as a real city
			# block from a distance instead of randomly-strewn debris.
			body.rotation.y = (randi() % 4) * (PI * 0.5)
			body.scale = Vector3.ONE * randf_range(scale_min, scale_max)

			body.add_child(building)

			var collision := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = local_aabb.size
			collision.shape = shape
			collision.position = local_aabb.position + local_aabb.size * 0.5
			body.add_child(collision)


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
