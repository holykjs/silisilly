extends Control

# Export buttons so you can assign them in the Inspector
@export var host_btn: Button
@export var join_btn: Button
@export var quit_btn: Button
@export var ip_input: LineEdit

# UI feedback
var status_label: Label

func _ready() -> void:
	# Connect signals safely
	host_btn.pressed.connect(_on_host_pressed)
	join_btn.pressed.connect(_on_join_pressed)
	quit_btn.pressed.connect(_on_quit_pressed)
	
	# Create status label for feedback
	status_label = Label.new()
	status_label.text = ""
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	status_label.position = Vector2(400, 400)
	status_label.size = Vector2(400, 50)
	add_child(status_label)

func _on_host_pressed() -> void:
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

func _on_quit_pressed() -> void:
	get_tree().quit()
