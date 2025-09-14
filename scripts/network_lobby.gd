extends Node

const PORT := 52000
const MAX_PLAYERS := 5
var selected_map := "Map1.tscn"

func host_game():
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT, MAX_PLAYERS)
	if err != OK:
		push_error("Server failed: %s" % str(err))
		return
	multiplayer.multiplayer_peer = peer
	print("Hosting on port %d" % PORT)

func join_game(ip:String):
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, PORT)
	if err != OK:
		push_error("Client failed: %s" % str(err))
		return
	multiplayer.multiplayer_peer = peer
	print("Joining %s:%d" % [ip, PORT])

func set_selected_map(map_name:String):
	if multiplayer.is_server():
		selected_map = map_name
		print("Selected map:", selected_map)

func get_selected_map() -> String:
	return selected_map

func start_game():
	if multiplayer.is_server():
		# broadcast to all: please load this map file
		rpc("rpc_load_map", selected_map)
		# server also loads the map locally
		_load_map_local(selected_map)

@rpc("any_peer")
func rpc_load_map(map_name:String):
	_load_map_local(map_name)

func _load_map_local(map_name:String):
	var path = "res://maps/%s" % map_name
	if not FileAccess.file_exists(path):
		push_error("Map missing: " + path)
		return
	# Godot 4 scene loading
	get_tree().change_scene_to_file(path)
	# once scene loads, clients should request spawn (client side)
	if not multiplayer.is_server():
		rpc_id(get_multiplayer_authority(), "rpc_request_spawn", multiplayer.get_unique_id())
