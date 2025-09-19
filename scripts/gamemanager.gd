extends Node

@export var PlayerScene: PackedScene
@export var tag_mode: String = "transfer" # "transfer" or "freeze"
@export var tag_cooldown: float = 1.5
@export var round_time: float = 120.0
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

# RandomNumberGenerator instance for consistent random numbers
var _rng := RandomNumberGenerator.new()
var _loaded_skins_cache := {}

func _ready() -> void:
	var cursor = load("res://assets/gui/cursorSword_bronze.png")
	Input.set_custom_mouse_cursor(cursor, Input.CURSOR_ARROW, Vector2(16, 16))
	_rng.randomize() # Initialize RNG once

	# ensure Players container exists
	if not has_node("Players"):
		var players_node := Node2D.new()
		players_node.name = "Players"
		add_child(players_node)

	if timer_label:
		timer_label.text = ""
	if round_message_label:
		round_message_label.visible = false
		round_message_label.modulate.a = 0.0

	set_process(true)

	if player_skins.is_empty():
		printerr("WARNING: No player skins assigned in GameManager. Player skins will not be visible.")
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
		print("All spawn points used, resetting available spawns.")

	var idx = _rng.randi_range(0, available.size() - 1)
	var chosen = available[idx]
	used_spawns.append(chosen)
	return chosen

# ---------------- client -> server spawn request (first join) ----------------
@rpc("any_peer")
func rpc_request_spawn(requesting_peer_id:int) -> void:
	if not multiplayer.is_server():
		return

	var spawn_node = _pick_spawn_node()
	var spawn_pos = spawn_node.global_position if spawn_node else Vector2.ZERO

	var skin_idx := get_random_skin_index() # Use the new helper

	# remember skin index on server
	players_skin_indices[requesting_peer_id] = skin_idx

	# Broadcast create to everyone (clients will create local instances)
	rpc("rpc_create_player", requesting_peer_id, spawn_pos, skin_idx)

	# After creating the new player's local instance, send the full game state to that peer
	send_full_state_to_peer(requesting_peer_id)

# ---------------- create player (called on everyone) ----------------
@rpc("any_peer")
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
	player_instance.is_local = (peer_id == multiplayer.get_unique_id())

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

	print("[GM] created player for peer:", peer_id, " skin_idx:", skin_idx)

# ---------------- server -> client: send full state to a single peer ----------------
func send_full_state_to_peer(peer_id:int) -> void:
	if not multiplayer.is_server():
		return

	# Send existing players' data to the new peer
	for pid in players.keys():
		var p = players.get(pid, null)
		var pos = p.global_position if p else Vector2.ZERO
		var skin_idx = players_skin_indices.get(pid, -1) # Get skin index from server record
		rpc_id(peer_id, "rpc_create_player", pid, pos, skin_idx)
		if frozen_set.has(pid):
			rpc_id(peer_id, "rpc_set_frozen", pid, true)

	# Send game state info
	rpc_id(peer_id, "rpc_set_tagger", current_tagger)
	if round_end_time > 0:
		rpc_id(peer_id, "rpc_round_timer_start", round_end_time)

# ---------------- respawn players ----------------
func _respawn_all_players() -> void:
	if not multiplayer.is_server():
		return
	used_spawns.clear() # Clear used spawns for a fresh start

	for pid in players_order:
		var spawn_node = _pick_spawn_node()
		var spawn_pos = spawn_node.global_position if spawn_node else Vector2.ZERO

		var new_skin_idx = get_random_skin_index() # Get a new random skin index for respawn
		players_skin_indices[pid] = new_skin_idx # Update server's record
		rpc("respawn_player", pid, spawn_pos, new_skin_idx) # Pass skin_idx to clients

		last_tag_time.erase(pid)
		frozen_set.erase(pid)

@rpc("any_peer")
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
	if not multiplayer.is_server():
		return
	if round_active:
		print("[GM] start_new_round: round already active, ignoring")
		return
	if players_order.is_empty():
		print("[GM] start_new_round: no players")
		return

	round_active = true

	rpc("rpc_show_round_message", "New round starting...", 2.0)
	await get_tree().create_timer(2.0).timeout

	_respawn_all_players() # This now handles skin re-assignment for all players

	var idx = _rng.randi_range(0, players_order.size() - 1)
	current_tagger = players_order[idx]

	rpc("rpc_set_tagger", current_tagger)

	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)

	print("[GM] New round started. Tagger:", current_tagger)

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
			timer_label.text = "Time Left: " + str(int(time_left)) + "s" # Cast to int for cleaner display
	else:
		if timer_label:
			timer_label.text = ""

# ---------------- set tagger ----------------
@rpc("any_peer")
func rpc_set_tagger(peer_id:int) -> void:
	for pid in players.keys():
		var p = players.get(pid, null)
		if p and p.has_method("set_sili"):
			p.set_sili(pid == peer_id)

	if peer_id == multiplayer.get_unique_id():
		show_round_message("You are the TAGGER!", 3.0)
	else:
		show_round_message("Avoid the TAGGER!", 3.0)

# ---------------- tag/rescue ----------------
@rpc("any_peer", "call_local") # Add call_local to ensure server also runs this on itself if needed
func rpc_request_tag(acting_peer:int, target_peer:int):
	if not multiplayer.is_server():
		return
	if acting_peer != current_tagger and not _is_ai(acting_peer):
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

# ---------------- round end ----------------
func _check_round_end() -> void:
	if tag_mode == "freeze":
		for pid in players_order:
			if pid == current_tagger:
				continue
			if not frozen_set.has(pid):
				return
		rpc("rpc_round_end", current_tagger) # All players except tagger are frozen

func _on_round_timer_timeout():
	if multiplayer.is_server(): # Ensure only server calls this RPC
		rpc("rpc_round_end", -1) # Time's up, no winner yet

@rpc("any_peer")
func rpc_round_end(winner_peer:int) -> void:
	round_active = false
	var message = ""
	if winner_peer == -1:
		message = "Time’s up! Runners win!"
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

	if multiplayer.is_server():
		await get_tree().create_timer(3.0).timeout
		start_new_round()

# ---------------- helpers ----------------
func _is_ai(peer_id:int) -> bool:
	# Placeholder for future AI player logic
	return false

@rpc("any_peer")
func rpc_round_timer_start(end_time: float):
	round_end_time = end_time
	round_active = true

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
