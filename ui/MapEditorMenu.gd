extends Control

## Emitted when the player picks a placeable from the catalog list.
## `scene_path` points at a wrapper .tscn under CATALOG_DIR.
signal item_selected(scene_path: String)

## Emitted when the player presses the Save button.
signal save_pressed

## Emitted when the player presses the Clear (deselect) button.
signal clear_pressed

const CATALOG_DIR := "res://Assets/Placeables/Trees/"

@onready var _list: VBoxContainer = %ItemList
@onready var _status: Label = %StatusLabel


func _ready() -> void:
	_populate_catalog()


func set_status(text: String) -> void:
	if _status:
		_status.text = text


func _populate_catalog() -> void:
	for child in _list.get_children():
		child.queue_free()

	var dir := DirAccess.open(CATALOG_DIR)
	if dir == null:
		push_warning("MapEditorMenu: could not open catalog dir " + CATALOG_DIR)
		return

	dir.list_dir_begin()
	var file_name := dir.get_next()
	var found: Array[String] = []
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tscn"):
			found.append(file_name)
		file_name = dir.get_next()
	dir.list_dir_end()

	found.sort()
	for fname in found:
		var scene_path := CATALOG_DIR + fname
		var display_name := fname.get_basename()
		var button := Button.new()
		button.text = display_name
		button.custom_minimum_size = Vector2(0, 40)
		button.pressed.connect(func(): item_selected.emit(scene_path))
		_list.add_child(button)


func _on_save_button_pressed() -> void:
	save_pressed.emit()


func _on_clear_button_pressed() -> void:
	clear_pressed.emit()
