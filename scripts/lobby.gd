extends Control

@onready var map_selection_container := $"MapSelectionContainer"
@onready var start_button := $StartButton
@onready var player_list := $PlayerList
@onready var lobby_label := $Label
@onready var back_button := $BackButton
# Background music now handled by AudioManager
# @onready var background_music: AudioStreamPlayer = $BackgroundMusic
var _ui_timer: Timer

# Map names to scene paths (auto-detected)
var map_scenes = {
	"Map1": "res://maps/Map1.tscn",
	"Map2": "res://maps/Map2.tscn",
	"Map3": "res://maps/Map3.tscn",
}

var selected_map : String = "Map1"

func _ready():
	_update_ui()
	
	# Start menu music via AudioManager (continues from MainMenu)
	if has_node("/root/AudioManager"):
		AudioManager.play_menu_music()
	else:
		print("[Lobby] AudioManager not found - add it as autoload in Project Settings")

	# Connect map buttons
	for button in map_selection_container.get_children():
		if button is TextureButton:
			button.pressed.connect(_on_map_selected.bind(button))

	# Connect start button
	start_button.pressed.connect(_on_start_pressed)
	
	# Connect back button
	back_button.pressed.connect(_on_back_pressed)
	
	# Connect to NetworkLobby signals for player list updates
	if not NetworkLobby.player_list_changed.is_connected(_update_player_list):
		NetworkLobby.player_list_changed.connect(_update_player_list)
		print("[Lobby] Connected to player_list_changed signal")
	if not NetworkLobby.player_list_changed.is_connected(_update_ui):
		NetworkLobby.player_list_changed.connect(_update_ui)
		print("[Lobby] Connected to player_list_changed for UI updates")
	
	# Initial player list update
	_update_player_list()
	# Defer another UI update to ensure autoload values (like local_ip) are ready
	call_deferred("_update_ui")
	# Also schedule a short delayed update in case the peer initializes just after scene change
	var _timer := get_tree().create_timer(0.5)
	_timer.timeout.connect(_update_ui)
	_timer.timeout.connect(func(): print("[Lobby] _update_ui (delayed) is_server=", multiplayer.is_server(), " has_peer=", multiplayer.has_multiplayer_peer(), " ip=", NetworkLobby.get_local_ip()))
	_timer.timeout.connect(func(): _update_ui())

	# Add a lightweight polling timer to keep the header fresh while in Lobby
	_ui_timer = Timer.new()
	_ui_timer.wait_time = 1.0
	_ui_timer.autostart = true
	_ui_timer.one_shot = false
	add_child(_ui_timer)
	_ui_timer.timeout.connect(_update_ui)

func _update_ui():
	print("[Lobby] _update_ui is_server=", multiplayer.is_server(), " has_peer=", multiplayer.has_multiplayer_peer(), " ip=", NetworkLobby.get_local_ip())
	start_button.disabled = not multiplayer.is_server()
	# only server chooses maps, disable buttons for clients
	for button in map_selection_container.get_children():
		if button is TextureButton:
			button.disabled = not multiplayer.is_server()
	# Show host IP to help peers connect
	var label_node := get_node_or_null("Label")
	if label_node and label_node is Label:
		var is_host := multiplayer.has_multiplayer_peer() and (multiplayer.is_server() or multiplayer.get_unique_id() == 1)
		if is_host:
			var ip := NetworkLobby.get_local_ip()
			if ip == "" or ip == null:
				ip = "(detecting...)"
			label_node.text = "Lobby - Host IP: %s:%d" % [ip, NetworkLobby.get_port()]
		else:
			# Check if we have player data to show proper status
			var player_data = NetworkLobby.get_player_data()
			if player_data.size() > 0:
				label_node.text = "Lobby - Connected to Host"
			else:
				label_node.text = "Lobby - Waiting for Host"
	
	# Also update player list when UI updates
	_update_player_list()

func _on_map_selected(button: TextureButton):
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	if multiplayer.is_server():
		selected_map = button.name.replace("Button", "") # e.g. "Map1Button" → "Map1"
		print("[Lobby] Selected map:", selected_map)
		# Validate the map exists
		if selected_map in map_scenes:
			NetworkLobby.set_selected_map(selected_map)
			print("[Lobby] Map selection confirmed:", selected_map)
		else:
			print("[Lobby] ERROR: Selected map not found in map_scenes:", selected_map)
			selected_map = "Map1"  # Fallback to default
			NetworkLobby.set_selected_map(selected_map)

func _on_start_pressed():
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	if multiplayer.is_server():
		# Stop menu music before entering game
		if has_node("/root/AudioManager"):
			AudioManager.stop_music()
		
		# Disable start button to prevent double-clicks
		start_button.disabled = true
		start_button.text = "Starting Game..."
		
		print("[Lobby] Starting game with map:", selected_map)
		print("[Lobby] NetworkLobby selected_map:", NetworkLobby.get_selected_map())
		# Verify map exists before starting
		var test_path = "res://maps/%s.tscn" % selected_map
		if FileAccess.file_exists(test_path):
			print("[Lobby] Map file confirmed:", test_path)
			# NetworkLobby.start_game() now handles scene transition
			NetworkLobby.start_game()
		else:
			print("[Lobby] ERROR: Map file not found:", test_path)
			start_button.disabled = false
			start_button.text = "START"
		# Note: Scene change is now handled in NetworkLobby for proper sync

func _update_player_list():
	"""Update the player list UI with connected players"""
	if not player_list:
		return
		
	player_list.clear()
	
	var player_data = NetworkLobby.get_player_data()
	var player_count = player_data.size()
	
	print("[Lobby] Updating player list - Count:", player_count, "Players:", player_data.keys())
	
	# Add header
	player_list.add_item("Connected Players (%d/%d):" % [player_count, NetworkLobby.MAX_PLAYERS])
	player_list.set_item_disabled(0, true)  # Make header non-selectable
	
	# Add each player
	for peer_id in player_data.keys():
		var player_info = player_data[peer_id]
		var player_name = player_info.get("name", "Unknown")
		var is_host = (peer_id == 1)
		var display_name = "%s%s" % [player_name, " (Host)" if is_host else ""]
		player_list.add_item(display_name)
		print("[Lobby] Added player to UI:", display_name)
	
	# Show waiting message if not enough players
	if player_count < 2:
		player_list.add_item("Waiting for more players...")
		player_list.set_item_disabled(player_list.get_item_count() - 1, true)
	
	# Force UI refresh
	player_list.queue_redraw()

func _on_back_pressed():
	"""Handle back button press - return to main menu"""
	# Play button sound
	if has_node("/root/AudioManager"):
		AudioManager.play_button_sound()
	
	print("[Lobby] Back button pressed - returning to main menu")
	
	# Disconnect from network if connected
	if multiplayer.has_multiplayer_peer():
		print("[Lobby] Disconnecting from network...")
		multiplayer.multiplayer_peer = null
	
	# Return to main menu
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")
