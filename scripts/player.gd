extends CharacterBody2D

@export var speed: float = 240.0
@export var jump_force: float = -400.0
@export var gravity: float = 1400.0

@export var is_local: bool = false
@export var debug: bool = true

var peer_id: int = -1
var frozen: bool = false

@onready var sprite: Sprite2D = $Sprite
@onready var tag_area: Area2D = $TagArea

func _ready() -> void:
	if debug:
		print("[PLAYER] ready — is_local:", is_local, "peer_id:", peer_id)
		print("[PLAYER] Input actions:", InputMap.get_actions())

func is_network_player() -> bool:
	return true

func set_frozen(value: bool) -> void:
	frozen = value
	sprite.modulate = Color(1,1,1) if not frozen else Color(0.6,0.6,1)
	if debug:
		print("[PLAYER] frozen set to", frozen)

func _physics_process(delta: float) -> void:
	if frozen:
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if is_local:
		# Gravity
		if not is_on_floor():
			velocity.y += gravity * delta
		else:
			velocity.y = 0

		# Horizontal movement
		var dir := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
		velocity.x = dir * speed

		# Flip sprite
		if dir != 0:
			sprite.flip_h = dir < 0

		# Jump
		if Input.is_action_just_pressed("jump") and is_on_floor():
			velocity.y = jump_force

		# Debug
		if debug:
			print("[PLAYER] dir:", dir, "vel:", velocity, "on_floor:", is_on_floor())

		# Apply movement
		move_and_slide()
