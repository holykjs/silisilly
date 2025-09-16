extends Control

@onready var map_selection_container := $"MapSelectionContainer"
@onready var start_button := $StartButton

# Map names to scene paths (auto-detected)
var map_scenes = {
	"Map1": "res://maps/Map1.tscn",
	"Map2": "res://maps/Map2.tscn",
	"Map3": "res://maps/Map3.tscn",
}

var selected_map : String = "Map1"

func _ready():
	_update_ui()

	# Connect map buttons
	for button in map_selection_container.get_children():
		if button is TextureButton:
			button.pressed.connect(_on_map_selected.bind(button))

	# Connect start button
	start_button.pressed.connect(_on_start_pressed)

func _update_ui():
	start_button.disabled = not multiplayer.is_server()
	# only server chooses maps, disable buttons for clients
	for button in map_selection_container.get_children():
		if button is TextureButton:
			button.disabled = not multiplayer.is_server()

func _on_map_selected(button: TextureButton):
	if multiplayer.is_server():
		selected_map = button.name.replace("Button", "") # e.g. "Map1Button" → "Map1"
		print("Selected map: ", selected_map)
		NetworkLobby.set_selected_map(selected_map)

func _on_start_pressed():
	if multiplayer.is_server():
		NetworkLobby.start_game()
		if selected_map in map_scenes:
			get_tree().change_scene_to_file(map_scenes[selected_map])
		else:
			print("Error: Selected map not found!")
