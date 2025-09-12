extends Node2D

# Move pointer visually to the player identified by peer_id
func move_to_peer(peer_id:int):
	var root = get_tree().current_scene
	if not root: return
	var players = root.get_node_or_null("Players")
	if not players: return
	for p in players.get_children():
		if p.has_method("is_network_player") and p.peer_id == peer_id:
			global_position = p.global_position + Vector2(0, -48)
			return
