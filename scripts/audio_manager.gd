extends Node

# AudioManager - Handles background music across scenes
# This should be added as an autoload in Project Settings

var background_music_player: AudioStreamPlayer
var button_sound_player: AudioStreamPlayer
var current_music_scene: String = ""
var menu_music: AudioStream
var button_sound: AudioStream
var music_check_timer: Timer

func _ready():
	# Create the background music player
	background_music_player = AudioStreamPlayer.new()
	add_child(background_music_player)
	
	# Create the button sound player
	button_sound_player = AudioStreamPlayer.new()
	add_child(button_sound_player)
	
	# Load the menu music and button sound
	menu_music = load("res://audios/intro-scene.mp3")
	button_sound = load("res://audios/button-bgm.mp3")
	
	# Ensure the audio stream has loop enabled if it's an AudioStreamMP3
	if menu_music is AudioStreamMP3:
		menu_music.loop = true
		print("[AudioManager] Enabled loop for MP3 audio stream")
	
	# Configure the background music player
	background_music_player.volume_db = -10
	background_music_player.bus = "Master"
	
	# Configure the button sound player
	button_sound_player.volume_db = -5  # Slightly louder than background music
	button_sound_player.bus = "Master"
	button_sound_player.stream = button_sound
	
	# Connect to finished signal to ensure seamless looping
	background_music_player.finished.connect(_on_music_finished)
	
	# Create a timer to periodically check if music is still playing
	music_check_timer = Timer.new()
	music_check_timer.wait_time = 2.0  # Check every 2 seconds
	music_check_timer.autostart = false
	music_check_timer.timeout.connect(_check_music_status)
	add_child(music_check_timer)

func play_menu_music():
	"""Play looping background music for MainMenu and Lobby"""
	if current_music_scene in ["MainMenu", "Lobby"] and background_music_player.playing:
		return  # Already playing the right music
	
	current_music_scene = "MainMenu"  # Both menu and lobby use same music
	
	# Set the stream if different
	if background_music_player.stream != menu_music:
		background_music_player.stream = menu_music
	
	# Start playing if not already playing
	if not background_music_player.playing:
		background_music_player.play()
		print("[AudioManager] Started menu music (will loop continuously)")
	else:
		print("[AudioManager] Menu music already playing")
	
	# Start the monitoring timer to ensure continuous playback
	if not music_check_timer.is_stopped():
		music_check_timer.stop()
	music_check_timer.start()

func stop_music():
	"""Stop all background music"""
	if background_music_player.playing:
		background_music_player.stop()
		print("[AudioManager] Stopped music")
	
	# Stop the monitoring timer
	if music_check_timer and not music_check_timer.is_stopped():
		music_check_timer.stop()
	
	current_music_scene = ""

func fade_out_music(duration: float = 1.0):
	"""Fade out music over specified duration"""
	if not background_music_player.playing:
		return
	
	var tween = create_tween()
	tween.tween_property(background_music_player, "volume_db", -80, duration)
	tween.tween_callback(stop_music)

func set_music_volume(volume_db: float):
	"""Set music volume in decibels"""
	background_music_player.volume_db = volume_db

func is_music_playing() -> bool:
	"""Check if music is currently playing"""
	return background_music_player.playing

func play_button_sound():
	"""Play button click sound effect"""
	if button_sound_player and button_sound:
		# Stop any currently playing button sound to allow rapid clicking
		if button_sound_player.playing:
			button_sound_player.stop()
		button_sound_player.play()
		print("[AudioManager] Played button sound")
	else:
		print("[AudioManager] Button sound not available")

func set_button_volume(volume_db: float):
	"""Set button sound volume in decibels"""
	if button_sound_player:
		button_sound_player.volume_db = volume_db

func connect_button_sound(button: Button):
	"""Automatically connect button sound to any button's pressed signal"""
	if button and button.is_node_ready():
		# Disconnect if already connected to avoid duplicates
		if button.pressed.is_connected(play_button_sound):
			button.pressed.disconnect(play_button_sound)
		# Connect the button sound
		button.pressed.connect(play_button_sound)
		print("[AudioManager] Connected button sound to: ", button.name)
	else:
		print("[AudioManager] Invalid button provided for sound connection")

func connect_button_sounds_in_scene(scene_node: Node):
	"""Automatically connect button sounds to all buttons in a scene"""
	var buttons_found = _connect_buttons_recursive(scene_node)
	print("[AudioManager] Connected button sounds to %d buttons in scene" % buttons_found)

func _connect_buttons_recursive(node: Node) -> int:
	"""Recursively find and connect all buttons in a node tree"""
	var buttons_found = 0
	
	if node is Button:
		connect_button_sound(node)
		buttons_found += 1
	
	for child in node.get_children():
		buttons_found += _connect_buttons_recursive(child)
	
	return buttons_found

func _on_music_finished():
	"""Called when music track finishes - restart it for seamless looping"""
	if current_music_scene in ["MainMenu", "Lobby"]:
		print("[AudioManager] Music finished, restarting for continuous loop")
		background_music_player.play()
	else:
		print("[AudioManager] Music finished, not in menu scene - stopping")

func _check_music_status():
	"""Periodically check if music should be playing and restart if needed"""
	if current_music_scene in ["MainMenu", "Lobby"]:
		if not background_music_player.playing:
			print("[AudioManager] Music stopped unexpectedly, restarting...")
			background_music_player.play()
	else:
		# Not in a menu scene, stop the timer
		if not music_check_timer.is_stopped():
			music_check_timer.stop()
