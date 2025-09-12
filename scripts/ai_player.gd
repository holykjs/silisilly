extends CharacterBody2D

@export var speed := 160
var target_peer := -1
@onready var agent := $NavigationAgent2D

func _physics_process(delta):
	if not GameManager: return
	if target_peer == -1 or GameManager.is_player_frozen(target_peer):
		target_peer = _choose_nearest_unfrozen()
	if target_peer == -1:
		return
	var target_node = GameManager.get_player_node(target_peer)
	if not target_node:
		return
	agent.set_target_position(target_node.global_position)
	var next_pos = agent.get_next_path_position()
	if next_pos != Vector2.ZERO:
		var dir = (next_pos - global_position).normalized()
		velocity = dir * speed
		move_and_slide()
	# attempt tag if close
	if global_position.distance_to(target_node.global_position) < 18.0:
		rpc_id(get_multiplayer_authority(), "rpc_request_tag", multiplayer.get_unique_id(), target_peer)

func _choose_nearest_unfrozen() -> int:
	var nearest := -1
	var bestd := 1e9
	for pid in GameManager.players_order:
		if GameManager.frozen_set.has(pid): continue
		if pid == GameManager.current_tagger: continue
		var pn = GameManager.players.get(pid, null)
		if pn:
			var d = global_position.distance_to(pn.global_position)
			if d < bestd:
				bestd = d
				nearest = pid
	return nearest
