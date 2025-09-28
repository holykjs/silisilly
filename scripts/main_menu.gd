extends Control

# Export buttons so you can assign them in the Inspector
@export var host_btn: Button
@export var join_btn: Button
@export var single_player_btn: Button
@export var quit_btn: Button
@export var ip_input: LineEdit

# UI feedback
var status_label: Label

# Background music (now handled by AudioManager)
# @onready var background_music: AudioStreamPlayer = $BackgroundMusic

func _ready() -> void:
	# Connect signals safely
	host_btn.pressed.connect(_on_host_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	if single_player_btn:
		single_player_btn.pressed.connect(_on_single_player_pressed)
	quit_btn.pressed.connect(_on_quit_pressed)
	
	# Create status label for feedback
	status_label = Label.new()
	status_label.text = ""
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.position = Vector2(400, 400)
	status_label.size = Vector2(400, 50)
	add_child(status_label)
	
	# Start menu music via AudioManager
	if has_node("/root/AudioManager"):
		AudioManager.play_menu_music()
	else:
		print("[MainMenu] AudioManager not found - add it as autoload in Project Settings")

func _on_host_pressed() -> void:
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	# Start hosting
	status_label.text = "Starting server..."
	var success = NetworkLobby.host_game()
	if success:
		status_label.text = "Server started! Waiting for players..."
		await get_tree().create_timer(1.0).timeout  # Brief delay to show message
		get_tree().change_scene_to_file("res://scenes/Lobby.tscn")
	else:
		status_label.text = "Failed to start server. Check if port 52000 is available."

func _on_join_pressed() -> void:
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	# Use IP from input, fallback to localhost
	var ip = ip_input.text.strip_edges()
	if ip == "":
		ip = "127.0.0.1"
	
	status_label.text = "Connecting to %s..." % ip
	var success = NetworkLobby.join_game(ip)
	if success:
		status_label.text = "Connecting..."
		# Wait a moment to see if connection succeeds
		await get_tree().create_timer(2.0).timeout
		# Check if we're actually connected
		if multiplayer.has_multiplayer_peer() and multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			get_tree().change_scene_to_file("res://scenes/Lobby.tscn")
		else:
			status_label.text = "Connection failed. Check IP address and try again."
	else:
		status_label.text = "Failed to connect. Check IP address."

func _on_single_player_pressed() -> void:
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	print("[MainMenu] Single Player button clicked!")
	# Go directly to single-player lobby or start game
	status_label.text = "Starting Single Player..."
	
	# Check if SinglePlayerManager exists (autoload added)
	if has_node("/root/SinglePlayerManager"):
		get_node("/root/SinglePlayerManager").setup_game(4, "Normal")
		print("[MainMenu] SinglePlayerManager found and configured")
	else:
		print("[MainMenu] SinglePlayerManager autoload not found - add it in Project Settings > Autoload")
	
	print("[MainMenu] Waiting 0.5 seconds...")
	await get_tree().create_timer(0.5).timeout
	
	# Start single-player music immediately
	if has_node("/root/AudioManager"):
		AudioManager.play_single_player_music()
		print("[MainMenu] Started single-player BGM")
	
	# Randomly select a map for single-player
	var available_maps = ["Map1", "Map2", "Map3"]
	var random_map = available_maps[randi() % available_maps.size()]
	print("[MainMenu] Loading random map:", random_map)
	get_tree().change_scene_to_file("res://maps/" + random_map + ".tscn")

func _on_quit_pressed() -> void:
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	get_tree().quit()
