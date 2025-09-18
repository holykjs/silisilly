extends CharacterBody2D

@export var speed: float = 200.0
@export var jump_force: float = -450.0
@export var gravity: float = 1200.0
@export var water_speed: float = 120.0
@export var water_jump_force: float = -250.0
@export var water_gravity: float = 600.0

@export var is_local: bool = true
@export var debug: bool = true

var peer_id: int = -1
var frozen: bool = false
var is_sili: bool = false
var is_in_water: bool = false
var water_overlap_count: int = 0

@onready var anim_sprite: AnimatedSprite2D = $Sprite
@onready var tag_area: Area2D = $TagArea
@onready var name_label: Label = $NameLabel

# track nearby players via TagArea signals
var nearby_players: Array = []

# ---------------- SKINS ----------------
var current_skin_resource: Resource = null # Renamed for clarity on what it stores

func _ready() -> void:
	if debug:
		print("[PLAYER] ready — peer_id:", peer_id, " is_local:", is_local)

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
		anim_sprite.modulate = Color(0.7,0.8,1.0) if frozen else (Color(1,0.7,0.7) if is_sili else Color(1,1,1))
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

	var dir := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
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


	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = current_jump

	move_and_slide()

	if is_local:
		if Input.is_action_just_pressed("action_tag"):
			_attempt_tag()
		if Input.is_action_just_pressed("action_rescue"):
			_attempt_rescue()

func _play_anim(name: String) -> void:
	if not is_instance_valid(anim_sprite) or not is_instance_valid(anim_sprite.sprite_frames):
		if debug: printerr("[PLAYER] _play_anim: Cannot play animation '", name, "'. SpriteFrames or anim_sprite not valid.")
		return

	if anim_sprite.sprite_frames.has_animation(name):
		if anim_sprite.animation != name or not anim_sprite.is_playing():
			anim_sprite.play(name)
	elif debug:
		printerr("[PLAYER] _play_anim: Animation '", name, "' not found in current SpriteFrames.")


# ... (rest of the script unchanged) ...


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
	if frozen or not is_sili:
		if debug: print("[PLAYER] cannot tag (frozen or not sili)")
		return

	for p in nearby_players:
		if not p: continue
		if p == self: continue
		if p.has_method("is_network_player") and p.peer_id != peer_id:
			rpc_id(1, "rpc_request_tag", peer_id, p.peer_id)
			if debug: print("[PLAYER] requested tag ->", p.peer_id)
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
			rpc_id(1, "rpc_request_rescue", peer_id, p.peer_id)
			if debug: print("[PLAYER] requested rescue ->", p.peer_id)
			return
	if debug:
		print("[PLAYER] no frozen target nearby")


# ---------------- Water detection ----------------
func _on_area_entered(area: Area2D) -> void:
	if area.is_in_group("water"):
		water_overlap_count += 1
		is_in_water = water_overlap_count > 0
		if debug: print("[PLAYER] Entered water:", water_overlap_count)


func _on_area_exited(area: Area2D) -> void:
	if area.is_in_group("water"):
		water_overlap_count = max(water_overlap_count - 1, 0)
		is_in_water = water_overlap_count > 0
		if debug: print("[PLAYER] Exited water:", water_overlap_count)
