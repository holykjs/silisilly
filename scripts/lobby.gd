extends Control

@onready var map_option := $VBoxContainer/MapOption
@onready var start_button := $VBoxContainer/StartButton

func _ready():
	# enable/disable UI depending on whether this instance is host
	_update_ui()
	# connect UI signals
	map_option.item_selected.connect(_on_map_selected)
	start_button.pressed.connect(_on_start_pressed)

func _update_ui():
	start_button.disabled = not multiplayer.is_server()
	map_option.disabled = not multiplayer.is_server()

func _on_map_selected(idx):
	if multiplayer.is_server():
		var map_name = map_option.get_item_text(idx)
		NetworkLobby.set_selected_map(map_name)

func _on_start_pressed():
	if multiplayer.is_server():
		NetworkLobby.start_game()
