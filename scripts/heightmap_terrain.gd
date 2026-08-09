extends StaticBody3D

@export var raw_path: String = "res://Assets/Terrain/heightmap.raw16"
@export var texture_path: String = "res://Assets/Terrain/colormap.png"
@export var world_size: float = 500.0
@export var height_scale: float = 80.0
@export var mesh_stride: int = 2
@export var reposition_player: bool = true
@export var player_spawn_height_offset: float = 102.0  # +100m above the old 2.0
## World X/Z the player spawns at — matches faction_battle.gd's
## friendly_spawn_center (city_center + (-10000, 0)) so the player launches
## alongside their own squadron instead of alone at the world origin. Kept
## as a plain exported value rather than read live from FactionBattle to
## avoid a _ready()-order dependency between the two scripts; update this
## by hand if the friendly spawn formula in faction_battle.gd ever changes.
@export var spawn_position_xz: Vector2 = Vector2.ZERO

var _height_grid: PackedFloat32Array
var _sampled_w: int = 0
var _sampled_h: int = 0
var _spacing_x: float = 1.0
var _spacing_z: float = 1.0


func _ready() -> void:
	var file := FileAccess.open(raw_path, FileAccess.READ)
	if file == null:
		push_error("Could not open heightmap raw file: " + raw_path)
		return

	var src_w := int(file.get_32())
	var src_h := int(file.get_32())
	var heights01 := PackedFloat32Array()
	heights01.resize(src_w * src_h)
	for i in src_w * src_h:
		heights01[i] = file.get_16() / 65535.0
	file.close()

	var sampled_w := int((src_w - 1) / mesh_stride) + 1
	var sampled_h := int((src_h - 1) / mesh_stride) + 1
	var spacing_x := world_size / float(sampled_w - 1)
	var spacing_z := world_size / float(sampled_h - 1)
	_sampled_w = sampled_w
	_sampled_h = sampled_h
	_spacing_x = spacing_x
	_spacing_z = spacing_z

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(sampled_w * sampled_h)
	normals.resize(sampled_w * sampled_h)
	uvs.resize(sampled_w * sampled_h)

	var height_grid := PackedFloat32Array()
	height_grid.resize(sampled_w * sampled_h)

	for iz in sampled_h:
		var src_z: int = min(iz * mesh_stride, src_h - 1)
		for ix in sampled_w:
			var src_x: int = min(ix * mesh_stride, src_w - 1)
			var h01: float = heights01[src_z * src_w + src_x]
			var world_y: float = h01 * height_scale
			var idx := iz * sampled_w + ix
			var x := (ix - (sampled_w - 1) * 0.5) * spacing_x
			var z := (iz - (sampled_h - 1) * 0.5) * spacing_z
			verts[idx] = Vector3(x, world_y, z)
			uvs[idx] = Vector2(float(ix) / float(sampled_w - 1), float(iz) / float(sampled_h - 1))
			height_grid[idx] = world_y

	_height_grid = height_grid

	for iz in sampled_h:
		for ix in sampled_w:
			var idx := iz * sampled_w + ix
			var hl: float = height_grid[iz * sampled_w + max(ix - 1, 0)]
			var hr: float = height_grid[iz * sampled_w + min(ix + 1, sampled_w - 1)]
			var hd: float = height_grid[max(iz - 1, 0) * sampled_w + ix]
			var hu: float = height_grid[min(iz + 1, sampled_h - 1) * sampled_w + ix]
			var dx: float = (hr - hl) / (2.0 * spacing_x)
			var dz: float = (hu - hd) / (2.0 * spacing_z)
			normals[idx] = Vector3(-dx, 1.0, -dz).normalized()

	for iz in sampled_h - 1:
		for ix in sampled_w - 1:
			var i0 := iz * sampled_w + ix
			var i1 := i0 + 1
			var i2 := i0 + sampled_w
			var i3 := i2 + 1
			indices.append(i0); indices.append(i1); indices.append(i2)
			indices.append(i1); indices.append(i3); indices.append(i2)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = load(texture_path)
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	array_mesh.surface_set_material(0, mat)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = array_mesh
	add_child(mesh_instance)

	var shape := HeightMapShape3D.new()
	shape.map_width = sampled_w
	shape.map_depth = sampled_h
	shape.map_data = height_grid

	var collision := CollisionShape3D.new()
	collision.shape = shape
	collision.transform = Transform3D(Basis().scaled(Vector3(spacing_x, 1.0, spacing_z)), Vector3.ZERO)
	add_child(collision)

	print("[Terrain] sampled_w=", sampled_w, " sampled_h=", sampled_h, " spacing_x=", spacing_x, " spacing_z=", spacing_z)
	print("[Terrain] world_size=", world_size, " height_scale=", height_scale)

	if reposition_player:
		var player := get_node_or_null("../Player")
		print("[Terrain] player found=", player)
		if player:
			var spawn_h: float = get_height_at(spawn_position_xz.x, spawn_position_xz.y)
			print("[Terrain] spawn_h=", spawn_h)
			var target := Transform3D(Basis(), Vector3(spawn_position_xz.x, spawn_h + player_spawn_height_offset, spawn_position_xz.y))
			var player_body := player.get_node_or_null("PlayerBody")
			print("[Terrain] player_body found=", player_body, " has teleport=", player_body.has_method("teleport") if player_body else "n/a")
			if player_body and player_body.has_method("teleport"):
				player_body.teleport(target)
			else:
				player.global_position = target.origin
			print("[Terrain] after reposition: player.global_position=", player.global_position, " player_body.global_position=", player_body.global_position if player_body else "n/a")

			await get_tree().physics_frame
			await get_tree().physics_frame
			await get_tree().physics_frame
			print("[Terrain] +3 physics frames: player.global_position=", player.global_position, " player_body.global_position=", player_body.global_position if player_body else "n/a")


## World-space (x, z) -> terrain surface height (world Y), sampled from the
## same height_grid used to build the collision mesh. Used for kinematic
## ground-hit detection (the ship has no physics body of its own — see
## crash_handler.gd) instead of a raycast against the collision shape.
func get_height_at(world_x: float, world_z: float) -> float:
	if _height_grid.is_empty():
		return 0.0
	var ix := int(roundi(world_x / _spacing_x + (_sampled_w - 1) * 0.5))
	var iz := int(roundi(world_z / _spacing_z + (_sampled_h - 1) * 0.5))
	ix = clampi(ix, 0, _sampled_w - 1)
	iz = clampi(iz, 0, _sampled_h - 1)
	return _height_grid[iz * _sampled_w + ix]
