extends Node

@export var PlayerScene: PackedScene
@export var tag_mode: String = "transfer" # "transfer" or "freeze"
@export var tag_cooldown: float = 1.5   # seconds of invulnerability after tag

var players := {}          # peer_id -> node (populated by rpc_create_player)
var players_order := []    # list of peer ids (creation order)
var current_tagger := -1   # peer id of current Sili (server authoritative)
var frozen_set := {}       # peer_id -> true
var last_tag_time := {}   # peer_id -> float (timestamp)

func _ready() -> void:
	randomize()

# ---------------- spawn flow ----------------
@rpc("any_peer")
func rpc_create_player(peer_id:int, pos:Vector2) -> void:
	# This RPC will be called on every client-server so each peer creates local Player instances
	var root = get_tree().current_scene
	if not root:
		return
	# lazy-load packed scene if not assigned
	if not PlayerScene:
		PlayerScene = load("res://scenes/Player.tscn")
	var player = PlayerScene.instantiate()
	player.global_position = pos
	player.peer_id = peer_id
	# mark local instance
	player.is_local = (peer_id == multiplayer.get_unique_id())
	root.get_node("Players").add_child(player)
	players[peer_id] = player
	if not players_order.has(peer_id):
		players_order.append(peer_id)
	print("[GM] created player for peer:", peer_id)

# ---------------- start / pick random tagger ----------------
func start_new_round() -> void:
	if players_order.is_empty():
		print("[GM] no players to pick")
		return
	# clear frozen state
	frozen_set.clear()

	# pick a random index
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var idx = rng.randi_range(0, players_order.size() - 1)
	current_tagger = players_order[idx]

	# broadcast new tagger to all peers
	rpc("rpc_set_tagger", current_tagger)

	# ensure all clients clear frozen visuals
	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)

	print("[GM] New round started. Tagger:", current_tagger)

@rpc("any_peer")
func rpc_set_tagger(peer_id:int) -> void:
	# Called on every peer. Mark visual/flag on Player nodes
	for pid in players.keys():
		var p = players.get(pid, null)
		if p and p.has_method("set_sili"):
			p.set_sili(pid == peer_id)

# ---------------- tag/rescue (server authoritative) ----------------
@rpc("any_peer")
func rpc_request_tag(acting_peer:int, target_peer:int):
	if not multiplayer.is_server(): 
		return
	if acting_peer != current_tagger and not _is_ai(acting_peer):
		# only current tagger (or AI) can tag
		return

	# --- Cooldown check ---
	var now = Time.get_unix_time_from_system()
	if last_tag_time.has(target_peer):
		var elapsed = now - last_tag_time[target_peer]
		if elapsed < tag_cooldown:
			if OS.is_debug_build():
				print("Tag blocked — target still invulnerable:", target_peer)
			return

	# Already frozen? Ignore
	if frozen_set.has(target_peer): 
		return

	# Freeze the target
	frozen_set[target_peer] = true
	last_tag_time[target_peer] = now   # record time of tag
	rpc("rpc_set_frozen", target_peer, true)

	_check_round_end()

@rpc("any_peer")
func rpc_request_rescue(requester_peer:int, target_peer:int) -> void:
	if not multiplayer.is_server():
		return
	# validate
	if frozen_set.has(requester_peer):
		return
	if not frozen_set.has(target_peer):
		return
	# unfreeze
	frozen_set.erase(target_peer)
	rpc("rpc_set_frozen", target_peer, false)
	print("[GM] rescue:", requester_peer, "->", target_peer)

@rpc("any_peer")
func rpc_set_frozen(peer_id:int, value:bool) -> void:
	# Called on all peers to update visuals/state
	var p = players.get(peer_id, null)
	if p and p.has_method("set_frozen"):
		p.set_frozen(value)

# ---------------- round end ----------------
func _check_round_end() -> void:
	# if freeze-mode: check if all non-tagger players frozen => Sili wins
	if tag_mode == "freeze":
		for pid in players_order:
			if pid == current_tagger:
				continue
			if not frozen_set.has(pid):
				return
		# all frozen -> round end
		rpc("rpc_round_end", current_tagger)

@rpc("any_peer")
func rpc_round_end(winner_peer:int) -> void:
	print("[GM] Round ended. Winner:", winner_peer)
	# clear frozen visuals on clients
	frozen_set.clear()
	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)
	# optionally auto-start a new round on server
	if multiplayer.is_server():
		await get_tree().create_timer(3.0).timeout
		start_new_round()

# ---------------- helpers ----------------
func _is_ai(peer_id:int) -> bool:
	return false
