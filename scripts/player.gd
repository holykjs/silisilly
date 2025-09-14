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

# track nearby players via TagArea signals
var nearby_players: Array = []

func _ready() -> void:
	if debug:
		print("[PLAYER] ready — peer_id:", peer_id, " is_local:", is_local)
	# connect TagArea signals (Godot 4 Callable syntax)
	if tag_area:
		if not tag_area.is_connected("body_entered", Callable(self, "_on_tag_area_body_entered")):
			tag_area.connect("body_entered", Callable(self, "_on_tag_area_body_entered"))
		if not tag_area.is_connected("body_exited", Callable(self, "_on_tag_area_body_exited")):
			tag_area.connect("body_exited", Callable(self, "_on_tag_area_body_exited"))

func is_network_player() -> bool:
	return true

# Visual hook called by GameManager (via rpc_set_tagger)
func set_sili(value: bool) -> void:
	is_sili = value
	if anim_sprite:
		# visual cue - a slight tint when you're the Sili
		anim_sprite.modulate = Color(1,0.7,0.7) if is_sili else Color(1,1,1)
	if debug:
		print("[PLAYER] set_sili:", name, is_sili)

func set_frozen(value: bool) -> void:
	frozen = value
	if anim_sprite:
		anim_sprite.modulate = Color(0.7,0.8,1.0) if frozen else (Color(1,0.7,0.7) if is_sili else Color(1,1,1))
	if frozen:
		# stop movement visually
		anim_sprite.stop()
	if debug:
		print("[PLAYER] set_frozen:", name, frozen)

func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	# basic physics (water-aware)
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

	# flip & simple animations (run/idle)
	if anim_sprite:
		if dir != 0:
			anim_sprite.flip_h = dir < 0
			_play_anim("run")
		else:
			_play_anim("idle")

	# jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = current_jump

	move_and_slide()

	# handle tag/rescue input only for local player
	if is_local:
		if Input.is_action_just_pressed("action_tag"):
			_attempt_tag()
		if Input.is_action_just_pressed("action_rescue"):
			_attempt_rescue()

func _play_anim(name: String) -> void:
	if anim_sprite.animation != name or not anim_sprite.is_playing():
		anim_sprite.play(name)

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

# ---------------- Tagging / Rescue attempts (client asks server) ----------------
func _attempt_tag() -> void:
	if frozen or not is_sili:
		if debug: print("[PLAYER] cannot tag (frozen or not sili)")
		return

	for p in nearby_players:
		if not p: continue
		if p == self: continue
		if p.has_method("is_network_player") and p.peer_id != peer_id:
			# ask the server to validate tag (server is usually peer id 1)
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

# ---------------- Water detection (counter for overlaps) ----------------
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

func set_skin(skin: Resource) -> void:
	# Primary path: SpriteFrames resource for AnimatedSprite2D
	if skin is SpriteFrames:
		anim_sprite.sprite_frames = skin
		# switch to a default animation if needed (e.g., "idle")
		if anim_sprite.has_animation("idle"):
			anim_sprite.animation = "idle"
			anim_sprite.play()
	# Fallback: if a single Texture2D is provided, create a simple one-frame SpriteFrames
	elif skin is Texture2D:
		var frames := SpriteFrames.new()
		# give it an "idle" animation with a single frame
		frames.add_animation("idle")
		frames.add_frame("idle", skin)
		anim_sprite.sprite_frames = frames
		anim_sprite.animation = "idle"
		anim_sprite.play()
	else:
		if debug:
			print("[PLAYER] set_skin: Unsupported resource type:", skin)
