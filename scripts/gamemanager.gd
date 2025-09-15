extends Node

@export var PlayerScene: PackedScene
@export var tag_mode: String = "transfer" # "transfer" or "freeze"
@export var tag_cooldown: float = 1.5
@export var round_time: float = 120.0
@export var player_skins: Array[Resource] = []

var players := {}          # peer_id -> node
var players_order := []    # list of peer ids (creation order)
var current_tagger := -1
var frozen_set := {}
var last_tag_time := {}

var round_timer: Timer
var round_end_time: float = 0.0
var used_spawns: Array = []

@onready var timer_label: Label = $HUD/RoundTimerLabel
@onready var round_message_label: Label = $HUD/RoundMessageLabel
@onready var spawn_points := $SpawnPoints.get_children()

func _ready() -> void:
	var cursor = load("res://assets/gui/cursorSword_bronze.png")
	Input.set_custom_mouse_cursor(cursor, Input.CURSOR_ARROW, Vector2(16, 16))
	randomize()

	# --- ensure Players container exists ---
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

# ---------------- helper: pick & reserve spawn ----------------
func _pick_spawn_node() -> Node2D:
	var available = spawn_points.filter(func(s): return not used_spawns.has(s))
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	if available.size() == 0:
		if spawn_points.size() == 0:
			return null
		return spawn_points[rng.randi_range(0, spawn_points.size() - 1)]
	var idx = rng.randi_range(0, available.size() - 1)
	var chosen = available[idx]
	used_spawns.append(chosen)
	return chosen

# ---------------- client -> server spawn request ----------------
@rpc("any_peer")
func rpc_request_spawn(requesting_peer_id:int) -> void:
	if not multiplayer.is_server():
		return
	var spawn_node = _pick_spawn_node()
	var spawn_pos = spawn_node.global_position if spawn_node else Vector2.ZERO

	var skin_idx := -1
	if player_skins.size() > 0:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		skin_idx = rng.randi_range(0, player_skins.size() - 1)

	rpc("rpc_create_player", requesting_peer_id, spawn_pos, skin_idx)

# ---------------- create player ----------------
@rpc("any_peer")
func rpc_create_player(peer_id:int, pos:Vector2, skin_idx:int = -1) -> void:
	if players.has(peer_id):
		var existing = players[peer_id]
		existing.global_position = pos
		if skin_idx >= 0 and skin_idx < player_skins.size() and existing.has_method("set_skin"):
			existing.set_skin(player_skins[skin_idx])
		return

	if not PlayerScene:
		PlayerScene = load("res://scenes/Player.tscn")

	var player = PlayerScene.instantiate()
	player.global_position = pos
	player.peer_id = peer_id
	player.is_local = (peer_id == multiplayer.get_unique_id())

	if skin_idx >= 0 and skin_idx < player_skins.size() and player.has_method("set_skin"):
		player.set_skin(player_skins[skin_idx])

	$Players.add_child(player)
	players[peer_id] = player
	if not players_order.has(peer_id):
		players_order.append(peer_id)

	print("[GM] created player for peer:", peer_id, " skin_idx:", skin_idx)

# ---------------- respawn players ----------------
func _respawn_all_players() -> void:
	if not multiplayer.is_server():
		return
	used_spawns.clear()
	for pid in players_order:
		var spawn_node = _pick_spawn_node()
		var spawn_pos = spawn_node.global_position if spawn_node else Vector2.ZERO
		rpc("rpc_respawn_player", pid, spawn_pos)
		last_tag_time.erase(pid)
		frozen_set.erase(pid)

@rpc("any_peer")
func rpc_respawn_player(peer_id:int, pos:Vector2) -> void:
	var p = players.get(peer_id, null)
	if p:
		if p.has_method("respawn"):
			p.respawn(pos)
		else:
			p.global_position = pos
			if p.has_method("set_frozen"):
				p.set_frozen(false)
	else:
		print("[GM] rpc_respawn_player: player missing locally:", peer_id)

# ---------------- round flow ----------------
func start_new_round() -> void:
	if not multiplayer.is_server():
		return
	if players_order.is_empty():
		print("[GM] start_new_round: no players")
		return

	rpc("rpc_show_round_message", "New round starting...", 2.0)
	await get_tree().create_timer(2.0).timeout

	_respawn_all_players()

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var idx = rng.randi_range(0, players_order.size() - 1)
	current_tagger = players_order[idx]
	rpc("rpc_set_tagger", current_tagger)

	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)

	print("[GM] New round started. Tagger:", current_tagger)

	if round_timer:
		round_timer.stop()
		round_timer.queue_free()

	round_timer = Timer.new()
	round_timer.wait_time = round_time
	round_timer.one_shot = true
	add_child(round_timer)
	round_timer.timeout.connect(_on_round_timer_timeout)
	round_timer.start()

	round_end_time = Time.get_unix_time_from_system() + round_time
	rpc("rpc_round_timer_start", round_end_time)

# ---------------- process ----------------
func _process(delta: float) -> void:
	if round_end_time > 0:
		var now = Time.get_unix_time_from_system()
		var time_left = max(round_end_time - now, 0)
		if timer_label:
			timer_label.text = "Time Left: " + str(time_left as int) + "s"
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

	# personal messages (local)
	if peer_id == multiplayer.get_unique_id():
		rpc_id(multiplayer.get_unique_id(), "rpc_show_round_message", "You are the TAGGER!", 3.0)
	else:
		rpc("rpc_show_round_message", "Avoid the TAGGER!", 3.0)

# ---------------- tag/rescue (server authoritative) ----------------
@rpc("any_peer")
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

@rpc("any_peer")
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
		# tagger froze everyone => round ends
		rpc("rpc_round_end", current_tagger)

func _on_round_timer_timeout():
	rpc("rpc_round_end", -1)  # -1 = timeout

@rpc("any_peer")
func rpc_round_end(winner_peer:int) -> void:
	if winner_peer == -1:
		print("[GM] Round ended. Time’s up! Non-taggers win.")
		rpc("rpc_show_round_message", "Time’s up! Runners win!", 3.0)
	else:
		print("[GM] Round ended. Winner:", winner_peer)
		if winner_peer == current_tagger:
			rpc("rpc_show_round_message", "Tagger Wins!", 3.0)
		else:
			rpc("rpc_show_round_message", "Runners Win!", 3.0)

	# stop and cleanup timer
	if round_timer:
		round_timer.stop()
		round_timer.queue_free()
		round_timer = null

	# clear freeze visuals
	frozen_set.clear()
	for pid in players.keys():
		rpc("rpc_set_frozen", pid, false)

	round_end_time = 0
	if timer_label:
		timer_label.text = "Round Over!"

	# server auto-start next round after a short pause
	if multiplayer.is_server():
		await get_tree().create_timer(3.0).timeout
		start_new_round()

# ---------------- helpers ----------------
func _is_ai(peer_id:int) -> bool:
	return false

@rpc("any_peer")
func rpc_round_timer_start(end_time: float):
	round_end_time = end_time

# ---------------- UI message helpers ----------------
@rpc("any_peer")
func rpc_show_round_message(text: String, duration: float = 2.0):
	show_round_message(text, duration)

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
