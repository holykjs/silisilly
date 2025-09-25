extends Node

const PORT := 52000
const MAX_PLAYERS := 5
var selected_map := "Map1.tscn"

# Local IP discovery
var local_ip := ""

# New: Dictionary to store player data {peer_id: {name: "PlayerX", character: "Warrior"}}
var player_data: Dictionary = {}

# New: Custom signal to notify UI or other nodes when the player list changes
signal player_list_changed

func _ready():
	# Connect to multiplayer signals
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.connected_to_server.connect(_on_connected_to_server)

func host_game():
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Server failed: %s" % str(err))
		return false # Return false on failure
	multiplayer.multiplayer_peer = peer
	print("[NetworkLobby] Hosting on port %d" % PORT)
	# Compute and cache the local IP for convenience
	_detect_local_ip()
	# Add host's own data to player_data
	var host_name = "Host (Player1)"
	_add_player(multiplayer.get_unique_id(), host_name)
	player_list_changed.emit() # Emit signal for UI
	print("[NetworkLobby] Host added to player list:", host_name)
	return true # Return true on success

func join_game(ip:String):
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		push_error("Client failed: %s" % str(err))
		return false # Return false on failure
	multiplayer.multiplayer_peer = peer
	print("Joining %s:%d" % [ip, PORT])
	return true # Return true on success

func set_selected_map(map_name:String):
	if multiplayer.is_server():
		selected_map = map_name
		print("Selected map:", selected_map)
		# New: RPC to inform all clients about the map change in the lobby
		rpc("rpc_update_lobby_map", selected_map)

func get_selected_map() -> String:
	return selected_map

func get_player_data() -> Dictionary:
	return player_data

func start_game():
	if multiplayer.is_server():
		print("[NetworkLobby] Server starting game with map:", selected_map)
		# Validate map exists before starting
		var test_path = "res://maps/%s" % selected_map
		if not test_path.ends_with(".tscn"):
			test_path += ".tscn"
		if not FileAccess.file_exists(test_path):
			push_error("Cannot start game - map missing: " + test_path)
			return
			
		# First, notify all clients to prepare for scene change
		rpc("rpc_prepare_game_start", selected_map)
		# Wait a moment for clients to acknowledge
		await get_tree().create_timer(0.5).timeout
		# Then broadcast scene change to all clients
		rpc("rpc_load_map", selected_map)
		# Server loads the map last to ensure clients are ready
		await get_tree().create_timer(0.2).timeout
		_load_map_local(selected_map)

# New: Prepare clients for game start
@rpc("any_peer", "call_local", "reliable")
func rpc_prepare_game_start(map_name:String):
	print("[NetworkLobby] Preparing for game start with map:", map_name)
	selected_map = map_name
	# Clients acknowledge they're ready
	if not multiplayer.is_server():
		rpc_id(1, "rpc_client_ready_for_game", multiplayer.get_unique_id())

@rpc("any_peer", "call_local", "reliable")
func rpc_load_map(map_name:String):
	print("[NetworkLobby] Loading map:", map_name)
	_load_map_local(map_name)

# Server receives client ready confirmations
@rpc("any_peer", "reliable")
func rpc_client_ready_for_game(client_id: int):
	if multiplayer.is_server():
		print("[NetworkLobby] Client", client_id, "ready for game start")

# New: RPC to update lobby map selection for clients
@rpc("any_peer")
func rpc_update_lobby_map(map_name:String):
	selected_map = map_name
	print("Lobby map updated to:", selected_map)
	# You might want to emit a signal here too if your lobby UI needs updating

func _load_map_local(map_name:String):
	# Ensure .tscn extension is added if not present
	var path = "res://maps/%s" % map_name
	if not path.ends_with(".tscn"):
		path += ".tscn"
		
	print("[NetworkLobby] Checking map file:", path)
	if not FileAccess.file_exists(path):
		push_error("Map missing: " + path)
		print("[NetworkLobby] ERROR: Map file does not exist:", path)
		return
	
	print("[NetworkLobby] Map file found, proceeding with scene change")
	
	print("[NetworkLobby] Changing scene to:", path)
	get_tree().change_scene_to_file(path)
	
	# Wait for scene to fully load before spawning
	await get_tree().process_frame
	await get_tree().process_frame  # Extra frame for safety
	
	# Now handle player spawning with proper timing
	if multiplayer.is_server():
		print("[NetworkLobby] Server requesting spawn for self")
		# Server spawns itself first using GameManager directly
		var gm = get_tree().current_scene.get_node_or_null("GameManager")
		if gm and gm.has_method("rpc_request_spawn"):
			gm.rpc_request_spawn(multiplayer.get_unique_id())
			print("[NetworkLobby] Server spawn requested via GameManager")
		# Then notify clients they can spawn
		await get_tree().create_timer(0.5).timeout
		rpc("rpc_clients_can_spawn")
	else:
		print("[NetworkLobby] Client waiting for spawn permission")
		# Clients wait for permission to spawn

# Server tells clients they can now spawn
@rpc("any_peer", "reliable")
func rpc_clients_can_spawn():
	if not multiplayer.is_server():
		print("[NetworkLobby] Client received spawn permission")
		await get_tree().create_timer(0.1).timeout  # Small delay
		# Use GameManager's spawn system directly
		var gm = get_tree().current_scene.get_node_or_null("GameManager")
		if gm and gm.has_method("rpc_request_spawn"):
			gm.rpc_id(1, "rpc_request_spawn", multiplayer.get_unique_id())
			print("[NetworkLobby] Client spawn requested via GameManager")
		else:
			print("[NetworkLobby] ERROR: GameManager not found for client spawn")


# --- New Multiplayer Signal Callbacks ---

func _on_peer_connected(id: int):
	print("[NetworkLobby] Peer connected: ", id)
	if multiplayer.is_server():
		# First, send existing players to the new client
		print("[NetworkLobby] Sending existing players to new client", id)
		for existing_id in player_data.keys():
			var player_info = player_data[existing_id]
			rpc_id(id, "rpc_add_player", existing_id, player_info.name)
			
		# Then request the new client's data
		rpc_id(id, "rpc_request_player_data")
		# Send current game state (e.g., selected map) to the new client
		rpc_id(id, "rpc_update_lobby_map", selected_map)

func _on_peer_disconnected(id: int):
	print("Peer disconnected: ", id)
	if multiplayer.is_server():
		if player_data.has(id):
			player_data.erase(id)
			player_list_changed.emit()
			# New: Inform other clients about player leaving
			rpc("rpc_remove_player", id)
	elif id == 1: # If client and server disconnected
		print("Disconnected from server.")
		# Handle going back to main menu, showing disconnect message, etc.
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn") # Example

func _on_connection_failed():
	print("Failed to connect to server.")
	# Show error message to user, maybe return to main menu
	multiplayer.multiplayer_peer = null # Clear the peer
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn") # Example

func _on_connected_to_server():
	print("Successfully connected to server.")
	# Send a ping to verify connection is stable
	await get_tree().create_timer(0.5).timeout
	rpc_id(1, "rpc_client_connection_verified", multiplayer.get_unique_id())
	
# Client confirms stable connection to server
@rpc("any_peer", "reliable")
func rpc_client_connection_verified(client_id: int):
	if multiplayer.is_server():
		print("[NetworkLobby] Client", client_id, "connection verified")
		# Ensure player data exists for this client
		if not player_data.has(client_id):
			var client_name = "Player" + str(client_id)
			_add_player(client_id, client_name)
			player_list_changed.emit()
			# Broadcast to all clients
			rpc("rpc_add_player", client_id, client_name)
			print("[NetworkLobby] Auto-added client", client_id, "and broadcasted to all")

# --- New RPCs for Player Data Sync ---

# Server-side: Adds player to dictionary and broadcasts to all
@rpc("any_peer", "call_local") # Call_local ensures server's own data is updated
func rpc_add_player(id: int, name: String):
	print("[NetworkLobby] rpc_add_player called for:", name, "(", id, ")")
	_add_player(id, name)
	player_list_changed.emit()
	print("[NetworkLobby] Player added via RPC and signal emitted:", name, "(", id, ")")
	print("[NetworkLobby] Current player_data:", player_data)

# Server-side: Removes player from dictionary and broadcasts to all
@rpc("any_peer", "call_local")
func rpc_remove_player(id: int):
	if player_data.has(id):
		player_data.erase(id)
		player_list_changed.emit()
		print("Player removed via RPC: %d" % id)

# Client-side: Server requests this from a newly connected client
@rpc("reliable") # Server is calling this, so it must be reliable
func rpc_request_player_data():
	if not multiplayer.is_server(): # Only clients should respond
		# Send client's local player data to the server
		# You'll need a way for the client to know its own name/character
		var my_name = "Player" + str(multiplayer.get_unique_id()) # Placeholder
		rpc_id(1, "rpc_send_player_data", multiplayer.get_unique_id(), my_name)

# Server-side: Client sends its player data to the server
@rpc("reliable")
func rpc_send_player_data(id: int, name: String):
	if multiplayer.is_server(): # Only server should receive
		print("[NetworkLobby] Received player data from client", id, ":", name)
		if not player_data.has(id):
			_add_player(id, name)
			player_list_changed.emit()
			print("[NetworkLobby] Broadcasting new player", id, "to all clients")
			# Broadcast this new player's data to ALL clients (including the new one for confirmation)
			rpc("rpc_add_player", id, name)
		else:
			print("[NetworkLobby] Player", id, "already exists in player_data")


# Helper function to add player data
func _add_player(id: int, name: String):
	player_data[id] = {"name": name, "character": "Default"} # Add other data as needed
	print("Added player: %s (%d)" % [name, id])

# --- End of New Multiplayer Signal Callbacks & RPCs ---

# DEPRECATED: This function is now handled by GameManager.rpc_request_spawn() directly
# Keeping for compatibility but redirecting to GameManager
@rpc("reliable")
func rpc_request_spawn(player_id: int):
	print("[NetworkLobby] DEPRECATED rpc_request_spawn called, redirecting to GameManager")
	if multiplayer.is_server():
		# Redirect to GameManager's spawn system
		var gm = get_tree().current_scene.get_node_or_null("GameManager")
		if gm and gm.has_method("rpc_request_spawn"):
			gm.rpc_request_spawn(player_id)
		else:
			print("[NetworkLobby] ERROR: GameManager not found for spawn request")

func _detect_local_ip():
	# Try to find a likely LAN IPv4 address
	var candidates := IP.get_local_addresses()
	for addr in candidates:
		# Skip loopback and IPv6
		if addr.begins_with("127."):
			continue
		if ":" in addr:
			continue
		# Common private IPv4 ranges
		if addr.begins_with("192.168.") or addr.begins_with("10.") or addr.begins_with("172."):
			local_ip = addr
			return
	# Fallback: first IPv4 that's not loopback
	for addr in candidates:
		if ":" in addr:
			continue
		if not addr.begins_with("127."):
			local_ip = addr
			return
	# Final fallback
	local_ip = "127.0.0.1"

func get_local_ip() -> String:
	return local_ip

func get_port() -> int:
	return PORT
