extends Control

# Export buttons so you can assign them in the Inspector
@export var host_btn: Button
@export var join_btn: Button
@export var quit_btn: Button
@export var ip_input: LineEdit

func _ready() -> void:
	# Connect signals safely
	host_btn.pressed.connect(_on_host_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	quit_btn.pressed.connect(_on_quit_pressed)

func _on_host_pressed() -> void:
	# Start hosting
	NetworkLobby.host_game()
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")

func _on_join_pressed() -> void:
	# Use IP from input, fallback to localhost
	var ip = ip_input.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	NetworkLobby.join_game(ip)
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")

func _on_quit_pressed() -> void:
	get_tree().quit()
