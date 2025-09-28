extends CharacterBody2D

@export var speed: float = 200.0
@export var jump_force: float = -450.0
@export var gravity: float = 1200.0
@export var water_speed: float = 150.0
@export var water_jump_force: float = -300.0
@export var water_gravity: float = 700.0

@export var is_local: bool = true
@export var debug: bool = false  # Set to true for debug prints
var peer_id: int = -1
var frozen: bool = false
var is_sili: bool = false
var is_in_water: bool = false
var water_overlap_count: int = 0

# AI behavior variables
var is_ai: bool = false
var ai_target: Node = null
var ai_state: String = "idle"  # idle, chasing, fleeing, rescuing, wandering
var ai_decision_timer: float = 0.0
var ai_decision_interval: float = 1.0  # Make decisions every second
var ai_reaction_delay: float = 0.0  # Delay before reacting to new situations
var ai_confusion_timer: float = 0.0  # Sometimes AI gets "confused"
var ai_personality: Dictionary = {}  # Individual AI personality traits
var ai_wander_target: Vector2 = Vector2.ZERO  # Random wander destination
var ai_wander_timer: float = 0.0  # Time spent wandering
var ai_idle_timer: float = 0.0  # Time spent being idle
var ai_stuck_timer: float = 0.0  # Track if AI is stuck
var ai_last_position: Vector2 = Vector2.ZERO  # For stuck detection
var ai_prediction_target: Vector2 = Vector2.ZERO  # Predicted target position
var ai_coordination_offset: Vector2 = Vector2.ZERO  # Offset for coordinated attacks
var ai_last_seen_position: Vector2 = Vector2.ZERO  # Last known human position
var ai_search_timer: float = 0.0  # Time spent searching

# Enhanced AI variables for natural movement
var ai_movement_style: String = "direct"  # direct, flanking, ambush, patrol
var ai_velocity_history: Array = []  # Track target's movement patterns
var ai_preferred_distance: float = 60.0  # Optimal hunting distance
var ai_aggression_buildup: float = 0.0  # Increases over time when chasing
var ai_last_tag_attempt: float = 0.0  # Cooldown for tag attempts
var ai_feint_timer: float = 0.0  # For feinting movements
var ai_momentum: Vector2 = Vector2.ZERO  # Smooth movement momentum
var ai_tactical_state: String = "hunt"  # hunt, surround, intercept, ambush
var ai_human_behavior_data: Dictionary = {}  # Learn human patterns
var ai_escape_route_timer: float = 0.0  # Track escape route predictions
var ai_corner_pressure: float = 0.0  # Apply pressure when human is cornered

@onready var anim_sprite: AnimatedSprite2D = $Sprite
@onready var tag_area: Area2D = $TagArea
@onready var name_label: Label = $NameLabel
@onready var nav_agent: NavigationAgent2D = $NavigationAgent2D

# track nearby players via TagArea signals
var nearby_players: Array = []

# ---------------- SKINS ----------------
var current_skin_resource: Resource = null # Renamed for clarity on what it stores

func _ready() -> void:
	if debug:
		print("[PLAYER] ready — peer_id:", peer_id, " is_local:", is_local)
	
	# Configure collision layers for tag game
	# Players should pass through each other, only collide with environment
	collision_layer = 4  # Players are on layer 4 (separate from other players)
	collision_mask = 2   # Collide with platforms/environment (layer 2), not other player bodies
	
	# Layer setup:
	# Layer 2: Platforms/environment AND TagArea detection
	# Layer 4: Player bodies (don't collide with each other)
	# TagArea will still detect other players for tagging/rescue

	# connect TagArea signals
	if tag_area:
		if not tag_area.is_connected("body_entered", Callable(self, "_on_tag_area_body_entered")):
			tag_area.connect("body_entered", Callable(self, "_on_tag_area_body_entered"))
		if not tag_area.is_connected("body_exited", Callable(self, "_on_tag_area_body_exited")):
			tag_area.connect("body_exited", Callable(self, "_on_tag_area_body_exited"))

	# Initial skin assignment on _ready_ for non-networked local players or if GameManager hasn't set it yet.
	# For network players, GameManager's rpc_create_player will eventually call set_skin.
	if current_skin_resource == null:
		_assign_random_skin_if_needed() # Use a helper for this initial assignment

	# Always try to apply whatever skin we have, in case GameManager set it before _ready()
	if current_skin_resource:
		set_skin(current_skin_resource)
	else:
		if debug: print("[PLAYER] _ready: No current_skin_resource after initial assignment attempt.")
		# Force fallback to ensure a visual representation
		set_skin(null) # Call set_skin with null to trigger the fallback logic


	# Ensure the sprite is visible at start
	if anim_sprite:
		anim_sprite.show()
		# Also, ensure it plays a default animation if frames are ready
		if is_instance_valid(anim_sprite.sprite_frames):
			_play_default_animation()


func is_network_player() -> bool:
	return true

func _assign_random_skin_if_needed() -> void:
	if current_skin_resource != null:
		return # Skin already set, do not reassign randomly

	var gm = get_tree().get_root().get_node_or_null("GameManager")
	if gm and gm.has_method("get_random_skin_resource"):
		current_skin_resource = gm.get_random_skin_resource()
		if debug and current_skin_resource:
			print("[PLAYER] assigned initial random skin from GameManager:",
				current_skin_resource.resource_path if current_skin_resource.resource_path else current_skin_resource)
	elif debug:
		print("[PLAYER] _assign_random_skin_if_needed: GameManager or get_random_skin_resource not found.")


func set_skin(skin: Resource) -> void:
	if not is_instance_valid(anim_sprite):
		if debug:
			printerr("[PLAYER] set_skin: anim_sprite is not valid, cannot set skin.")
		return

	current_skin_resource = skin # Store the actual resource reference

	# Ensure anim_sprite is visible
	anim_sprite.show()

	# SpriteFrames resource
	if skin is SpriteFrames:
		if debug: print("[PLAYER] set_skin: Applying SpriteFrames resource:", skin.resource_path if skin.resource_path else skin)
		anim_sprite.sprite_frames = skin
		_play_default_animation()

	# Single Texture2D
	elif skin is Texture2D:
		if debug: print("[PLAYER] set_skin: Converting Texture2D to SpriteFrames:", skin.resource_path if skin.resource_path else skin)
		var frames := SpriteFrames.new()
		frames.add_animation("idle")
		frames.add_frame("idle", skin)
		anim_sprite.sprite_frames = frames
		_play_default_animation()

	# Fallback (e.g., if skin is null or unsupported type)
	else:
		if debug:
			printerr("[PLAYER] set_skin: Unsupported or null resource type. Using fallback default skin. Received:", skin)
		var dummy := SpriteFrames.new()
		dummy.add_animation("idle")
		var img := Image.create(32, 32, false, Image.FORMAT_RGBA8)
		img.fill(Color.RED)
		var tex := ImageTexture.create_from_image(img)
		dummy.add_frame("idle", tex)
		anim_sprite.sprite_frames = dummy
		_play_default_animation()

	# Ensure the animation plays after setting the frames
	if is_instance_valid(anim_sprite.sprite_frames):
		anim_sprite.play()
	elif debug:
		printerr("[PLAYER] set_skin: Failed to play animation, sprite_frames is still invalid after setting.")


func _play_default_animation() -> void:
	if not is_instance_valid(anim_sprite) or not is_instance_valid(anim_sprite.sprite_frames):
		if debug:
			printerr("[PLAYER] _play_default_animation: anim_sprite or sprite_frames not valid.")
		anim_sprite.stop()
		return

	if anim_sprite.sprite_frames.has_animation("idle"):
		anim_sprite.animation = "idle"
	elif anim_sprite.sprite_frames.get_animation_names().size() > 0:
		anim_sprite.animation = anim_sprite.sprite_frames.get_animation_names()[0]
	else:
		if debug: printerr("[PLAYER] _play_default_animation: No animations found in sprite frames.")
		anim_sprite.stop()
		return

	if not anim_sprite.is_playing():
		anim_sprite.play()

	if not anim_sprite.is_playing() or anim_sprite.animation != anim_sprite.animation:
		anim_sprite.play()


func respawn(pos: Vector2) -> void:
	# move and reset the player
	global_position = pos
	velocity = Vector2.ZERO
	frozen = false
	is_in_water = false
	water_overlap_count = 0
	is_sili = false

	# The skin assignment for respawn is now primarily handled by GameManager
	# calling `set_skin` before calling `respawn` on the player.
	# This `respawn` method on the player just ensures visual reset/animation.
	if current_skin_resource:
		set_skin(current_skin_resource) # Re-apply the current skin to ensure sprite frames are active
	else:
		if debug: printerr("[PLAYER] respawn: current_skin_resource is null, falling back to default.")
		set_skin(null) # Force fallback skin

	# idle anim reset (this is handled within set_skin for the most part now)
	if is_instance_valid(anim_sprite) and is_instance_valid(anim_sprite.sprite_frames):
		_play_default_animation()
	else:
		if debug: printerr("[PLAYER] respawn: anim_sprite or its frames not ready for idle anim reset after skin application.")


# ---------------- SILI / FROZEN ----------------
func set_sili(value: bool) -> void:
	is_sili = value
	if anim_sprite and is_instance_valid(anim_sprite):
		anim_sprite.modulate = Color(1,0.7,0.7) if is_sili else Color(1,1,1)
	if debug:
		print("[PLAYER] set_sili:", name, is_sili)


func set_frozen(value: bool) -> void:
	frozen = value
	if anim_sprite and is_instance_valid(anim_sprite):
		if frozen:
			anim_sprite.modulate = Color(0.7,0.8,1.0)
		elif is_sili:
			anim_sprite.modulate = Color(1,0.7,0.7)
		else:
			anim_sprite.modulate = Color(1,1,1)
	if frozen and is_instance_valid(anim_sprite):
		anim_sprite.stop()
	if debug:
		print("[PLAYER] set_frozen:", name, frozen)


# ---------------- PHYSICS ----------------
func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var current_gravity = water_gravity if is_in_water else gravity
	var move_speed = water_speed if is_in_water else speed
	var current_jump = water_jump_force if is_in_water else jump_force

	if not is_on_floor():
		velocity.y += current_gravity * delta
	else:
		if velocity.y > 0:
			velocity.y = 0

	var dir: float = 0.0
	
	# AI or Human input
	if is_ai:
		dir = _get_ai_input(delta)
	elif is_local:  # Only local players should respond to input
		dir = Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	else:
		dir = 0.0  # Remote players don't respond to local input
	
	# Set horizontal velocity
	velocity.x = dir * move_speed

	# Crucial check here
	if is_instance_valid(anim_sprite) and is_instance_valid(anim_sprite.sprite_frames):
		if dir != 0:
			anim_sprite.flip_h = dir < 0
			_play_anim("run")
		else:
			_play_anim("idle")
	else:
		# This is the message you're seeing. It means sprite_frames is not ready.
		# Add a temporary visual debug if this happens often:
		if debug:
			printerr("[PLAYER] _physics_process: anim_sprite or frames not ready for animation. (Showing debug)")
			# You could temporarily hide the sprite and show a label or another node
			# if you need stronger visual feedback that the sprite is broken.
			if anim_sprite: anim_sprite.hide()
			# Example: get_node("DebugLabel").text = "NO SPRITE"
		return # Skip animation logic if frames aren't ready


	# Handle jumping (human or AI)
	var should_jump = false
	if is_local and not is_ai:  # Only local human players
		should_jump = Input.is_action_just_pressed("jump")
	elif is_ai:
		should_jump = _should_ai_jump()
	
	if should_jump and is_on_floor():
		velocity.y = current_jump

	move_and_slide()
	
	# Sync position to other clients if this is the local player or AI (AI runs on server)
	if multiplayer.has_multiplayer_peer() and (is_local or (is_ai and multiplayer.is_server())):
		_sync_position_to_network()

	# Handle actions (human or AI)
	if is_local and not is_ai:  # Only local human players
		if Input.is_action_just_pressed("action_tag"):
			_attempt_tag()
		if Input.is_action_just_pressed("action_rescue"):
			_attempt_rescue()
	elif is_ai:
		_handle_ai_actions()

func _play_anim(anim_name: String) -> void:
	if not is_instance_valid(anim_sprite) or not is_instance_valid(anim_sprite.sprite_frames):
		if debug: printerr("[PLAYER] _play_anim: Cannot play animation '", anim_name, "'. SpriteFrames or anim_sprite not valid.")
		return
	
	if anim_sprite.sprite_frames.has_animation(anim_name):
		anim_sprite.play(anim_name)
	else:
		if debug: printerr("[PLAYER] _play_anim: Animation '", anim_name, "' not found in SpriteFrames.")
# ---------------- TagArea signal handlers ----------------
func _on_tag_area_body_entered(body: Node) -> void:
	if body == self:
		return
	if body.has_method("is_network_player"):
		if not nearby_players.has(body):
			nearby_players.append(body)
		if debug:
			print("[PLAYER] nearby added:", body.name)


func _on_tag_area_body_exited(body: Node) -> void:
	if body == self:
		return
	if nearby_players.has(body):
		nearby_players.erase(body)
		if debug:
			print("[PLAYER] nearby removed:", body.name)


# ---------------- Tagging / Rescue ----------------
func _attempt_tag() -> void:
	if frozen:
		if debug: print("[PLAYER] cannot tag (frozen)")
		return
	
	# Check if this player can tag
	var can_tag = false
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	
	if game_manager and game_manager.current_tagger == -1:  # Survival mode
		can_tag = (peer_id >= 1000)  # AI hunters can tag
	else:  # Normal mode
		can_tag = is_sili  # Only sili can tag
	
	if not can_tag:
		if debug: print("[PLAYER] cannot tag (not authorized)")
		return

	for p in nearby_players:
		if not p: continue
		if p == self: continue
		if p.has_method("is_network_player") and p.peer_id != peer_id:
			# Call GameManager's RPC function instead of trying to call RPC directly from player
			var gm = get_tree().get_first_node_in_group("game_manager")
			if gm and gm.has_method("rpc_request_tag"):
				gm.rpc_id(1, "rpc_request_tag", peer_id, p.peer_id)
				if debug: print("[PLAYER] AI Hunter ", peer_id, " requested tag ->", p.peer_id)
			else:
				if debug: print("[PLAYER] GameManager not found or missing rpc_request_tag method")
			return
	if debug:
		print("[PLAYER] no target found to tag")


func _attempt_rescue() -> void:
	if frozen:
		return

	for p in nearby_players:
		if not p: continue
		if p == self: continue
		if p.has_method("is_network_player") and p.frozen:
			# Call GameManager's RPC function instead of trying to call RPC directly from player
			var gm = get_tree().get_first_node_in_group("game_manager")
			if gm and gm.has_method("rpc_request_rescue"):
				gm.rpc_id(1, "rpc_request_rescue", peer_id, p.peer_id)
				if debug: print("[PLAYER] requested rescue ->", p.peer_id)
			else:
				if debug: print("[PLAYER] GameManager not found or missing rpc_request_rescue method")
			return
	if debug:
		print("[PLAYER] no frozen target nearby")


# ---------------- Water detection ----------------
func _on_area_entered(_area: Area2D) -> void:
	if _area.is_in_group("water"):
		water_overlap_count += 1
		is_in_water = water_overlap_count > 0
		if debug: print("[PLAYER] Entered water:", _area.name, " Count:", water_overlap_count, " is_in_water:", is_in_water)


func _on_area_exited(_area: Area2D) -> void:
	if _area.is_in_group("water"):
		water_overlap_count = max(water_overlap_count - 1, 0)
		is_in_water = water_overlap_count > 0
		if debug: print("[PLAYER] Exited water:", _area.name, " Count:", water_overlap_count, " is_in_water:", is_in_water)

# ---------------- AI BEHAVIOR SYSTEM ----------------
func setup_as_ai():
	"""Configure this player as AI"""
	is_ai = true
	is_local = false
	if debug: print("[PLAYER] Setup as AI - peer_id:", peer_id)
	
	# Generate unique AI personality
	_generate_ai_personality()
	
	# Setup navigation agent for pathfinding
	if nav_agent:
		nav_agent.path_desired_distance = 4.0
		nav_agent.target_desired_distance = 4.0
		nav_agent.path_max_distance = 50.0
		nav_agent.avoidance_enabled = true
		nav_agent.radius = 16.0
		if debug: print("[AI] NavigationAgent2D configured for peer_id:", peer_id)
	
	# Make AI more stable against collisions
	# Note: CharacterBody2D doesn't have mass property, using collision resistance instead
	
	# Visual indicator for AI players (will be overridden by survival mode colors)
	if name_label:
		name_label.modulate = Color.YELLOW  # AI players have yellow names
	
	# Check animations after a brief delay to ensure sprite is ready
	call_deferred("_check_ai_animations")

func _get_ai_input(delta: float) -> float:
	"""Get AI movement input (-1 to 1) with human-like behavior"""
	# Update timers
	ai_decision_timer += delta
	ai_idle_timer += delta
	ai_wander_timer += delta
	
	# Make decisions periodically
	if ai_decision_timer >= ai_decision_interval:
		ai_decision_timer = 0.0
		_update_ai_target()
	
	# Handle confusion (AI sometimes gets confused and stops)
	ai_confusion_timer -= delta
	if ai_confusion_timer > 0:
		return 0.0  # Stand still when confused
	
	# Random chance to get confused
	if randf() < ai_personality.get("confusion_chance", 0.05):
		ai_confusion_timer = randf_range(0.5, 1.5)
		return 0.0
	
	# Priority behavior based on state
	match ai_state:
		"chasing":
			return _get_chasing_input()
		"fleeing":
			return _get_fleeing_input()
		"rescuing":
			return _get_rescuing_input()
		"wandering":
			return _get_wandering_input()
		"idle":
			return _get_idle_input()
		_:
			return _get_idle_input()

func _get_chasing_input() -> float:
	"""Advanced AI input when chasing - uses prediction, learning, and tactical movement"""
	# Update timers and learning data
	_update_ai_learning()
	_check_if_stuck()
	
	if ai_target and is_instance_valid(ai_target):
		var distance = global_position.distance_to(ai_target.global_position)
		
		# Learn from human behavior patterns
		_analyze_human_behavior()
		
		# Determine tactical approach based on movement style and situation
		var movement_input = _calculate_tactical_movement(distance)
		
		# Apply momentum for smoother, more natural movement
		movement_input = _apply_movement_momentum(movement_input)
		
		# Add personality-based variations
		movement_input = _apply_personality_movement(movement_input, distance)
		
		return clamp(movement_input, -1.0, 1.0)
	else:
		# Search behavior - move towards last seen or patrol
		return _get_search_input()

func _calculate_chase_speed(distance: float) -> float:
	"""Calculate dynamic chase speed based on distance, urgency, and adaptive difficulty"""
	var base_speed = 1.0
	
	# Distance-based speed
	if distance < 80:
		base_speed = 1.4  # Very fast when very close
	elif distance < 150:
		base_speed = 1.3  # Fast when close
	elif distance < 300:
		base_speed = 1.1  # Slightly faster at medium range
	
	# Personality-based modifier
	var aggression = ai_personality.get("aggression", 0.8)
	base_speed *= (0.8 + aggression * 0.4)  # 0.8 to 1.2 multiplier
	
	# Apply dynamic difficulty adjustment
	base_speed = _get_dynamic_chase_speed(base_speed, distance)
	
	return base_speed

func _check_if_stuck():
	"""Detect if AI is stuck and needs alternative movement"""
	var current_pos = global_position
	var movement_threshold = 10.0  # Minimum movement expected
	
	if ai_last_position.distance_to(current_pos) < movement_threshold:
		ai_stuck_timer += get_physics_process_delta_time()
	else:
		ai_stuck_timer = 0.0
		ai_last_position = current_pos

func _get_search_input() -> float:
	"""Input when searching for the human player"""
	if nav_agent and nav_agent.target_position != Vector2.ZERO:
		var next_path_position = nav_agent.get_next_path_position()
		var direction = (next_path_position - global_position).normalized()
		return clamp(direction.x * 0.8, -1.0, 1.0)  # Moderate search speed
	else:
		# Random search movement
		if randf() < 0.15:  # 15% chance to change direction
			return randf_range(-0.6, 0.6)
	return 0.0

func _get_fleeing_input() -> float:
	"""AI input when fleeing from Sili"""
	if ai_target and is_instance_valid(ai_target):
		var direction = (global_position - ai_target.global_position).normalized()
		var distance = global_position.distance_to(ai_target.global_position)
		
		# Panic more when Sili is close
		var panic_factor = 1.0
		if distance < 100:
			panic_factor = 1.5  # Move faster when panicked
		
		# Add randomness for realistic movement
		var randomness = randf_range(-0.3, 0.3)
		return clamp(direction.x * panic_factor + randomness, -1.0, 1.0)
	return 0.0

func _get_rescuing_input() -> float:
	"""AI input when rescuing frozen players"""
	if ai_target and is_instance_valid(ai_target):
		var direction = (ai_target.global_position - global_position).normalized()
		# Move steadily toward frozen player
		var randomness = randf_range(-0.1, 0.1)
		return clamp(direction.x + randomness, -1.0, 1.0)
	return 0.0

func _get_wandering_input() -> float:
	"""AI input when wandering around"""
	# Check if we need a new wander target
	if ai_wander_target == Vector2.ZERO or ai_wander_timer > 3.0:
		_set_new_wander_target()
		ai_wander_timer = 0.0
	
	# Move toward wander target
	var direction = (ai_wander_target - global_position).normalized()
	var distance = global_position.distance_to(ai_wander_target)
	
	# If close to target, pick a new one
	if distance < 50:
		_set_new_wander_target()
	
	# Add natural movement variation
	var randomness = randf_range(-0.2, 0.2)
	return clamp(direction.x + randomness, -1.0, 1.0)

func _get_idle_input() -> float:
	"""AI input when idle - occasionally move around"""
	# After being idle for a while, start wandering
	if ai_idle_timer > randf_range(2.0, 5.0):
		ai_state = "wandering"
		ai_idle_timer = 0.0
		_set_new_wander_target()
		return _get_wandering_input()
	
	# Small random movements while idle
	if randf() < 0.02:  # 2% chance per frame
		return randf_range(-0.4, 0.4)
	
	return 0.0

func _set_new_wander_target():
	"""Set a new random wander destination"""
	# Get a random point within reasonable distance
	var wander_distance = randf_range(100, 300)
	var wander_angle = randf() * TAU  # Random angle
	
	ai_wander_target = global_position + Vector2(
		cos(wander_angle) * wander_distance,
		sin(wander_angle) * wander_distance
	)
	
	if debug: print("[AI] New wander target for ", peer_id, ": ", ai_wander_target)

func _update_ai_target():
	"""Update AI target and state based on game situation"""
	# Find GameManager
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	if not game_manager:
		return
	
	# Check if we're in survival mode (all AI are hunters)
	if game_manager.current_tagger == -1:  # Survival mode
		# In survival mode, ALL AI (peer_id >= 1000) are hunters
		if peer_id >= 1000:  # This AI is a hunter
			if debug and ai_decision_timer <= 0:
				print("[AI] ", peer_id, " is HUNTER in survival mode")
			_ai_hunter_behavior(game_manager)
		else:
			# This shouldn't happen in survival mode, but fallback to idle
			if debug: print("[AI] ", peer_id, " ERROR: Non-AI in survival mode")
			ai_state = "idle"
			ai_target = null
	elif is_sili:
		# AI Sili behavior: chase nearest unfrozen player
		if debug and ai_decision_timer <= 0:
			print("[AI] ", peer_id, " is SILI in normal mode")
		_ai_sili_behavior(game_manager)
	else:
		# AI player behavior: flee from Sili, rescue frozen players
		if debug and ai_decision_timer <= 0:
			print("[AI] ", peer_id, " is REGULAR PLAYER (fleeing/rescuing)")
		_ai_player_behavior(game_manager)

func _ai_hunter_behavior(game_manager):
	"""Advanced AI behavior in survival mode - smart coordinated hunting"""
	var human_player = null
	
	# Find the human player (peer_id = 1)
	for pid in game_manager.players_order:
		if pid == 1:  # Human player
			human_player = game_manager.players.get(pid, null)
			break
	
	if human_player and is_instance_valid(human_player):
		# Update last seen position and predict movement
		ai_last_seen_position = human_player.global_position
		_predict_human_movement(human_player)
		_calculate_coordination_offset(game_manager)
		_update_tactical_state(human_player, game_manager)
		
		ai_target = human_player
		ai_state = "chasing"
		ai_idle_timer = 0.0
		ai_wander_timer = 0.0
		ai_search_timer = 0.0
		
		# Use enhanced prediction for smarter pathfinding
		var target_position = _get_enhanced_prediction() + ai_coordination_offset
		
		# Set navigation target for pathfinding
		if nav_agent:
			nav_agent.target_position = target_position
		
		var distance = global_position.distance_to(human_player.global_position)
		
		# Dynamic corner pressure detection
		_update_corner_pressure(human_player)
		
		if debug and ai_decision_timer <= 0: 
			print("[AI Hunter] ", peer_id, " (", ai_personality.archetype, ") CHASING human at distance: ", distance, " tactical_state: ", ai_tactical_state)
	else:
		# Smart searching behavior when human is not visible
		if debug and ai_decision_timer <= 0:
			print("[AI Hunter] ", peer_id, " CANNOT FIND human player - searching")
		_ai_search_behavior()

func _predict_human_movement(human_player):
	"""Predict where the human will be based on their velocity"""
	if not human_player.has_method("get_velocity"):
		ai_prediction_target = human_player.global_position
		return
	
	var human_velocity: Vector2 = Vector2.ZERO
	if human_player.has_method("get_velocity"):
		human_velocity = human_player.velocity
	var prediction_time = ai_personality.get("reaction_time", 0.5)
	
	# Predict future position based on current velocity
	ai_prediction_target = human_player.global_position + (human_velocity * prediction_time)
	
	# Add some randomness to avoid all AI targeting the exact same spot
	var randomness = Vector2(randf_range(-20, 20), randf_range(-20, 20))
	ai_prediction_target += randomness

func _calculate_coordination_offset(game_manager):
	"""Calculate offset for coordinated attacks to surround the human"""
	var ai_hunters = []
	var my_index = 0
	
	# Find all AI hunters and my position among them
	for pid in game_manager.players_order:
		if pid >= 1000:  # AI player
			ai_hunters.append(pid)
			if pid == peer_id:
				my_index = ai_hunters.size() - 1
	
	if ai_hunters.size() <= 1:
		ai_coordination_offset = Vector2.ZERO
		return
	
	# Calculate angle for surrounding the target
	var angle_per_hunter = TAU / ai_hunters.size()
	var my_angle = angle_per_hunter * my_index
	var coordination_radius = 80.0  # Distance to spread around target
	
	ai_coordination_offset = Vector2(
		cos(my_angle) * coordination_radius,
		sin(my_angle) * coordination_radius
	)

func _ai_search_behavior():
	"""Smart searching when human is not visible"""
	ai_state = "chasing"  # Maintain hunting urgency
	ai_search_timer += get_physics_process_delta_time()
	
	# If we have a last seen position, search around it
	if ai_last_seen_position != Vector2.ZERO:
		# Expand search radius over time
		var search_radius = min(100 + (ai_search_timer * 50), 300)
		var search_angle = ai_search_timer * 2.0  # Rotate search pattern
		
		var search_offset = Vector2(
			cos(search_angle) * search_radius,
			sin(search_angle) * search_radius
		)
		
		var search_target = ai_last_seen_position + search_offset
		
		if nav_agent:
			nav_agent.target_position = search_target
		
		if debug and ai_decision_timer <= 0:
			print("[AI Hunter] ", peer_id, " searching around last seen position, radius: ", search_radius)
	else:
		# No last seen position, patrol the map
		if ai_wander_target == Vector2.ZERO or ai_wander_timer > 2.0:
			_set_aggressive_patrol_target()
			ai_wander_timer = 0.0

func _set_aggressive_patrol_target():
	"""Set patrol target for aggressive map coverage"""
	# Get map bounds (approximate)
	var map_center = Vector2(500, 300)  # Adjust based on your map size
	var patrol_radius = randf_range(200, 400)
	var patrol_angle = randf() * TAU
	
	ai_wander_target = map_center + Vector2(
		cos(patrol_angle) * patrol_radius,
		sin(patrol_angle) * patrol_radius
	)
	
	if nav_agent:
		nav_agent.target_position = ai_wander_target

# ============ ENHANCED AI MOVEMENT FUNCTIONS ============

func _update_ai_learning():
	"""Update AI learning timers and data"""
	ai_aggression_buildup += get_physics_process_delta_time() * 0.1
	ai_aggression_buildup = min(ai_aggression_buildup, 2.0)  # Cap at 2x aggression
	
	ai_last_tag_attempt += get_physics_process_delta_time()
	ai_feint_timer += get_physics_process_delta_time()
	ai_escape_route_timer += get_physics_process_delta_time()
	
	# Update adaptive difficulty
	_update_adaptive_difficulty()

func _analyze_human_behavior():
	"""Analyze and learn from human player movement patterns"""
	if not ai_target or not is_instance_valid(ai_target):
		return
	
	# Track velocity history for pattern recognition
	if ai_target.has_method("get_velocity"):
		var human_velocity = ai_target.velocity
		ai_velocity_history.append(human_velocity)
		
		# Keep only recent history (last 2 seconds at 60fps)
		if ai_velocity_history.size() > 120:
			ai_velocity_history.pop_front()
		
		# Update behavior data
		if ai_velocity_history.size() > 10:
			var avg_velocity = Vector2.ZERO
			for vel in ai_velocity_history:
				avg_velocity += vel
			avg_velocity /= ai_velocity_history.size()
			
			ai_human_behavior_data.preferred_directions = avg_velocity.normalized()
			ai_human_behavior_data.average_speed = avg_velocity.length()

func _calculate_tactical_movement(distance: float) -> float:
	"""Calculate movement based on AI tactical state and personality"""
	var base_direction = Vector2.ZERO
	var target_position = ai_target.global_position
	
	# Enhanced prediction with learned behavior
	var predicted_position = _get_enhanced_prediction()
	
	match ai_movement_style:
		"direct":
			base_direction = _get_direct_approach(predicted_position)
		"flanking":
			base_direction = _get_flanking_approach(predicted_position, distance)
		"ambush":
			base_direction = _get_ambush_approach(predicted_position, distance)
		"patrol":
			base_direction = _get_coordinated_approach(predicted_position, distance)
	
	# Apply tactical state modifications
	base_direction = _apply_tactical_state(base_direction, distance)
	
	return base_direction.x

func _get_enhanced_prediction() -> Vector2:
	"""Enhanced prediction using velocity history and behavior analysis"""
	if not ai_target or not is_instance_valid(ai_target):
		return ai_target.global_position if ai_target else Vector2.ZERO
	
	var base_prediction = ai_target.global_position
	var distance = global_position.distance_to(ai_target.global_position)
	
	# Use velocity history for better prediction
	if ai_velocity_history.size() > 5:
		var recent_velocity = Vector2.ZERO
		var samples = min(ai_velocity_history.size(), 30)  # Last 0.5 seconds
		
		for i in range(ai_velocity_history.size() - samples, ai_velocity_history.size()):
			recent_velocity += ai_velocity_history[i]
		recent_velocity /= samples
		
		# Predict based on learned patterns
		var prediction_time = ai_personality.get("reaction_time", 0.5) * randf_range(0.8, 1.2)
		base_prediction += recent_velocity * prediction_time
		
		# Add escape route prediction
		if distance < ai_human_behavior_data.panic_threshold:
			var escape_direction = ai_human_behavior_data.preferred_directions
			if escape_direction.length() > 0.1:
				base_prediction += escape_direction * 50.0  # Predict escape
	
	return base_prediction

func _get_direct_approach(target_pos: Vector2) -> Vector2:
	"""Direct aggressive approach - straight line with slight unpredictability"""
	var direction = (target_pos - global_position).normalized()
	
	# Add slight weaving for more natural movement
	var weave_intensity = 0.1 * ai_personality.get("aggression", 0.8)
	var weave_offset = sin(Time.get_time_dict_from_system().second * 3.0) * weave_intensity
	
	direction.x += weave_offset
	return direction.normalized()

func _get_flanking_approach(target_pos: Vector2, distance: float) -> Vector2:
	"""Flanking approach - try to get to the side or behind target"""
	var direct_direction = (target_pos - global_position).normalized()
	
	# Calculate flanking angle based on target's movement
	var flank_angle = PI * 0.5  # 90 degrees
	if ai_human_behavior_data.preferred_directions.length() > 0.1:
		# Flank in the direction opposite to human's preferred escape
		var escape_dir = ai_human_behavior_data.preferred_directions
		flank_angle = escape_dir.angle() + PI  # Opposite direction
	
	# Adjust approach based on distance
	if distance > ai_preferred_distance:
		# Move closer while flanking
		var flank_direction = Vector2(cos(flank_angle), sin(flank_angle))
		return (direct_direction * 0.7 + flank_direction * 0.3).normalized()
	else:
		# Circle around at optimal distance
		var perpendicular = Vector2(-direct_direction.y, direct_direction.x)
		return perpendicular.normalized()

func _get_ambush_approach(target_pos: Vector2, distance: float) -> Vector2:
	"""Ambush approach - wait and predict, then strike"""
	# If far away, move to ambush position
	if distance > ai_preferred_distance * 1.5:
		# Move to intercept predicted path
		var predicted_path = ai_human_behavior_data.preferred_directions
		if predicted_path.length() > 0.1:
			var intercept_point = target_pos + predicted_path * distance * 0.3
			return (intercept_point - global_position).normalized()
		else:
			return (target_pos - global_position).normalized() * 0.5  # Slow approach
	else:
		# Wait and prepare to strike
		if ai_personality.get("patience", 0.5) > randf():
			return Vector2.ZERO  # Wait
		else:
			# Strike when target is close
			return (target_pos - global_position).normalized()

func _get_coordinated_approach(target_pos: Vector2, distance: float) -> Vector2:
	"""Coordinated approach - work with other AI hunters"""
	var base_direction = (target_pos + ai_coordination_offset - global_position).normalized()
	
	# Adjust based on other AI positions
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	if game_manager:
		var other_hunters = []
		for pid in game_manager.players_order:
			if pid >= 1000 and pid != peer_id:  # Other AI hunters
				var other_ai = game_manager.players.get(pid, null)
				if other_ai and is_instance_valid(other_ai):
					other_hunters.append(other_ai)
		
		# Avoid clustering with other hunters
		for hunter in other_hunters:
			var hunter_distance = global_position.distance_to(hunter.global_position)
			if hunter_distance < 100:  # Too close to another hunter
				var avoid_direction = (global_position - hunter.global_position).normalized()
				base_direction += avoid_direction * 0.3
	
	return base_direction.normalized()

func _apply_tactical_state(direction: Vector2, distance: float) -> Vector2:
	"""Apply tactical state modifications to movement"""
	match ai_tactical_state:
		"hunt":
			# Standard hunting behavior
			return direction
		"surround":
			# Move to surround position
			var surround_angle = ai_coordination_offset.angle()
			var surround_direction = Vector2(cos(surround_angle), sin(surround_angle))
			return (direction * 0.6 + surround_direction * 0.4).normalized()
		"intercept":
			# Move to intercept escape routes
			var escape_prediction = ai_human_behavior_data.preferred_directions
			if escape_prediction.length() > 0.1:
				var intercept_direction = escape_prediction.rotated(PI * 0.5)  # Perpendicular
				return (direction * 0.4 + intercept_direction * 0.6).normalized()
		"ambush":
			# Slow, patient movement
			return direction * ai_personality.get("patience", 0.5)
	
	return direction

func _apply_movement_momentum(input: float) -> float:
	"""Apply momentum for smoother, more natural movement"""
	var target_momentum = Vector2(input, 0)
	
	# Smooth momentum transition
	var momentum_factor = 0.15  # How quickly to change direction
	ai_momentum = ai_momentum.lerp(target_momentum, momentum_factor)
	
	# Add slight random variation for natural movement
	var natural_variation = randf_range(-0.05, 0.05) * ai_personality.get("confusion_chance", 0.01) * 10
	
	return ai_momentum.x + natural_variation

func _apply_personality_movement(input: float, distance: float) -> float:
	"""Apply personality-based movement modifications"""
	var modified_input = input
	
	# Aggression affects speed and directness
	var aggression = ai_personality.get("aggression", 0.8) + (ai_aggression_buildup * 0.2)
	modified_input *= (0.7 + aggression * 0.5)  # 0.7 to 1.2 speed multiplier
	
	# Tactical intelligence affects precision
	var intelligence = ai_personality.get("tactical_intelligence", 0.7)
	if intelligence > 0.8:
		# Smart AI uses feinting
		if ai_feint_timer > randf_range(2.0, 4.0):
			ai_feint_timer = 0.0
			modified_input *= -0.3  # Brief feint in opposite direction
	
	# Patience affects when to commit to attack
	if distance < ai_preferred_distance * 0.5:
		var patience = ai_personality.get("patience", 0.5)
		if patience > 0.7 and ai_last_tag_attempt < 1.0:
			modified_input *= 0.5  # Wait for better opportunity
	
	return modified_input

func _update_tactical_state(human_player, game_manager):
	"""Update AI tactical state based on situation"""
	var distance = global_position.distance_to(human_player.global_position)
	var other_hunters_count = 0
	var closest_hunter_distance = 999999.0
	
	# Count other hunters and find closest one
	for pid in game_manager.players_order:
		if pid >= 1000 and pid != peer_id:  # Other AI hunters
			var other_ai = game_manager.players.get(pid, null)
			if other_ai and is_instance_valid(other_ai):
				other_hunters_count += 1
				var hunter_distance = global_position.distance_to(other_ai.global_position)
				closest_hunter_distance = min(closest_hunter_distance, hunter_distance)
	
	# Determine tactical state based on situation
	if other_hunters_count >= 2 and distance < 200:
		# Multiple hunters close - coordinate to surround
		ai_tactical_state = "surround"
	elif ai_corner_pressure > 0.5 and distance < 150:
		# Human is cornered - apply pressure
		ai_tactical_state = "intercept"
	elif ai_personality.archetype == "ambusher" and distance > ai_preferred_distance:
		# Ambusher waits for opportunity
		ai_tactical_state = "ambush"
	elif closest_hunter_distance < 120 and other_hunters_count > 0:
		# Coordinate with nearby hunters
		ai_tactical_state = "surround"
	else:
		# Standard hunting
		ai_tactical_state = "hunt"

func _update_corner_pressure(human_player):
	"""Calculate how cornered the human player is using proper boundary detection"""
	var human_pos = human_player.global_position
	var escape_routes = 0
	var check_distance = 150.0
	
	# Check escape routes in 8 directions
	var directions = [
		Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1),
		Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)
	]
	
	for direction in directions:
		var check_pos = human_pos + direction * check_distance
		# Check against map boundaries (standard map size is 1154x595)
		if check_pos.x > 30 and check_pos.x < 1124 and check_pos.y > 30 and check_pos.y < 565:
			# Additional check for platform obstacles using raycasting
			var space_state = get_world_2d().direct_space_state
			var query = PhysicsRayQueryParameters2D.create(human_pos, check_pos)
			query.exclude = [self]  # Exclude self from raycast
			var result = space_state.intersect_ray(query)
			
			if result.is_empty():
				escape_routes += 1  # Clear path found
		# If outside boundaries, this direction is blocked
	
	# Calculate pressure (fewer escape routes = higher pressure)
	ai_corner_pressure = 1.0 - (escape_routes / 8.0)
	ai_corner_pressure = max(ai_corner_pressure, 0.0)
	
	if debug and ai_decision_timer <= 0:
		print("[AI] Corner pressure for human: ", ai_corner_pressure, " (", escape_routes, "/8 escape routes)")

func _update_adaptive_difficulty():
	"""Adjust AI difficulty based on human player performance"""
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	if not game_manager:
		return
	
	# Update survival time
	ai_human_behavior_data.survival_time += get_physics_process_delta_time()
	
	# Calculate escape success rate
	if ai_human_behavior_data.total_encounters > 0:
		ai_human_behavior_data.escape_success_rate = float(ai_human_behavior_data.successful_escapes) / float(ai_human_behavior_data.total_encounters)
	
	# Adjust AI performance based on human success rate
	var target_success_rate = 0.3  # Aim for 30% human escape rate for balanced gameplay
	var performance_diff = ai_human_behavior_data.escape_success_rate - target_success_rate
	
	# Adjust AI aggression and reaction time
	if performance_diff > 0.2:  # Human escaping too often - make AI harder
		ai_personality.aggression = min(ai_personality.aggression * 1.05, 1.0)
		ai_personality.reaction_time = max(ai_personality.reaction_time * 0.95, 0.1)
		ai_decision_interval = max(ai_decision_interval * 0.95, 0.2)
	elif performance_diff < -0.2:  # Human getting caught too often - make AI easier
		ai_personality.aggression = max(ai_personality.aggression * 0.95, 0.5)
		ai_personality.reaction_time = min(ai_personality.reaction_time * 1.05, 1.0)
		ai_decision_interval = min(ai_decision_interval * 1.05, 2.0)

func _track_encounter_outcome(was_successful_escape: bool):
	"""Track the outcome of an encounter with the human player"""
	ai_human_behavior_data.total_encounters += 1
	if was_successful_escape:
		ai_human_behavior_data.successful_escapes += 1
	
	# Update difficulty every 5 encounters
	if ai_human_behavior_data.total_encounters % 5 == 0:
		_update_adaptive_difficulty()

func _get_dynamic_chase_speed(base_speed: float, distance: float) -> float:
	"""Get dynamically adjusted chase speed based on performance"""
	var adjusted_speed = base_speed
	
	# Adjust based on escape success rate
	var success_rate = ai_human_behavior_data.escape_success_rate
	if success_rate > 0.4:  # Human escaping too much
		adjusted_speed *= 1.2
	elif success_rate < 0.2:  # Human getting caught too much
		adjusted_speed *= 0.8
	
	# Distance-based adjustments
	if distance < 50:
		adjusted_speed *= 1.3  # Sprint when very close
	elif distance > 200:
		adjusted_speed *= 0.9  # Conserve energy when far
	
	return adjusted_speed

func _ai_sili_behavior(game_manager):
	"""AI behavior when this player is Sili (tagger)"""
	var nearest_target = null
	var nearest_distance = 999999.0
	
	# Find nearest unfrozen player
	for pid in game_manager.players_order:
		if pid == peer_id: continue  # Skip self
		if game_manager.frozen_set.has(pid): continue  # Skip frozen
		
		var player_node = game_manager.players.get(pid, null)
		if player_node:
			var distance = global_position.distance_to(player_node.global_position)
			if distance < nearest_distance:
				nearest_distance = distance
				nearest_target = player_node
	
	if nearest_target:
		ai_target = nearest_target
		ai_state = "chasing"
	else:
		ai_target = null
		ai_state = "idle"

func _ai_player_behavior(game_manager):
	"""AI behavior when this player is a regular player (not Sili)"""
	# Priority 1: Flee from Sili if nearby
	var sili_nearby = null
	var frozen_nearby = null
	
	# Look for Sili and frozen players
	for pid in game_manager.players_order:
		if pid == peer_id: continue  # Skip self
		
		var player_node = game_manager.players.get(pid, null)
		if not player_node: continue
		
		var distance = global_position.distance_to(player_node.global_position)
		
		# Check if this is Sili and nearby (increased detection range)
		if pid == game_manager.current_tagger and distance < 300:
			sili_nearby = player_node
			break  # Fleeing is top priority
		
		# Check for frozen players to rescue (increased range)
		if game_manager.frozen_set.has(pid) and distance < 200 and not frozen_nearby:
			frozen_nearby = player_node
	
	# Set behavior based on priorities
	if sili_nearby:
		ai_target = sili_nearby
		ai_state = "fleeing"
		ai_idle_timer = 0.0  # Reset idle timer
	elif frozen_nearby:
		ai_target = frozen_nearby
		ai_state = "rescuing"
		ai_idle_timer = 0.0  # Reset idle timer
	else:
		# No immediate threats or rescue targets
		ai_target = null
		# If we've been idle too long, start wandering
		if ai_state == "idle" and ai_idle_timer > 2.0:
			ai_state = "wandering"
			_set_new_wander_target()
		elif ai_state not in ["wandering", "idle"]:
			ai_state = "idle"
			ai_idle_timer = 0.0

func _should_ai_jump() -> bool:
	"""Smart AI jumping for hunting and obstacle navigation"""
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	var is_survival_mode = game_manager and game_manager.current_tagger == -1
	
	# Strategic jumping in survival mode
	if is_survival_mode and ai_state == "chasing":
		if ai_target and is_instance_valid(ai_target):
			var distance = global_position.distance_to(ai_target.global_position)
			var target_y_diff = ai_target.global_position.y - global_position.y
			
			# Jump to reach higher platforms
			if target_y_diff < -50 and distance < 150:
				return randf() < 0.25  # 25% chance to jump up to target
			
			# Jump when very close for final catch attempt
			if distance < 60 and abs(target_y_diff) < 30:
				return randf() < 0.15  # 15% chance for catch jump
			
			# Smart obstacle jumping when stuck
			if ai_stuck_timer > 0.5:
				return randf() < 0.3  # 30% chance when stuck
			
			# Jump over small obstacles when moving horizontally
			if abs(velocity.x) > 50 and abs(target_y_diff) < 20:
				return randf() < 0.05  # 5% chance for obstacle clearing
	
	# Pathfinding-assisted jumping
	if nav_agent and ai_target:
		var next_path_pos = nav_agent.get_next_path_position()
		var path_y_diff = next_path_pos.y - global_position.y
		
		# Jump if pathfinding suggests going up
		if path_y_diff < -30 and abs(velocity.x) > 20:
			return randf() < 0.2  # 20% chance to follow path upward
	
	# Emergency unstuck jumping
	if ai_stuck_timer > 1.5:
		return randf() < 0.4  # 40% chance when really stuck
	
	# Minimal random jumping for natural movement
	var jump_chance = ai_personality.get("jump_frequency", 0.002)
	if randf() < jump_chance:
		return true
	
	return false

func _check_ai_animations():
	"""Check if AI animations are properly set up"""
	if anim_sprite and anim_sprite.sprite_frames:
		if debug: print("[AI] Animations ready for peer_id:", peer_id)
	else:
		if debug: print("[AI] WARNING: No animations for peer_id:", peer_id)

func _generate_ai_personality():
	"""Generate unique personality traits for this AI with specialized hunter profiles"""
	# Create specialized hunter archetypes for more diverse gameplay
	var archetype = randi() % 4
	
	match archetype:
		0:  # "Aggressive Pursuer" - Direct, fast, relentless
			ai_personality = {
				"aggression": randf_range(0.9, 1.0),
				"caution": randf_range(0.1, 0.3),
				"helpfulness": randf_range(0.3, 0.6),
				"reaction_time": randf_range(0.2, 0.4),
				"confusion_chance": randf_range(0.001, 0.005),
				"jump_frequency": randf_range(0.001, 0.003),
				"archetype": "pursuer",
				"preferred_distance": randf_range(40.0, 70.0),
				"patience": randf_range(0.2, 0.4),
				"tactical_intelligence": randf_range(0.6, 0.8)
			}
			ai_movement_style = "direct"
		1:  # "Tactical Flanker" - Smart positioning, patient
			ai_personality = {
				"aggression": randf_range(0.7, 0.9),
				"caution": randf_range(0.4, 0.7),
				"helpfulness": randf_range(0.5, 0.8),
				"reaction_time": randf_range(0.3, 0.6),
				"confusion_chance": randf_range(0.002, 0.008),
				"jump_frequency": randf_range(0.002, 0.005),
				"archetype": "flanker",
				"preferred_distance": randf_range(80.0, 120.0),
				"patience": randf_range(0.7, 0.9),
				"tactical_intelligence": randf_range(0.8, 1.0)
			}
			ai_movement_style = "flanking"
		2:  # "Ambush Predator" - Waits, predicts, strikes
			ai_personality = {
				"aggression": randf_range(0.6, 0.8),
				"caution": randf_range(0.5, 0.8),
				"helpfulness": randf_range(0.4, 0.7),
				"reaction_time": randf_range(0.4, 0.7),
				"confusion_chance": randf_range(0.003, 0.010),
				"jump_frequency": randf_range(0.001, 0.004),
				"archetype": "ambusher",
				"preferred_distance": randf_range(100.0, 150.0),
				"patience": randf_range(0.8, 1.0),
				"tactical_intelligence": randf_range(0.9, 1.0)
			}
			ai_movement_style = "ambush"
		3:  # "Coordinated Hunter" - Team player, supports others
			ai_personality = {
				"aggression": randf_range(0.8, 0.95),
				"caution": randf_range(0.3, 0.6),
				"helpfulness": randf_range(0.7, 1.0),
				"reaction_time": randf_range(0.25, 0.5),
				"confusion_chance": randf_range(0.002, 0.006),
				"jump_frequency": randf_range(0.002, 0.006),
				"archetype": "coordinator",
				"preferred_distance": randf_range(60.0, 100.0),
				"patience": randf_range(0.5, 0.7),
				"tactical_intelligence": randf_range(0.7, 0.9)
			}
			ai_movement_style = "patrol"
	
	# Set optimal hunting distance
	ai_preferred_distance = ai_personality.preferred_distance
	
	# Adjust decision interval based on personality (faster for hunters)
	ai_decision_interval = ai_personality.reaction_time * randf_range(0.8, 1.2)
	
	# Initialize behavior tracking
	ai_human_behavior_data = {
		"escape_patterns": [],
		"preferred_directions": Vector2.ZERO,
		"panic_threshold": 100.0,
		"average_speed": 0.0,
		"jump_frequency": 0.0,
		"successful_escapes": 0,
		"total_encounters": 0,
		"escape_success_rate": 0.0,
		"last_tag_time": 0.0,
		"survival_time": 0.0
	}
	
	if debug:
		print("[AI] Generated ", ai_personality.archetype, " personality for ", peer_id, ": ", ai_personality)

func _handle_ai_actions():
	"""Enhanced AI tagging and rescuing with smart timing"""
	if not ai_target or not is_instance_valid(ai_target):
		return
	
	# Reduced reaction delay for faster AI
	if ai_reaction_delay > 0:
		ai_reaction_delay -= get_physics_process_delta_time()
		return
	
	var distance = global_position.distance_to(ai_target.global_position)
	
	if ai_state == "chasing":
		# Track encounter for adaptive difficulty
		var was_close_encounter = distance < 100
		if was_close_encounter and ai_last_tag_attempt > 2.0:  # New encounter
			# Check if human escaped from previous encounter
			var human_escaped = distance > 150  # Human got away
			if ai_human_behavior_data.total_encounters > 0:  # Not first encounter
				_track_encounter_outcome(human_escaped)
		
		# Smart tagging range based on movement and prediction
		var tag_range = _calculate_tag_range(distance)
		
		if distance < tag_range:
			var tag_chance = _calculate_tag_chance(distance)
			
			if debug and ai_decision_timer <= 0:
				print("[AI Hunter] ", peer_id, " in range: ", distance, "/", tag_range, " chance: ", tag_chance)
			
			if randf() < tag_chance:
				if debug: print("[AI Hunter] ", peer_id, " attempting tag at distance: ", distance)
				_attempt_tag()
				# Reset reaction delay after tagging attempt
				ai_reaction_delay = ai_personality.get("reaction_time", 0.3) * 0.5
				ai_last_tag_attempt = 0.0  # Reset encounter timer
	elif ai_state == "rescuing" and distance < 50:
		# AI player tries to rescue (with helpfulness factor)
		if randf() < ai_personality.get("helpfulness", 0.7):
			_attempt_rescue()

func _calculate_tag_range(distance: float) -> float:
	"""Calculate dynamic tagging range based on AI state and target movement"""
	var base_range = 50.0
	
	# Increase range when target is moving fast (prediction)
	if ai_target and ai_target.has_method("get_velocity"):
		var target_speed: float = 0.0
		if ai_target.velocity:
			target_speed = ai_target.velocity.length()
		if target_speed > 100:
			base_range += 15.0  # Longer range for fast-moving targets
	
	# Increase range when AI is moving fast (momentum tagging)
	if velocity.length() > 80:
		base_range += 10.0
	
	# Survival mode gets extended range
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	if game_manager and game_manager.current_tagger == -1:
		base_range += 20.0  # Hunters get longer reach
	
	return base_range

func _calculate_tag_chance(distance: float) -> float:
	"""Calculate tagging success chance based on distance and conditions"""
	var base_chance = ai_personality.get("aggression", 0.8)
	
	# Higher chance when very close
	if distance < 30:
		base_chance += 0.3
	elif distance < 40:
		base_chance += 0.2
	
	# Bonus chance in survival mode
	var game_manager = get_tree().get_first_node_in_group("game_manager")
	if game_manager and game_manager.current_tagger == -1:
		base_chance += 0.25  # Hunters are more accurate
	
	# Bonus when target is moving predictably
	if ai_target and ai_target.velocity:
		var target_speed = ai_target.velocity.length()
		if target_speed < 50:  # Slow or stationary target
			base_chance += 0.2
	
	# Penalty when AI is stuck (less accurate)
	if ai_stuck_timer > 0.5:
		base_chance -= 0.1
	
	return clamp(base_chance, 0.1, 1.0)

# ---------------- Network Synchronization ----------------
var last_sync_time: float = 0.0
var sync_interval: float = 0.05  # Sync every 50ms (20 FPS)

func _sync_position_to_network():
	"""Sync position and movement to other clients"""
	var current_time = Time.get_unix_time_from_system()
	
	# Only sync at intervals to avoid network spam
	if current_time - last_sync_time < sync_interval:
		return
	
	last_sync_time = current_time
	
	# Send position, velocity, and animation state to other clients
	var flip_horizontal: bool = false
	if anim_sprite:
		flip_horizontal = anim_sprite.flip_h
	rpc("_receive_network_update", global_position, velocity, flip_horizontal)

@rpc("any_peer", "call_remote", "unreliable")
func _receive_network_update(pos: Vector2, vel: Vector2, flip_horizontal: bool):
	"""Receive position update from network"""
	if is_local:
		return  # Don't apply network updates to local player
	
	# Smooth interpolation to network position
	var tween = create_tween()
	tween.tween_property(self, "global_position", pos, 0.1)
	
	# Update velocity for physics consistency
	velocity = vel
	
	# Update sprite direction
	if anim_sprite:
		anim_sprite.flip_h = flip_horizontal
