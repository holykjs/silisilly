extends Control

@onready var map_option := $MapOption
@onready var start_button := $StartButton

# Map names to scene paths (auto-detected)
var map_scenes = {}

func _ready():
	_update_ui()
	_load_maps()  # auto-detect maps
	map_option.item_selected.connect(_on_map_selected)
	start_button.pressed.connect(_on_start_pressed)

func _update_ui():
	start_button.disabled = not multiplayer.is_server()
	map_option.disabled = not multiplayer.is_server()

func _load_maps():
	map_option.clear()
	var dir = DirAccess.open("res://maps")
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if file_name.ends_with(".tscn"):
				var map_name = file_name.get_basename()  # remove .tscn
				var map_path = "res://maps/" + file_name
				map_scenes[map_name] = map_path
				map_option.add_item(map_name)
			file_name = dir.get_next()
		dir.list_dir_end()
	else:
		print("Error: Could not open maps folder!")

func _on_map_selected(idx):
	if multiplayer.is_server():
		var map_name = map_option.get_item_text(idx)
		NetworkLobby.set_selected_map(map_name)

func _on_start_pressed():
	if multiplayer.is_server():
		NetworkLobby.start_game()
		# Load the selected map locally as well
		var selected_map = NetworkLobby.get_selected_map()
		if selected_map in map_scenes:
			# Use change_scene_to_file with path (Godot 4)
			get_tree().change_scene_to_file(map_scenes[selected_map])
		else:
			print("Error: Selected map not found!")
