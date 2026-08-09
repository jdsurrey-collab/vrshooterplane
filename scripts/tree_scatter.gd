extends Node3D

@export var ground_size: Vector2 = Vector2(280, 280)
@export var spawn_clear_radius: float = 8.0
@export var big_tree_count: int = 120
@export var small_tree_count: int = 180
@export var rng_seed: int = 12345

const TREE_BIG := "res://Assets/Trees/tree_big.gltf"
const TREE_SMALL := "res://Assets/Trees/tree_small.gltf"


func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	_spawn_type(TREE_BIG, big_tree_count, rng)
	_spawn_type(TREE_SMALL, small_tree_count, rng)


func _spawn_type(scene_path: String, count: int, rng: RandomNumberGenerator) -> void:
	var packed: PackedScene = load(scene_path)
	var temp := packed.instantiate()
	add_child(temp)

	var mesh_instances: Array[MeshInstance3D] = []
	_collect_mesh_instances(temp, mesh_instances)
	var to_local := global_transform.affine_inverse()

	var placements: Array[Transform3D] = []
	for i in count:
		var x := rng.randf_range(-ground_size.x * 0.5, ground_size.x * 0.5)
		var z := rng.randf_range(-ground_size.y * 0.5, ground_size.y * 0.5)
		while Vector2(x, z).length() < spawn_clear_radius:
			x = rng.randf_range(-ground_size.x * 0.5, ground_size.x * 0.5)
			z = rng.randf_range(-ground_size.y * 0.5, ground_size.y * 0.5)
		var rot_y := rng.randf_range(0.0, TAU)
		var s := rng.randf_range(0.8, 1.3)
		var basis := Basis.IDENTITY.rotated(Vector3.UP, rot_y).scaled(Vector3(s, s, s))
		placements.append(Transform3D(basis, Vector3(x, 0.0, z)))

	for mi in mesh_instances:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mi.mesh
		mm.instance_count = placements.size()
		var mesh_local := to_local * mi.global_transform
		for i in placements.size():
			mm.set_instance_transform(i, placements[i] * mesh_local)

		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		add_child(mmi)

	remove_child(temp)
	temp.queue_free()


func _collect_mesh_instances(node: Node, out_list: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out_list.append(node)
	for child in node.get_children():
		_collect_mesh_instances(child, out_list)
