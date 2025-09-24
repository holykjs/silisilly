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
	print("Hosting on port %d" % PORT)
	# Compute and cache the local IP for convenience
	_detect_local_ip()
	# New: Add host's own data to player_data
	_add_player(multiplayer.get_unique_id(), "HostPlayer") # You might want a UI for setting name
	player_list_changed.emit() # Emit signal for UI
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
		# Broadcast to all: please load this map file
		rpc("rpc_load_map", selected_map)
		# Server also loads the map locally
		_load_map_local(selected_map)

@rpc("any_peer")
func rpc_load_map(map_name:String):
	_load_map_local(map_name)

# New: RPC to update lobby map selection for clients
@rpc("any_peer")
func rpc_update_lobby_map(map_name:String):
	selected_map = map_name
	print("Lobby map updated to:", selected_map)
	# You might want to emit a signal here too if your lobby UI needs updating

func _load_map_local(map_name:String):
	var path = "res://maps/%s" % map_name
	if not FileAccess.file_exists(path):
		push_error("Map missing: " + path)
		return
	
	get_tree().change_scene_to_file(path)
	
	# If we're the server, also spawn our own player
	if multiplayer.is_server():
		rpc_request_spawn(multiplayer.get_unique_id())
		return

	# once scene loads, clients should request spawn (client side)
	# We'll handle spawning a bit differently, often in the loaded map scene itself,
	# or a dedicated GameState manager. For now, keep this here.
	if not multiplayer.is_server():
		# Request spawn from the server, passing the client's peer ID
		rpc_id(1, "rpc_request_spawn", multiplayer.get_unique_id()) # RPC to server (peer ID 1)


# --- New Multiplayer Signal Callbacks ---

func _on_peer_connected(id: int):
	print("Peer connected: ", id)
	if multiplayer.is_server():
		# Server receives connection, requests client's player data
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
	# Client is now connected, request to send its data to the server
	# The server will handle requesting data from new clients.
	# We might want to send initial data here if it's not requested by the server.
	# For now, we'll let the server request it.

# --- New RPCs for Player Data Sync ---

# Server-side: Adds player to dictionary and broadcasts to all
@rpc("any_peer", "call_local") # Call_local ensures server's own data is updated
func rpc_add_player(id: int, name: String):
	_add_player(id, name)
	player_list_changed.emit()
	print("Player added via RPC: %s (%d)" % [name, id])

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
		if not player_data.has(id):
			_add_player(id, name)
			player_list_changed.emit()
			print("Received player data from client %d: %s" % [id, name])
			# New: Broadcast this new player's data to all other already connected clients
			for peer_id in player_data.keys():
				if peer_id != 1 and peer_id != id: # Don't send to self or the new client again
					rpc_id(peer_id, "rpc_add_player", id, name)
			# Also send existing players to the new client
			for existing_id in player_data.keys():
				if existing_id != 1 and existing_id != id: # Don't send server or new client
					rpc_id(id, "rpc_add_player", existing_id, player_data[existing_id].name)


# Helper function to add player data
func _add_player(id: int, name: String):
	player_data[id] = {"name": name, "character": "Default"} # Add other data as needed
	print("Added player: %s (%d)" % [name, id])

# --- End of New Multiplayer Signal Callbacks & RPCs ---

# --- New: Player Spawning RPC (Server-side) ---
# This is typically called by a client after a map loads
@rpc("reliable")
func rpc_request_spawn(player_id: int):
	if multiplayer.is_server():
		# Get the current map scene
		var current_map_scene = get_tree().current_scene
		if current_map_scene:
			# Prefer a dedicated GameManager node if present
			var gm = current_map_scene.get_node_or_null("GameManager")
			if gm and gm.has_method("spawn_player"):
				gm.spawn_player(player_id, player_data[player_id].name)
				return
			# Fallback: call on scene root if it implements the method
			if current_map_scene.has_method("spawn_player"):
				current_map_scene.spawn_player(player_id, player_data[player_id].name)
				return
		push_warning("No 'spawn_player' method found on current map or its GameManager.")

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
