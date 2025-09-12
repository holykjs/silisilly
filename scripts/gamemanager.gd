extends Node

@export var PlayerScene: PackedScene
@export var AiTaggerScene: PackedScene

var players := {}          # peer_id -> node
var players_order := []    # list of peer ids in join order
var current_tagger := -1
var frozen_set := {}       # peer_id -> true

# ---------------- spawn flow ----------------
@rpc("any_peer")
func rpc_request_spawn(requesting_peer_id:int):
	# server handles spawn request
	if not multiplayer.is_server():
		return
	var root = get_tree().current_scene
	if not root:
		return
	var spawns = root.get_node_or_null("Spawns")
	var spawn_pos = Vector2.ZERO
	if spawns and spawns.get_child_count() > 0:
		var idx = players.size() % spawns.get_child_count()
		spawn_pos = spawns.get_child(idx).global_position
	# broadcast create instruction so every client creates the player locally
	rpc("rpc_create_player", requesting_peer_id, spawn_pos)

@rpc("any_peer")
func rpc_create_player(peer_id:int, pos:Vector2):
	var root = get_tree().current_scene
	if not root:
		return
	# instantiate PlayerScene locally
	if not PlayerScene:
		PlayerScene = load("res://scenes/Player.tscn")
	var player = PlayerScene.instantiate()
	player.global_position = pos
	player.peer_id = peer_id
	player.is_local = (peer_id == multiplayer.get_unique_id())
	root.get_node("Players").add_child(player)
	players[peer_id] = player
	if not players_order.has(peer_id):
		players_order.append(peer_id)
	print("Created player locally for peer ", peer_id)

# helper getters used by AI and other scripts
func get_player_node(peer_id:int):
	return players.get(peer_id, null)

func is_player_frozen(peer_id:int) -> bool:
	return frozen_set.has(peer_id)

# ---------------- tag/rescue API (server authoritative) ---------------
@rpc("any_peer")
func rpc_request_tag(acting_peer:int, target_peer:int):
	if not multiplayer.is_server(): return
	if acting_peer != current_tagger and not _is_ai(acting_peer):
		# only current tagger (or AI master) can tag
		return
	if frozen_set.has(target_peer): return
	# freeze target
	frozen_set[target_peer] = true
	rpc("rpc_set_frozen", target_peer, true)
	_check_round_end()

@rpc("any_peer")
func rpc_request_rescue(requester_peer:int, target_peer:int):
	if not multiplayer.is_server(): return
	if frozen_set.has(requester_peer): return
	if not frozen_set.has(target_peer): return
	frozen_set.erase(target_peer)
	rpc("rpc_set_frozen", target_peer, false)

@rpc("any_peer")
func rpc_set_frozen(peer_id:int, value:bool):
	# called on all peers to update visuals
	var p = players.get(peer_id, null)
	if p:
		p.set_frozen(value)

# ---------------- simple round end check -------------
func _check_round_end():
	# if all non-tagger players frozen => round over
	for pid in players_order:
		if pid == current_tagger: continue
		if not frozen_set.has(pid):
			return
	# round over
	rpc("rpc_round_end", current_tagger)

@rpc("any_peer")
func rpc_round_end(winner_peer:int):
	print("Round ended. Winner was: ", winner_peer)
	# clear frozen set and reset visuals on all clients
	frozen_set.clear()
	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)

func _is_ai(peer_id:int) -> bool:
	# placeholder: implement your AI peer id checks if needed
	return false
