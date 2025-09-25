extends Node

@export var PlayerScene: PackedScene
@export var tag_mode: String = "freeze" # "freeze" for Sili Silly mechanics
@export var tag_cooldown: float = 1.5
@export var round_time: float = 90.0  # 90 seconds for survival mode
@export var player_skins: Array[Resource] = []   # unified skins array, ideally SpriteFrames

# runtime state
var players := {}          # peer_id -> node
var players_order := []    # list of peer ids (creation order)
var players_skin_indices := {} # peer_id -> skin_idx (server-side record, changed name for clarity)
var current_tagger := -1
var frozen_set := {}
var last_tag_time := {}

var round_timer: Timer
var round_end_time: float = 0.0
var used_spawns: Array = []
var round_active: bool = false

@onready var timer_label: Label = $HUD/RoundTimerLabel
@onready var round_message_label: Label = $HUD/RoundMessageLabel
@onready var spawn_points := $SpawnPoints.get_children()

# Additional UI elements (create these in your scene if needed)
@onready var mode_label: Label = $HUD/GameModeLabel if has_node("HUD/GameModeLabel") else null
@onready var player_count_label: Label = $HUD/PlayerCountLabel if has_node("HUD/PlayerCountLabel") else null

# End game popup (will be created dynamically)
var end_game_popup: Control = null

# RandomNumberGenerator instance for consistent random numbers
var _rng := RandomNumberGenerator.new()
var _loaded_skins_cache := {}

func _ready() -> void:
	var cursor = load("res://assets/gui/cursorSword_bronze.png")
	Input.set_custom_mouse_cursor(cursor, Input.CURSOR_ARROW, Vector2(16, 16))
	_rng.randomize() # Initialize RNG once

	# Add to group so AI can find this GameManager
	add_to_group("game_manager")

	# Connect multiplayer signals for proper disconnection handling
	if multiplayer.has_multiplayer_peer():
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		# Also connect to peer connected for late joiners
		multiplayer.peer_connected.connect(_on_peer_connected_to_game)

	# ensure Players container exists
	if not has_node("Players"):
		var players_node := Node2D.new()
		players_node.name = "Players"
		add_child(players_node)

	if timer_label:
		timer_label.text = ""
		print("[GM] Timer label found and initialized: ", timer_label.name)
	else:
		print("[GM] ERROR: Timer label not found! Check node path: $HUD/RoundTimerLabel")
	if round_message_label:
		round_message_label.visible = false
		round_message_label.modulate.a = 0.0

	# Initialize UI elements (hidden by default)
	_initialize_ui_elements()

	set_process(true)

	if player_skins.is_empty():
		printerr("WARNING: No player skins assigned in GameManager. Player skins will not be visible.")
	
	# Auto-start single-player mode if SinglePlayerManager is active OR no multiplayer
	var should_start_single_player = false
	
	if has_node("/root/SinglePlayerManager") and get_node("/root/SinglePlayerManager").is_single_player:
		print("[GM] Single-player mode detected via SinglePlayerManager")
		should_start_single_player = true
	elif not multiplayer.has_multiplayer_peer():
		print("[GM] No multiplayer detected - assuming single-player mode")
		should_start_single_player = true
	
	if should_start_single_player:
		print("[GM] Starting single-player game in 2 seconds")
		await get_tree().create_timer(2.0).timeout
		start_single_player_game()
	else:
		# Proactively load all skins into cache on startup
		for i in range(player_skins.size()):
			var skin_entry = player_skins[i]
			if skin_entry is String: # If it's a path
				var loaded = ResourceLoader.load(skin_entry)
				if loaded:
					_loaded_skins_cache[i] = loaded
					player_skins[i] = loaded # Replace path with loaded resource in the array
				else:
					printerr("Failed to preload skin from path:", skin_entry)
			elif skin_entry is Resource: # Already a resource, just cache it
				_loaded_skins_cache[i] = skin_entry
			else:
				printerr("Unsupported skin entry type in player_skins array at index", i, ":", skin_entry)

# Helper function to get a random skin resource
func get_random_skin_resource() -> Resource:
	if player_skins.is_empty():
		printerr("ERROR: player_skins array is empty. Cannot get random skin.")
		return null
	var random_index = _rng.randi_range(0, player_skins.size() - 1)
	return get_skin_resource_by_index(random_index) # Use the index getter

# Helper function to get a random skin index
func get_random_skin_index() -> int:
	if player_skins.is_empty():
		printerr("ERROR: player_skins array is empty. Cannot get random skin index.")
		return -1
	return _rng.randi_range(0, player_skins.size() - 1)

# Helper function to get a skin resource by index
func get_skin_resource_by_index(index: int) -> Resource:
	if index < 0 or index >= player_skins.size():
		printerr("ERROR: Invalid skin index:", index, " Max:", player_skins.size() - 1)
		return null

	# Check cache first
	if _loaded_skins_cache.has(index):
		return _loaded_skins_cache[index]

	var skin_entry = player_skins[index]
	var loaded_skin: Resource = null

	if skin_entry is String:
		# If for some reason it's still a path, load it
		loaded_skin = ResourceLoader.load(skin_entry)
		if loaded_skin:
			_loaded_skins_cache[index] = loaded_skin
			player_skins[index] = loaded_skin # Update the array entry with the loaded resource
			return loaded_skin
		else:
			printerr("Failed to load skin from path (fallback):", skin_entry)
	elif skin_entry is Resource:
		# It's already a Resource, cache it for future calls
		_loaded_skins_cache[index] = skin_entry
		return skin_entry
	else:
		printerr("Unsupported skin entry type for index", index, ":", skin_entry)

	return null


# ---------------- helper: pick & reserve spawn ----------------
func _pick_spawn_node() -> Node2D:
	var available = spawn_points.filter(func(s): return not used_spawns.has(s))
	if available.size() == 0:
		if spawn_points.is_empty():
			printerr("ERROR: No spawn points available!")
			return null
		# If all spawns are used, pick a random one from all available, clearing `used_spawns` might be better here
		used_spawns.clear() # Reset used spawns if all are taken
		available = spawn_points
		print("[GM] All spawn points used, resetting available spawns. Total spawn points: ", spawn_points.size())

	var idx = _rng.randi_range(0, available.size() - 1)
	var chosen = available[idx]
	used_spawns.append(chosen)
	print("[GM] Picked spawn point ", idx, " from ", available.size(), " available")
	return chosen

# ---------------- client -> server spawn request (first join) ----------------
@rpc("any_peer", "reliable")
func rpc_request_spawn(requesting_peer_id:int) -> void:
	if not multiplayer.is_server():
		return

	print("[GM] Spawn request from peer:", requesting_peer_id)
	
	# Check if player already exists (prevent duplicate spawning)
	if players.has(requesting_peer_id):
		print("[GM] Player", requesting_peer_id, "already exists, sending state update")
		send_full_state_to_peer(requesting_peer_id)
		return

	var spawn_node = _pick_spawn_node()
	var spawn_pos = spawn_node.global_position if spawn_node else Vector2.ZERO

	var skin_idx := get_random_skin_index() # Use the new helper

	# remember skin index on server
	players_skin_indices[requesting_peer_id] = skin_idx

	print("[GM] Creating player", requesting_peer_id, "at", spawn_pos)
	# Broadcast create to everyone (clients will create local instances)
	rpc("rpc_create_player", requesting_peer_id, spawn_pos, skin_idx)

	# Wait a moment for player creation to complete
	await get_tree().process_frame
	await get_tree().process_frame  # Extra frame for safety
	
	# Verify player was created successfully
	if not players.has(requesting_peer_id):
		print("[GM] ERROR: Player", requesting_peer_id, "was not created successfully!")
		return
	
	print("[GM] Player", requesting_peer_id, "created successfully. Total players:", players.size())
	
	# After creating the new player's local instance, send the full game state to that peer
	send_full_state_to_peer(requesting_peer_id)
	
	# Force visual state update for all players
	for pid in players.keys():
		update_player_visual_state(pid)
	
	# Check if we have enough players to start a round
	_check_auto_start_round()

# ---------------- create player (called on everyone) ----------------
@rpc("any_peer", "call_local", "reliable")
func rpc_create_player(peer_id:int, pos:Vector2, skin_idx:int = -1) -> void:
	# If player already exists, just update its position and skin
	if players.has(peer_id):
		var existing_player: CharacterBody2D = players[peer_id]
		existing_player.global_position = pos
		var skin_resource = get_skin_resource_by_index(skin_idx)
		if skin_resource and existing_player.has_method("set_skin"):
			existing_player.set_skin(skin_resource)
		return

	if not PlayerScene:
		PlayerScene = load("res://scenes/Player.tscn")
		if not PlayerScene:
			printerr("ERROR: PlayerScene not loaded!")
			return

	var player_instance: CharacterBody2D = PlayerScene.instantiate()
	player_instance.global_position = pos
	player_instance.peer_id = peer_id
	
	# In single-player mode, only peer_id 1 (human) should be local
	if not multiplayer.has_multiplayer_peer():
		player_instance.is_local = (peer_id == 1)  # Human player in single-player
	else:
		player_instance.is_local = (peer_id == multiplayer.get_unique_id())  # Multiplayer mode

	var skin_resource = get_skin_resource_by_index(skin_idx)
	if skin_resource and player_instance.has_method("set_skin"):
		player_instance.set_skin(skin_resource)
	else:
		if is_instance_valid(player_instance.anim_sprite):
			# Fallback if skin_resource is null, apply default Godot skin (e.g. red box)
			player_instance.anim_sprite.sprite_frames = player_instance.anim_sprite.sprite_frames # Force update or re-initialize
			player_instance._play_default_animation() # Call the helper on player to ensure animation


	$Players.add_child(player_instance)
	players[peer_id] = player_instance
	if not players_order.has(peer_id):
		players_order.append(peer_id)

	print("[GM] created player for peer:", peer_id, " skin_idx:", skin_idx, " at position:", pos)
	print("[GM] Player", peer_id, "is_local:", player_instance.is_local, "multiplayer_authority:", player_instance.get_multiplayer_authority())
	
	# Ensure player is visible and properly configured
	if player_instance.has_node("NameLabel"):
		var name_label = player_instance.get_node("NameLabel")
		name_label.text = "Player_" + str(peer_id)
		name_label.visible = true
		print("[GM] Set name label for player", peer_id, "to:", name_label.text)
	
	# Update visual state after creation
	call_deferred("update_player_visual_state", peer_id)
	
	# Debug: Print all current players
	print("[GM] All players after creation:")
	for pid in players.keys():
		var p = players[pid]
		print("  Player", pid, ":", p.name, "at", p.global_position, "visible:", p.visible)

# ---------------- server -> client: send full state to a single peer ----------------
func send_full_state_to_peer(peer_id:int) -> void:
	if not multiplayer.is_server():
		return

	print("[GM] Sending full state to peer", peer_id, "- Current players:", players.keys())
	
	# Send existing players' data to the new peer
	for pid in players.keys():
		if pid == peer_id:
			continue  # Don't send the peer their own player data
			
		var p = players.get(pid, null)
		if not p:
			print("[GM] WARNING: Player", pid, "exists in players dict but node is null")
			continue
			
		var pos = p.global_position
		var skin_idx = players_skin_indices.get(pid, -1)
		print("[GM] Sending player", pid, "data to peer", peer_id, "at position", pos)
		rpc_id(peer_id, "rpc_create_player", pid, pos, skin_idx)
		
		if frozen_set.has(pid):
			rpc_id(peer_id, "rpc_set_frozen", pid, true)

	# Send game state info
	print("[GM] Sending game state to peer", peer_id, "- tagger:", current_tagger, "round_active:", round_active)
	rpc_id(peer_id, "rpc_update_round_state", round_active, current_tagger, round_end_time)
	
	# Force visual update for the new peer
	await get_tree().process_frame
	for pid in players.keys():
		rpc_id(peer_id, "rpc_force_visual_update", pid)

# ---------------- respawn players ----------------
func _respawn_all_players() -> void:
	if not multiplayer.is_server() and multiplayer.has_multiplayer_peer():
		return

	print("[GM] Respawn all players...")
	used_spawns.clear() # Clear used spawns for a fresh start

	for pid in players_order:
		var spawn_node = _pick_spawn_node()
		var spawn_pos = spawn_node.global_position if spawn_node else Vector2.ZERO

		var new_skin_idx = get_random_skin_index() # Get a new random skin index for respawn
		players_skin_indices[pid] = new_skin_idx # Update server record

		respawn_player(pid, spawn_pos, new_skin_idx)

# ---------------- respawn player ----------------
func respawn_player(peer_id: int, pos: Vector2, skin_idx: int) -> void:
	var player_node = players.get(peer_id, null)
	if player_node:
		# Use the respawn function in Player.gd, which now handles skin application internally
		# We don't need to call set_skin directly here, as player.respawn() will handle it.
		# However, `respawn` in Player.gd expects to find the skin itself.
		# Let's directly call `set_skin` on the player, as `respawn` on Player.gd is
		# also updated to use `current_skin_resource`
		var skin_resource = get_skin_resource_by_index(skin_idx)
		if skin_resource and player_node.has_method("set_skin"):
			player_node.set_skin(skin_resource)
		
		player_node.respawn(pos) # Now `player.respawn()` just moves and resets other states.
								# The skin is handled by the server's rpc_set_player_skin.
	else:
		printerr("ERROR: Player node not found for peer_id:", peer_id, " during respawn.")


# Removed rpc_set_player_skin. The skin is already passed in rpc_create_player or respawn_player.
# The player script's `set_skin` method handles the actual assignment.
# We keep `players_skin_indices` on the server and pass the index over RPC.

# ---------------- spawn_player method for NetworkLobby compatibility ----------------
func spawn_player(peer_id: int, player_name: String) -> void:
	"""
	Called by NetworkLobby when a player requests to spawn.
	This is a wrapper around the existing rpc_request_spawn functionality.
	"""
	if not multiplayer.is_server():
		return
	
	print("[GM] spawn_player called for peer_id:", peer_id, " name:", player_name)
	
	# Use the existing spawn logic
	rpc_request_spawn(peer_id)

# ---------------- round flow ----------------
func start_new_round() -> void:
	# Only server can start rounds in multiplayer
	if multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		print("[GM] Only server can start rounds")
		return
		
	if round_active:
		print("[GM] start_new_round: round already active, ignoring")
		return
		
	if players_order.is_empty():
		print("[GM] start_new_round: no players")
		return
	
	# Check if we're in single-player mode first
	var is_single_player = false
	if has_node("/root/SinglePlayerManager"):
		var sp_manager = get_node("/root/SinglePlayerManager")
		is_single_player = sp_manager.is_single_player
		print("[GM] SinglePlayerManager found, is_single_player: ", is_single_player)
		print("[GM] Player count: ", players_order.size(), " Players: ", players_order)
		print("[GM] multiplayer.has_multiplayer_peer(): ", multiplayer.has_multiplayer_peer())
	else:
		print("[GM] SinglePlayerManager NOT found - checking multiplayer status")
	
	# In multiplayer mode (not single-player), ensure we have enough human players
	if not is_single_player and multiplayer.has_multiplayer_peer():
		var human_count = players_order.filter(func(pid): return pid < 1000).size()
		if human_count < 2:
			print("[GM] Not enough human players for multiplayer round:", human_count)
			return

	print("[GM] Starting countdown sequence...")
	
	# Ensure all clients are synchronized before starting
	if multiplayer.has_multiplayer_peer():
		rpc("rpc_sync_game_state")
		await get_tree().create_timer(0.5).timeout
	
	# Start visual countdown immediately while players are respawning (parallel execution)
	# Respawn all players first (quick operation)
	_respawn_all_players()
	
	# Then show countdown sequence for both modes
	await _show_countdown_sequence()
	
	# In single-player mode, ALL AI are taggers (survival mode)
	if is_single_player:
		current_tagger = -1  # Special value indicating survival mode
		print("[GM] Single-player SURVIVAL mode: All AI are hunters!")
		print("[GM] Human player ID: 1, AI hunter IDs: 1000+")
	else:
		# Pick a random HUMAN tagger in multiplayer (exclude AI players)
		var human_players = players_order.filter(func(pid): return pid < 1000)
		if human_players.size() > 0:
			var idx = _rng.randi_range(0, human_players.size() - 1)
			current_tagger = human_players[idx]
			print("[GM] Multiplayer mode: Selected human tagger ", current_tagger)
		else:
			# Fallback: if no human players, use first available
			current_tagger = players_order[0] if players_order.size() > 0 else -1
			print("[GM] Fallback tagger selection: ", current_tagger)

	# 3-second countdown with mode-specific messages
	if current_tagger == -1:  # Survival mode
		rpc("rpc_show_countdown_message", "SURVIVAL MODE", "3", 1.0)
		await get_tree().create_timer(1.0).timeout
		
		rpc("rpc_show_countdown_message", "4 HUNTERS INCOMING", "2", 1.0)
		await get_tree().create_timer(1.0).timeout
		
		rpc("rpc_show_countdown_message", "RUN FOR YOUR LIFE", "1", 1.0)
		await get_tree().create_timer(1.0).timeout
		
		rpc("rpc_show_round_message", "SURVIVE 90 SECONDS!", 2.0)
	else:
		# Normal mode countdown
		rpc("rpc_show_countdown_message", "GET READY", "3", 1.0)
		await get_tree().create_timer(1.0).timeout
		
		rpc("rpc_show_countdown_message", "GET READY", "2", 1.0)
		await get_tree().create_timer(1.0).timeout
		
		rpc("rpc_show_countdown_message", "GET READY", "1", 1.0)
		await get_tree().create_timer(1.0).timeout
		
		rpc("rpc_show_round_message", "GO!", 1.0)
	
	# Now start the actual round
	round_active = true
	rpc("rpc_set_tagger", current_tagger)

	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)

	print("[GM] New round started. Tagger:", current_tagger)
	
	# Show game UI elements now that the round is active
	_show_game_ui()
	
	# Ensure network synchronization
	rpc("rpc_sync_game_state")

	# Countdown already provided the delay for both single-player and multiplayer
	# No additional wait needed since countdown gives players time to get ready
	
	# Start the timer
	if round_timer:
		round_timer.stop()
		round_timer.queue_free()
		round_timer = null # Ensure it's nullified

	round_timer = Timer.new()
	round_timer.wait_time = round_time
	round_timer.one_shot = true
	add_child(round_timer)
	round_timer.timeout.connect(_on_round_timer_timeout)
	round_timer.start()

	round_end_time = Time.get_unix_time_from_system() + round_time

	rpc("rpc_start_round", current_tagger, round_end_time)
	rpc("rpc_round_timer_start", round_end_time)
	
	print("[GM] Timer started after player respawn - ", round_time, " seconds remaining")

@rpc("any_peer")
func rpc_start_round(tagger_peer:int, end_time: float) -> void:
	round_end_time = end_time
	round_active = true
	current_tagger = tagger_peer

	# Update player states based on received info
	for pid in players.keys():
		var p = players.get(pid, null)
		if p and p.has_method("set_frozen"):
			p.set_frozen(false)
		if p and p.has_method("set_sili"):
			p.set_sili(pid == tagger_peer)

	show_round_message("Round Started!", 1.5)

func _process(delta: float) -> void:
	if round_end_time > 0:
		var now = Time.get_unix_time_from_system()
		var time_left = max(round_end_time - now, 0)
		if timer_label:
			# Format time as [mm]:[ss]
			var total_seconds = int(time_left)
			var minutes = total_seconds / 60
			var seconds = total_seconds % 60
			var formatted_time = "[%02d]:[%02d]" % [minutes, seconds]
			
			# Different UI for survival mode
			if current_tagger == -1:  # Survival mode
				var timer_text = "SURVIVE: " + formatted_time
				timer_label.text = timer_text
				# Change color based on urgency
				if time_left <= 20:
					timer_label.modulate = Color.RED  # Critical time
				elif time_left <= 45:
					timer_label.modulate = Color.YELLOW  # Warning time
				else:
					timer_label.modulate = Color.GREEN  # Safe time
				# Debug: Print every 5 seconds
				if int(time_left) % 5 == 0:
					print("[GM] Timer updated: ", timer_text, " visible: ", timer_label.visible)
			else:
				timer_label.text = "Time Left: " + formatted_time
				timer_label.modulate = Color.WHITE  # Normal color
	else:
		if timer_label:
			timer_label.text = ""
			timer_label.modulate = Color.WHITE
	
	# Update player count display
	_update_player_count_display()

# ---------------- set tagger ----------------
@rpc("any_peer")
func rpc_set_tagger(peer_id:int) -> void:
	for pid in players.keys():
		var p = players.get(pid, null)
		if p and p.has_method("set_sili"):
			# In survival mode (peer_id = -1), all AI are taggers
			if peer_id == -1:  # Survival mode
				p.set_sili(pid >= 1000)  # AI players are taggers
			else:
				p.set_sili(pid == peer_id)  # Normal mode
		# Update visual state for all players
		update_player_visual_state(pid)

	# Show appropriate message based on mode
	if peer_id == -1:  # Survival mode
		var hunter_count = 0
		for pid in players.keys():
			if pid >= 1000:  # Count AI hunters
				hunter_count += 1
		show_round_message("SURVIVAL MODE: " + str(hunter_count) + " hunters are after you!", 3.0)
	elif peer_id == multiplayer.get_unique_id():
		show_round_message("You are the TAGGER!", 3.0)
	else:
		show_round_message("Avoid the TAGGER!", 3.0)

# ---------------- tag/rescue ----------------
@rpc("any_peer", "call_local") # Add call_local to ensure server also runs this on itself if needed
func rpc_request_tag(acting_peer:int, target_peer:int):
	if not multiplayer.is_server():
		return
	# In survival mode, all AI can tag. In normal mode, only current tagger can tag
	var can_tag = false
	if current_tagger == -1:  # Survival mode
		can_tag = _is_ai(acting_peer)  # Only AI hunters can tag
	else:  # Normal mode
		can_tag = (acting_peer == current_tagger)
	
	if not can_tag:
		return

	var now = Time.get_unix_time_from_system()
	if last_tag_time.has(target_peer):
		var elapsed = now - last_tag_time[target_peer]
		if elapsed < tag_cooldown:
			if OS.is_debug_build():
				print("[GM] Tag blocked — target still invulnerable:", target_peer)
			return

	if frozen_set.has(target_peer):
		return

	frozen_set[target_peer] = true
	last_tag_time[target_peer] = now
	rpc("rpc_set_frozen", target_peer, true)

	_check_round_end()

@rpc("any_peer", "call_local")
func rpc_request_rescue(requester_peer:int, target_peer:int) -> void:
	if not multiplayer.is_server():
		return
	if frozen_set.has(requester_peer):
		return
	if not frozen_set.has(target_peer):
		return

	frozen_set.erase(target_peer)
	rpc("rpc_set_frozen", target_peer, false)

	last_tag_time[target_peer] = Time.get_unix_time_from_system()
	print("[GM] rescue:", requester_peer, "->", target_peer)

@rpc("any_peer")
func rpc_set_frozen(peer_id:int, value:bool) -> void:
	var p = players.get(peer_id, null)
	if p and p.has_method("set_frozen"):
		p.set_frozen(value)
	
	# Update visual state
	update_player_visual_state(peer_id)

# ---------------- round end ----------------
func _check_round_end() -> void:
	# In survival mode, game ends when human player is tagged
	if current_tagger == -1:  # Survival mode
		if frozen_set.has(1):  # Human player (peer_id = 1) is frozen/tagged
			print("[GM] Human player tagged in survival mode - game over!")
			# Check if we're in single-player mode
			var is_single_player = false
			if has_node("/root/SinglePlayerManager"):
				var sp_manager = get_node("/root/SinglePlayerManager")
				is_single_player = sp_manager.is_single_player
			
			if is_single_player:
				rpc_round_end(-2)  # Call directly in single-player
			else:
				rpc("rpc_round_end", -2)  # Use RPC in multiplayer
			return
		# Check if time is up (human survived)
		return
	
	# Normal freeze mode
	if tag_mode == "freeze":
		for pid in players_order:
			if pid == current_tagger:
				continue
			if not frozen_set.has(pid):
				return
		rpc("rpc_round_end", current_tagger) # All players except tagger are frozen

func _on_round_timer_timeout():
	print("[GM] _on_round_timer_timeout() called!")
	
	# Check if we're in single-player mode
	var is_single_player = false
	if has_node("/root/SinglePlayerManager"):
		var sp_manager = get_node("/root/SinglePlayerManager")
		is_single_player = sp_manager.is_single_player
		print("[GM] Timer timeout - SinglePlayerManager found, is_single_player: ", is_single_player)
	else:
		print("[GM] Timer timeout - SinglePlayerManager NOT found!")
	
	print("[GM] Timer timeout - is_single_player: ", is_single_player, " multiplayer.is_server(): ", multiplayer.is_server())
	
	if is_single_player or multiplayer.is_server():
		# In survival mode, if timer expires, human wins
		if current_tagger == -1:  # Survival mode
			print("[GM] Timer expired in survival mode - human wins!")
			if is_single_player:
				print("[GM] Single-player mode - calling rpc_round_end directly")
				rpc_round_end(1)  # Call directly in single-player
			else:
				print("[GM] Multiplayer mode - calling via RPC")
				rpc("rpc_round_end", 1)  # Use RPC in multiplayer
		else:
			print("[GM] Timer expired in normal mode")
			if is_single_player:
				rpc_round_end(-1)  # Call directly in single-player
			else:
				rpc("rpc_round_end", -1) # Use RPC in multiplayer
	else:
		print("[GM] Timer expired but not server/single-player - ignoring")

@rpc("any_peer")
func rpc_round_end(winner_peer:int) -> void:
	print("[GM] rpc_round_end() called with winner_peer: ", winner_peer)
	round_active = false
	var message = ""
	
	if winner_peer == -2:  # Survival mode game over (human caught)
		message = "GAME OVER! You were caught by the hunters!"
	elif winner_peer == 1 and current_tagger == -1:  # Human wins survival mode
		message = "SURVIVAL SUCCESS! You escaped the hunters!"
	elif winner_peer == -1:
		if current_tagger == -1:  # This shouldn't happen anymore
			message = "SURVIVAL SUCCESS! You escaped the hunters!"
		else:
			message = "Time's up! Runners win!"
	else:
		if winner_peer == current_tagger:
			message = "Tagger Wins!"
		else:
			message = "Runners Win!"

	print("[GM] Round ended. " + message)
	show_round_message(message, 3.0)

	if round_timer:
		round_timer.stop()
		round_timer.queue_free()
		round_timer = null

	frozen_set.clear() # Clear frozen state for next round
	for pid in players.keys():
		var p = players.get(pid, null)
		if p and p.has_method("set_frozen"):
			p.set_frozen(false)

	round_end_time = 0
	if timer_label:
		timer_label.text = "Round Over!"

	# Check if we're in single-player mode
	var is_single_player = false
	if has_node("/root/SinglePlayerManager"):
		var sp_manager = get_node("/root/SinglePlayerManager")
		is_single_player = sp_manager.is_single_player
		print("[GM] SinglePlayerManager found, is_single_player: ", is_single_player)
	else:
		print("[GM] SinglePlayerManager NOT found!")
	
	print("[GM] Round end - is_single_player: ", is_single_player, " winner_peer: ", winner_peer)
	
	# Show end game popup in single-player mode
	if is_single_player:
		print("[GM] Showing popup for single-player mode")
		await get_tree().create_timer(2.0).timeout  # Brief pause to show message
		_show_end_game_popup(message, winner_peer)
	else:
		print("[GM] Not single-player mode, using auto-restart")
		# Auto-restart in multiplayer mode
		if multiplayer.is_server():
			await get_tree().create_timer(3.0).timeout
			start_new_round()
		else:
			# For clients, hide UI after round ends
			await get_tree().create_timer(3.0).timeout
			_hide_game_ui()

# ---------------- helpers ----------------
func _is_ai(peer_id:int) -> bool:
	"""Check if a player is AI (peer_id >= 1000 for AI players)"""
	return peer_id >= 1000

func _show_end_game_popup(result_message: String, winner_peer: int):
	"""Show end game popup with play again or main menu options"""
	print("[GM] Showing end game popup with message: ", result_message)
	
	# Hide game UI
	_hide_game_ui()
	
	# Create popup container
	end_game_popup = Control.new()
	end_game_popup.name = "EndGamePopup"
	end_game_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_game_popup.z_index = 100  # Make sure it's on top
	add_child(end_game_popup)
	
	print("[GM] Created popup container")
	
	# Semi-transparent background
	var background = ColorRect.new()
	background.color = Color(0, 0, 0, 0.8)
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	end_game_popup.add_child(background)
	
	# Main panel with custom or gradient background
	var panel = TextureRect.new()
	panel.size = Vector2(350, 500)
	# Center the panel manually
	var screen_size = get_viewport().get_visible_rect().size
	panel.position = Vector2(
		(screen_size.x - panel.size.x) / 2,
		(screen_size.y - panel.size.y) / 2
	)
	
	# Try to load custom background assets first
	var background_texture_path = ""
	if winner_peer == 1:  # Victory
		background_texture_path = "res://assets/ui/popup_win_background.png"
	else:  # Defeat
		background_texture_path = "res://assets/ui/popup_lose_background.png"
	
	# Check if custom background asset exists
	if background_texture_path != "" and ResourceLoader.exists(background_texture_path):
		print("[GM] Using custom popup background: ", background_texture_path)
		panel.texture = load(background_texture_path)
		panel.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	else:
		print("[GM] Using fallback gradient background")
		# Create gradient background (fallback)
		var gradient = Gradient.new()
		if winner_peer == 1:  # Victory
			gradient.add_point(0.0, Color(0.2, 0.8, 0.8, 1.0))  # Teal
			gradient.add_point(1.0, Color(0.3, 0.2, 0.8, 1.0))  # Purple
		else:  # Defeat
			gradient.add_point(0.0, Color(0.8, 0.3, 0.3, 1.0))  # Red
			gradient.add_point(1.0, Color(0.3, 0.2, 0.8, 1.0))  # Purple
		
		var gradient_texture = GradientTexture2D.new()
		gradient_texture.gradient = gradient
		gradient_texture.fill_from = Vector2(0.5, 0.0)
		gradient_texture.fill_to = Vector2(0.5, 1.0)
		
		panel.texture = gradient_texture
		panel.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	
	end_game_popup.add_child(panel)
	
	print("[GM] Created gradient panel at position: ", panel.position, " size: ", panel.size)
	
	# Create banner-style result display with custom assets
	var banner_texture_path = ""
	if winner_peer == 1:  # Victory
		banner_texture_path = "res://assets/ui/banner_win.png"
	else:  # Defeat
		banner_texture_path = "res://assets/ui/banner_lose.png"
	
	# Check if custom banner asset exists
	if banner_texture_path != "" and ResourceLoader.exists(banner_texture_path):
		print("[GM] Using custom banner: ", banner_texture_path)
		# Use custom banner image - adjusted size to fit better in background PNG
		var banner = TextureRect.new()
		banner.size = Vector2(300, 100)  # Larger banner size
		banner.position = Vector2(25, 70)  # Better centered in panel
		banner.texture = load(banner_texture_path)
		banner.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		panel.add_child(banner)
	else:
		print("[GM] Using fallback banner design")
		# Fallback to colored rectangle banner
		var banner = ColorRect.new()
		banner.size = Vector2(280, 80)
		banner.position = Vector2(35, 80)  # Centered in panel
		
		# Banner color based on result
		if winner_peer == 1:  # Victory
			banner.color = Color(0.2, 0.6, 1.0, 0.9)  # Blue banner
		else:  # Defeat  
			banner.color = Color(1.0, 0.3, 0.3, 0.9)  # Red banner
		
		panel.add_child(banner)
		
		# Result text on banner
		var result_label = Label.new()
		if winner_peer == 1:
			result_label.text = "WIN"
		else:
			result_label.text = "LOSE"
		
		result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		result_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		result_label.position = Vector2(0, 0)
		result_label.size = Vector2(280, 80)
		result_label.add_theme_font_size_override("font_size", 32)
		result_label.add_theme_color_override("font_color", Color.WHITE)
		banner.add_child(result_label)
	
	# Removed stars decoration as requested
	
	# Stats label below banner - only show time survived, not victory/defeat message
	var stats_text = _get_time_stats_only(winner_peer)
	var stats_label = Label.new()
	stats_label.text = stats_text
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stats_label.position = Vector2(25, 260)
	stats_label.size = Vector2(300, 30)
	
	# Load and apply digital-7.ttf font
	var digital_font_path = "res://assets/gui/digital-7.ttf"
	if ResourceLoader.exists(digital_font_path):
		var digital_font = load(digital_font_path)
		stats_label.add_theme_font_override("font", digital_font)
		print("[GM] Using digital-7.ttf font for timer stats")
	else:
		print("[GM] digital-7.ttf font not found, using default font")
	
	stats_label.add_theme_font_size_override("font_size", 18)
	stats_label.add_theme_color_override("font_color", Color.WHITE)
	stats_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	stats_label.add_theme_constant_override("shadow_offset_x", 2)
	stats_label.add_theme_constant_override("shadow_offset_y", 2)
	panel.add_child(stats_label)
	
	# Create styled buttons - horizontally aligned side by side
	var button_width = 120
	var button_height = 50
	var button_spacing = 20
	var total_width = (button_width * 2) + button_spacing
	var start_x = (panel.size.x - total_width) / 2
	
	_create_styled_button(panel, "New Round", Vector2(start_x, 320), Vector2(button_width, button_height), Color(1.0, 0.8, 0.2, 1.0), _on_play_again_pressed)
	_create_styled_button(panel, "Home", Vector2(start_x + button_width + button_spacing, 320), Vector2(button_width, button_height), Color(0.3, 0.6, 1.0, 1.0), _on_main_menu_pressed)
	
	print("[GM] Created buttons - Play Again and Main Menu")
	
	# Animate popup in
	panel.modulate.a = 0.0
	panel.scale = Vector2(0.8, 0.8)
	var tween = create_tween()
	tween.parallel().tween_property(panel, "modulate:a", 1.0, 0.3)
	tween.parallel().tween_property(panel, "scale", Vector2(1.0, 1.0), 0.3)
	
	print("[GM] Popup animation started - should be visible now!")
	
	# Make sure the popup is visible and on top
	end_game_popup.visible = true
	end_game_popup.show()
	panel.visible = true
	panel.show()

func _create_styled_button(parent: Control, text: String, pos: Vector2, size: Vector2, color: Color, callback: Callable):
	"""Create a styled button with support for custom assets"""
	
	# Try to load custom button assets first
	var button_texture_path = ""
	if text == "New Round":
		button_texture_path = "res://assets/ui/button_new_round.png"
	elif text == "Home":
		button_texture_path = "res://assets/ui/button_home.png"
	
	# Check if custom asset exists
	var use_custom_asset = false
	if button_texture_path != "" and ResourceLoader.exists(button_texture_path):
		use_custom_asset = true
		print("[GM] Using custom button asset: ", button_texture_path)
	
	if use_custom_asset:
		# Use custom texture for button
		var btn_texture = TextureRect.new()
		btn_texture.position = pos
		btn_texture.size = size
		btn_texture.texture = load(button_texture_path)
		btn_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		parent.add_child(btn_texture)
		
		# Invisible button for clicks
		var button = Button.new()
		button.position = pos
		button.size = size
		button.flat = true
		button.modulate = Color(1, 1, 1, 0)  # Invisible
		button.pressed.connect(callback)
		parent.add_child(button)
		
		# No text overlay - custom PNG assets already have text built-in
	else:
		# Fallback to colored rectangles (current system)
		print("[GM] Using fallback button design for: ", text)
		
		# Button background
		var btn_bg = ColorRect.new()
		btn_bg.position = pos
		btn_bg.size = size
		btn_bg.color = color
		parent.add_child(btn_bg)
		
		# Rounded corners effect (simple border)
		var border = ColorRect.new()
		border.position = Vector2(pos.x - 2, pos.y - 2)
		border.size = Vector2(size.x + 4, size.y + 4)
		border.color = Color(1.0, 1.0, 1.0, 0.3)
		border.z_index = -1
		parent.add_child(border)
		
		# Button (invisible, just for clicks)
		var button = Button.new()
		button.position = pos
		button.size = size
		button.flat = true
		button.modulate = Color(1, 1, 1, 0)  # Invisible
		button.pressed.connect(callback)
		parent.add_child(button)
		
		# Button text
		var label = Label.new()
		label.text = text
		label.position = pos
		label.size = size
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 18)
		label.add_theme_color_override("font_color", Color.WHITE)
		parent.add_child(label)

func _get_round_stats(winner_peer: int) -> String:
	"""Generate stats text for the round"""
	var stats = ""
	
	if current_tagger == -1:  # Survival mode
		if winner_peer == 1:  # Human won by surviving
			stats = "Congratulations!\nYou survived the hunt!\n\nTime survived: " + str(int(round_time)) + " seconds"
		else:  # Human was caught
			# Calculate how long they survived
			var current_time = Time.get_unix_time_from_system()
			var elapsed_time = round_time
			if round_end_time > 0:
				elapsed_time = round_time - max(round_end_time - current_time, 0)
			stats = "Game Over!\nYou were caught by the hunters!\n\nTime survived: " + str(int(max(elapsed_time, 0))) + " seconds"
	else:
		stats = "Round completed!"
	
	return stats

func _get_time_stats_only(winner_peer: int) -> String:
	"""Generate only time stats without victory/defeat messages"""
	var stats = ""
	
	if current_tagger == -1:  # Survival mode
		if winner_peer == 1:  # Human won by surviving
			stats = "Time survived: " + str(int(round_time)) + " seconds"
		else:  # Human was caught
			# Calculate how long they survived
			var current_time = Time.get_unix_time_from_system()
			var elapsed_time = round_time
			if round_end_time > 0:
				elapsed_time = round_time - max(round_end_time - current_time, 0)
			stats = "Time survived: " + str(int(max(elapsed_time, 0))) + " seconds"
	else:
		stats = "Round completed!"
	
	return stats

func _on_play_again_pressed():
	"""Handle play again button press"""
	print("[GM] Play Again button pressed!")
	_close_end_game_popup()
	# Brief delay then start new round
	await get_tree().create_timer(0.5).timeout
	start_new_round()

func _on_main_menu_pressed():
	"""Handle main menu button press"""
	print("[GM] Main Menu button pressed!")
	
	# Stop single-player music before returning to main menu
	if has_node("/root/AudioManager"):
		var audio_manager = get_node("/root/AudioManager")
		audio_manager.stop_music()
		print("[GM] Stopped single-player BGM")
	
	_close_end_game_popup()
	# Return to main menu
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

func _show_countdown_sequence():
	"""Show visual countdown sequence for single-player mode"""
	print("[GM] Starting visual countdown sequence")
	
	# Create countdown overlay
	var countdown_overlay = Control.new()
	countdown_overlay.name = "CountdownOverlay"
	countdown_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	countdown_overlay.z_index = 200  # Above everything else
	add_child(countdown_overlay)
	
	# Create countdown label - explicitly centered
	var countdown_label = Label.new()
	countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	# Get screen size and center the label
	var screen_size = get_viewport().get_visible_rect().size
	countdown_label.position = Vector2(0, 0)
	countdown_label.size = screen_size
	countdown_label.anchor_left = 0.0
	countdown_label.anchor_top = 0.0
	countdown_label.anchor_right = 1.0
	countdown_label.anchor_bottom = 1.0
	
	countdown_label.add_theme_font_size_override("font_size", 120)
	countdown_label.add_theme_color_override("font_color", Color.WHITE)
	countdown_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	countdown_label.add_theme_constant_override("shadow_offset_x", 4)
	countdown_label.add_theme_constant_override("shadow_offset_y", 4)
	
	# Load digital font if available
	var digital_font_path = "res://assets/gui/digital-7.ttf"
	if ResourceLoader.exists(digital_font_path):
		var digital_font = load(digital_font_path)
		countdown_label.add_theme_font_override("font", digital_font)
		print("[GM] Using digital-7.ttf font for countdown")
	
	countdown_overlay.add_child(countdown_label)
	
	# Countdown sequence: 3, 2, 1, GO!
	var countdown_numbers = ["3", "2", "1", "GO!"]
	var countdown_colors = [Color.YELLOW, Color.ORANGE, Color.RED, Color.GREEN]
	
	for i in range(countdown_numbers.size()):
		countdown_label.text = countdown_numbers[i]
		countdown_label.add_theme_color_override("font_color", countdown_colors[i])
		
		# Scale animation
		countdown_label.scale = Vector2(0.5, 0.5)
		var tween = create_tween()
		tween.tween_property(countdown_label, "scale", Vector2(1.2, 1.2), 0.3)
		tween.tween_property(countdown_label, "scale", Vector2(1.0, 1.0), 0.2)
		
		# Wait for animation and pause
		await tween.finished
		await get_tree().create_timer(0.5).timeout
	
	# Clean up countdown overlay
	countdown_overlay.queue_free()
	print("[GM] Countdown sequence completed")

func _close_end_game_popup():
	"""Close and cleanup the end game popup"""
	if end_game_popup:
		var tween = create_tween()
		tween.tween_property(end_game_popup, "modulate:a", 0.0, 0.2)
		await tween.finished
		end_game_popup.queue_free()
		end_game_popup = null

# Handle new peer connecting to game (late joiner)
func _on_peer_connected_to_game(peer_id: int):
	"""Handle when a peer connects to an active game"""
	print("[GM] Peer connected to active game:", peer_id)
	# Send full game state to the new peer
	if multiplayer.is_server():
		await get_tree().create_timer(0.5).timeout  # Wait for peer to be ready
		send_full_state_to_peer(peer_id)

func _check_auto_start_round():
	"""Check if we should auto-start a round when enough players join"""
	if not multiplayer.is_server():
		return
	
	# Only auto-start if we have at least 2 human players and no round is active
	var human_count = players_order.filter(func(pid): return pid < 1000).size()
	if human_count >= 2 and not round_active:
		print("[GM] Auto-starting round with", human_count, "players")
		await get_tree().create_timer(2.0).timeout  # Give players time to see each other
		start_new_round()

func _on_peer_disconnected(peer_id: int):
	"""Handle player disconnection in multiplayer"""
	if not multiplayer.has_multiplayer_peer():
		return  # Not in multiplayer mode
	
	print("[GM] Player disconnected: ", peer_id)
	
	# Remove player from game
	if players.has(peer_id):
		players[peer_id].queue_free()
		players.erase(peer_id)
		players_order.erase(peer_id)
		frozen_set.erase(peer_id)
		players_skin_indices.erase(peer_id)
		
		# If disconnected player was tagger, select new one
		if current_tagger == peer_id:
			var human_players = players_order.filter(func(pid): return pid < 1000)
			if human_players.size() > 0:
				current_tagger = human_players[0]
				rpc("rpc_set_tagger", current_tagger)
				show_round_message("New tagger selected!", 2.0)
			else:
				# No human players left, end round
				rpc("rpc_round_end", -1)
				return
		
		# Check if game should end due to insufficient players
		var human_count = players_order.filter(func(pid): return pid < 1000).size()
		if human_count < 2:
			rpc("rpc_round_end", -1)
			show_round_message("Not enough players!", 3.0)
			return
		
		# Check normal win conditions
		_check_round_end()

@rpc("any_peer")
func rpc_round_timer_start(end_time: float):
	round_end_time = end_time
	round_active = true

@rpc("any_peer", "call_local", "reliable")
func rpc_sync_game_state():
	"""Ensure all clients have consistent game state"""
	if not multiplayer.is_server():
		return
	
	print("[GM] Synchronizing game state across network")
	
	# Sync basic game state
	rpc("rpc_update_round_state", round_active, current_tagger, round_end_time)
	
	# Sync all frozen states
	for pid in frozen_set.keys():
		rpc("rpc_set_frozen", pid, true)
	
	# Sync all player visual states
	for pid in players.keys():
		update_player_visual_state(pid)
	
	print("[GM] Game state synchronized across network")

# New RPC for comprehensive state sync
@rpc("any_peer", "reliable")
func rpc_update_round_state(is_active: bool, tagger_id: int, end_time: float):
	"""Update round state on clients"""
	round_active = is_active
	current_tagger = tagger_id
	round_end_time = end_time
	
	# Update tagger state for all players
	for pid in players.keys():
		var p = players.get(pid, null)
		if p and p.has_method("set_sili"):
			p.set_sili(pid == tagger_id)
		update_player_visual_state(pid)
	
	print("[GM] Client updated round state: active=", is_active, " tagger=", tagger_id)

# Force visual update for a specific player
@rpc("any_peer", "reliable")
func rpc_force_visual_update(peer_id: int):
	"""Force visual state update for a specific player"""
	update_player_visual_state(peer_id)
	print("[GM] Forced visual update for player", peer_id)

func _initialize_ui_elements():
	"""Initialize UI elements - hide them by default until game starts"""
	# Hide game UI elements initially
	if timer_label:
		timer_label.visible = false
	if round_message_label:
		round_message_label.visible = false
	if mode_label:
		mode_label.visible = false
	if player_count_label:
		player_count_label.visible = false

func _show_game_ui():
	"""Show game UI elements when round starts"""
	if timer_label:
		timer_label.visible = true
		print("[GM] Timer label made visible: ", timer_label.visible, " text: '", timer_label.text, "'")
	else:
		print("[GM] ERROR: timer_label is null in _show_game_ui()")
	if round_message_label:
		round_message_label.visible = true
	_update_mode_display()
	_update_player_count_display()

func _hide_game_ui():
	"""Hide game UI elements when not in game"""
	if timer_label:
		timer_label.visible = false
	if round_message_label:
		round_message_label.visible = false
	if mode_label:
		mode_label.visible = false
	if player_count_label:
		player_count_label.visible = false

func _update_mode_display():
	"""Update the game mode display"""
	if not mode_label:
		return
	
	mode_label.visible = true  # Show when game is active
	
	if not multiplayer.has_multiplayer_peer():
		mode_label.text = "SURVIVAL MODE"
		mode_label.modulate = Color.RED
	else:
		mode_label.text = "SILI SILLY"
		mode_label.modulate = Color.YELLOW

func _update_player_count_display():
	"""Update the player count display"""
	if not player_count_label:
		return
	
	# Only show during active gameplay
	if not round_active or players.size() == 0:
		player_count_label.visible = false
		return
	
	player_count_label.visible = true
	
	if current_tagger == -1:  # Survival mode
		var alive_count = 1 if not frozen_set.has(1) else 0
		var hunter_count = players.size() - 1
		player_count_label.text = "Hunters: %d | Survivor: %d" % [hunter_count, alive_count]
		player_count_label.modulate = Color.GREEN if alive_count > 0 else Color.RED
	else:  # Multiplayer mode
		var frozen_count = frozen_set.size()
		var active_count = players.size() - frozen_count
		player_count_label.text = "Active: %d | Frozen: %d" % [active_count, frozen_count]
		player_count_label.modulate = Color.WHITE

# ---------------- UI message helpers ----------------
# Renamed rpc_show_round_message to avoid local/rpc confusion,
# and have rpc_show_round_message simply call the local one.
func show_round_message(text: String, duration: float = 2.0):
	if not round_message_label:
		return
	round_message_label.text = text
	round_message_label.visible = true
	var tween = create_tween()
	round_message_label.modulate.a = 0.0
	tween.tween_property(round_message_label, "modulate:a", 1.0, 0.5)
	tween.tween_interval(duration)
	tween.tween_property(round_message_label, "modulate:a", 0.0, 0.5)
	await tween.finished
	round_message_label.visible = false

@rpc("any_peer")
func rpc_show_round_message(text: String, duration: float = 2.0):
	show_round_message(text, duration)

@rpc("any_peer")
func rpc_show_countdown_message(text: String, number: String, duration: float = 1.0):
	show_countdown_message(text, number, duration)

func show_countdown_message(text: String, number: String, duration: float = 1.0):
	"""Show a prominent countdown message with large number"""
	if not round_message_label:
		return
	
	# Create prominent countdown display
	var countdown_text = text + "\n\n" + number
	round_message_label.text = countdown_text
	round_message_label.visible = true
	
	# Make the countdown more prominent
	var original_scale = round_message_label.scale
	round_message_label.scale = Vector2(1.5, 1.5)  # Make it bigger
	
	var tween = create_tween()
	round_message_label.modulate.a = 0.0
	
	# Animate in with bounce effect
	tween.tween_property(round_message_label, "modulate:a", 1.0, 0.2)
	tween.parallel().tween_property(round_message_label, "scale", Vector2(1.2, 1.2), 0.2)
	tween.tween_interval(duration - 0.4)
	tween.tween_property(round_message_label, "modulate:a", 0.0, 0.2)
	tween.parallel().tween_property(round_message_label, "scale", original_scale, 0.2)
	
	await tween.finished
	round_message_label.visible = false
	round_message_label.scale = original_scale

# ---------------- Single Player Mode ----------------
func start_single_player_game():
	"""Start a single-player game with AI opponents"""
	print("[GM] Starting single-player game")
	
	# Single-player BGM should already be playing from MainMenu
	# Just ensure it's still playing in case of any issues
	if has_node("/root/AudioManager"):
		var audio_manager = get_node("/root/AudioManager")
		if not audio_manager.is_music_playing():
			audio_manager.play_single_player_music()
			print("[GM] BGM wasn't playing, started single-player BGM")
		else:
			print("[GM] Single-player BGM already playing from MainMenu")
	else:
		print("[GM] AudioManager not found - no BGM will play")
	
	# Create human player (peer_id = 1)
	var human_spawn = _pick_spawn_node()
	var human_pos = human_spawn.global_position if human_spawn else Vector2.ZERO
	var human_skin_idx = get_random_skin_index()
	rpc_create_player(1, human_pos, human_skin_idx)
	
	# Create AI players
	var ai_count = 4  # Default
	if has_node("/root/SinglePlayerManager"):
		ai_count = get_node("/root/SinglePlayerManager").ai_count
	
	print("[GM] Creating ", ai_count, " AI players for survival mode")
	for i in range(ai_count):
		var ai_peer_id = 1000 + i  # Use high IDs for AI
		var ai_spawn = _pick_spawn_node()
		var ai_pos = ai_spawn.global_position if ai_spawn else Vector2.ZERO
		var ai_skin_idx = get_random_skin_index()
		
		# Create AI player
		_create_ai_player(ai_peer_id, ai_pos, ai_skin_idx, "AI_" + str(i + 1))
		print("[GM] Created AI player ", i + 1, " with peer_id ", ai_peer_id, " at ", ai_pos)
	
	# Verify all players were created
	print("[GM] Total players created: ", players.size(), " (Expected: ", ai_count + 1, ")")
	for pid in players.keys():
		var player_node = players[pid]
		print("[GM] Player ", pid, ": ", player_node.name, " at ", player_node.global_position)
	
	# Start the round after a brief delay
	await get_tree().create_timer(1.0).timeout
	start_new_round()

func _create_ai_player(peer_id: int, pos: Vector2, skin_idx: int, ai_name: String):
	"""Create an AI player for single-player mode"""
	if not PlayerScene:
		printerr("[GM] No PlayerScene assigned!")
		return
	
	var player_instance = PlayerScene.instantiate()
	player_instance.name = "Player_" + str(peer_id)
	player_instance.peer_id = peer_id
	player_instance.is_local = false  # AI is not local controlled
	player_instance.position = pos
	
	# Ensure AI players don't respond to input
	player_instance.set_multiplayer_authority(peer_id)
	
	# Set AI name
	if player_instance.has_node("NameLabel"):
		player_instance.get_node("NameLabel").text = ai_name
	
	# Setup as AI player
	if player_instance.has_method("setup_as_ai"):
		player_instance.setup_as_ai()
	
	# Apply skin
	var skin_resource = get_skin_resource_by_index(skin_idx)
	if skin_resource and player_instance.has_method("set_skin"):
		player_instance.set_skin(skin_resource)
	
	# Add to tracking
	players[peer_id] = player_instance
	players_order.append(peer_id)
	players_skin_indices[peer_id] = skin_idx
	
	# Add to scene
	$Players.add_child(player_instance)
	
	# Update visual state after creation
	call_deferred("update_player_visual_state", peer_id)
	
	print("[GM] Created AI player:", ai_name, "at", pos)

# ---------------- AI Helper Methods ----------------
func is_player_frozen(peer_id: int) -> bool:
	"""Check if a player is frozen"""
	return frozen_set.has(peer_id)

func get_player_node(peer_id: int) -> Node:
	"""Get the player node by peer_id"""
	return players.get(peer_id, null)

func update_player_visual_state(peer_id: int):
	"""Update player name color and text based on state"""
	var player_node = players.get(peer_id, null)
	if not player_node:
		print("[GM] WARNING: Cannot update visual state - player", peer_id, "not found")
		return
	
	if not player_node.has_node("NameLabel"):
		print("[GM] WARNING: Player", peer_id, "has no NameLabel node")
		return
	
	var name_label = player_node.get_node("NameLabel")
	var base_name = "Player_" + str(peer_id)  # Use consistent base name
	
	# Reset to base name
	var display_name = base_name
	var color = Color.WHITE  # Default human player color
	
	# Handle survival mode (current_tagger = -1)
	if current_tagger == -1:  # Survival mode
		if peer_id >= 1000:  # AI players are all hunters
			color = Color.RED
			display_name = "[HUNTER] " + base_name
		else:  # Human player is the runner
			color = Color.GREEN
			display_name = "[RUNNER] " + base_name
	else:
		# Normal multiplayer mode
		# Check if this is the tagger (Sili)
		if peer_id == current_tagger:
			color = Color.RED
			display_name = "[SILI] " + base_name
		else:
			# Regular player
			color = Color.WHITE
			display_name = base_name
	
	# Frozen players are cyan (overrides other colors)
	if frozen_set.has(peer_id):
		color = Color.CYAN
		display_name = "[FROZEN] " + base_name
	
	# Apply changes
	name_label.text = display_name
	name_label.modulate = color
	name_label.visible = true  # Ensure label is visible
	
	# Also ensure the player sprite is visible
	if player_node.has_node("Sprite"):
		player_node.get_node("Sprite").visible = true
	
	print("[GM] Updated visual state for player", peer_id, ":", display_name, "color:", color)
