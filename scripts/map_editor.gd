extends Node3D

## Manages the in-VR map editor: spawning placeables from the wrist menu,
## letting the player adjust height/scale while holding an object (via
## thumbstick), snapping to the terrain on release, and saving/loading the
## placed-object layout to disk.

@export var terrain_collision_mask: int = 1
@export var scale_speed: float = 1.0
@export var height_speed: float = 1.0
@export var min_scale: float = 0.2
@export var max_scale: float = 5.0
@export var stick_deadzone: float = 0.15

const SAVE_PATH := "user://saves/world.json"

var _placed_objects: Node3D
var _menu: Control
var _right_pickup: XRToolsFunctionPickup
var _left_pickup: XRToolsFunctionPickup
var _right_movement: Node
var _left_movement: Node

var _prev_held: Dictionary = {}
var _height_offsets: Dictionary = {}


func _ready() -> void:
	_placed_objects = Node3D.new()
	_placed_objects.name = "PlacedObjects"
	add_child(_placed_objects)

	var player := get_node("../Player")
	_right_pickup = player.get_node_or_null("RightHand/FunctionPickup")
	_left_pickup = player.get_node_or_null("LeftHand/FunctionPickup")
	_right_movement = player.get_node_or_null("RightHand/MovementTurn")
	_left_movement = player.get_node_or_null("LeftHand/MovementDirect")

	var wrist_menu: XRToolsViewport2DIn3D = player.get_node_or_null(
			"LeftHand/WristMenu/Viewport2Din3D")
	if wrist_menu:
		await get_tree().process_frame
		_menu = wrist_menu.get_scene_instance()
		if _menu:
			wrist_menu.connect_scene_signal("item_selected", _on_item_selected)
			wrist_menu.connect_scene_signal("save_pressed", _on_save_pressed)
			wrist_menu.connect_scene_signal("clear_pressed", _on_clear_pressed)

	_load_world()


func _process(delta: float) -> void:
	_process_hand(_right_pickup, _right_movement, delta)
	_process_hand(_left_pickup, _left_movement, delta)


func _process_hand(pickup: XRToolsFunctionPickup, movement: Node, delta: float) -> void:
	if pickup == null:
		return

	var held: Node3D = pickup.picked_up_object
	var was_held: Node3D = _prev_held.get(pickup, null)

	if held != null:
		if was_held == null:
			_height_offsets[held] = 0.0
		if movement:
			movement.enabled = false
		_adjust_held(pickup, held, delta)
	else:
		if movement:
			movement.enabled = true
		if was_held != null:
			_on_released(was_held)

	_prev_held[pickup] = held


func _adjust_held(pickup: XRToolsFunctionPickup, held: Node3D, delta: float) -> void:
	var controller := pickup.get_controller()
	if controller == null or not controller.get_is_active():
		return

	var stick: Vector2 = controller.get_vector2("primary")

	if absf(stick.y) > stick_deadzone:
		var offset: float = _height_offsets.get(held, 0.0)
		_height_offsets[held] = offset + stick.y * height_speed * delta

	if absf(stick.x) > stick_deadzone:
		var new_scale: float = clampf(
				held.scale.x + stick.x * scale_speed * delta, min_scale, max_scale)
		held.scale = Vector3(new_scale, new_scale, new_scale)


func _on_released(obj: Node3D) -> void:
	if not is_instance_valid(obj):
		return

	var offset: float = _height_offsets.get(obj, 0.0)
	var ground_y = _raycast_ground(obj.global_position)
	if ground_y != null:
		obj.global_position = Vector3(obj.global_position.x, ground_y + offset, obj.global_position.z)

	if obj is RigidBody3D:
		obj.freeze = true
		obj.linear_velocity = Vector3.ZERO
		obj.angular_velocity = Vector3.ZERO

	_height_offsets.erase(obj)


func _raycast_ground(from_pos: Vector3):
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
			from_pos + Vector3.UP * 500.0,
			from_pos + Vector3.DOWN * 500.0)
	query.collision_mask = terrain_collision_mask
	var result: Dictionary = space.intersect_ray(query)
	if result.is_empty():
		return null
	return result.position.y


func _on_item_selected(scene_path: String) -> void:
	if not ResourceLoader.exists(scene_path):
		return
	var packed: PackedScene = load(scene_path)
	var inst: Node3D = packed.instantiate()
	_placed_objects.add_child(inst)

	var spawn_pickup: XRToolsFunctionPickup = _right_pickup if _right_pickup else _left_pickup
	if spawn_pickup == null:
		inst.queue_free()
		return

	inst.global_transform = spawn_pickup.global_transform
	spawn_pickup._pick_up_object(inst)

	if _menu:
		_menu.set_status("Placing: " + scene_path.get_file().get_basename())


func _on_save_pressed() -> void:
	_save_world()
	if _menu:
		_menu.set_status("Saved.")


func _on_clear_pressed() -> void:
	if _right_pickup and is_instance_valid(_right_pickup.picked_up_object):
		_right_pickup.drop_object()
	if _left_pickup and is_instance_valid(_left_pickup.picked_up_object):
		_left_pickup.drop_object()
	if _menu:
		_menu.set_status("Ready")


func _save_world() -> void:
	var data: Array = []
	for obj in _placed_objects.get_children():
		if obj.scene_file_path == "":
			continue
		data.append({
			"scene_path": obj.scene_file_path,
			"position": [obj.global_position.x, obj.global_position.y, obj.global_position.z],
			"rotation_y": obj.rotation.y,
			"scale": obj.scale.x,
		})

	DirAccess.make_dir_recursive_absolute("user://saves")
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data))
		file.close()


func _load_world() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return

	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if not file:
		return
	var text := file.get_as_text()
	file.close()

	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_ARRAY:
		return

	for entry in parsed:
		var scene_path: String = entry.get("scene_path", "")
		if scene_path == "" or not ResourceLoader.exists(scene_path):
			continue
		var packed: PackedScene = load(scene_path)
		var inst: Node3D = packed.instantiate()
		_placed_objects.add_child(inst)

		var pos: Array = entry.get("position", [0.0, 0.0, 0.0])
		inst.global_position = Vector3(pos[0], pos[1], pos[2])
		inst.rotation.y = entry.get("rotation_y", 0.0)
		var s: float = entry.get("scale", 1.0)
		inst.scale = Vector3(s, s, s)
		if inst is RigidBody3D:
			inst.freeze = true
