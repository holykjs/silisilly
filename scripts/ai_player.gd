extends CharacterBody2D

@export var speed := 160
var target_peer := -1
var peer_id := -1  # This AI player's peer ID
@onready var agent := $NavigationAgent2D

func _physics_process(delta):
	# Find GameManager in the scene
	var game_manager = get_node_or_null("/root/GameManager")
	if not game_manager:
		game_manager = get_tree().get_first_node_in_group("game_manager")
	if not game_manager:
		return
	
	# Choose target if needed
	if target_peer == -1 or game_manager.is_player_frozen(target_peer):
		target_peer = _choose_nearest_unfrozen(game_manager)
	if target_peer == -1:
		return
		
	# Get target node
	var target_node = game_manager.get_player_node(target_peer)
	if not target_node:
		return
		
	# Move towards target
	agent.set_target_position(target_node.global_position)
	var next_pos = agent.get_next_path_position()
	if next_pos != Vector2.ZERO:
		var dir = (next_pos - global_position).normalized()
		velocity = dir * speed
		move_and_slide()
		
	# Attempt tag if close
	if global_position.distance_to(target_node.global_position) < 18.0:
		# In single-player mode, call GameManager directly instead of RPC
		if multiplayer.has_multiplayer_peer():
			rpc_id(get_multiplayer_authority(), "rpc_request_tag", multiplayer.get_unique_id(), target_peer)
		else:
			# Single-player mode - call GameManager directly
			game_manager.rpc_request_tag(peer_id, target_peer)

func _choose_nearest_unfrozen(game_manager) -> int:
	var nearest := -1
	var bestd := 1e9
	for pid in game_manager.players_order:
		if game_manager.frozen_set.has(pid): continue
		if pid == game_manager.current_tagger: continue
		var pn = game_manager.players.get(pid, null)
		if pn:
			var d = global_position.distance_to(pn.global_position)
			if d < bestd:
				bestd = d
				nearest = pid
	return nearest
