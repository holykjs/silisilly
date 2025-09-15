extends Node

func _ready() -> void:
	# Load your PNG cursor
	var cursor = load("res://assets/gui/cursorSword_bronze.png")
	# Replace default arrow everywhere
	Input.set_custom_mouse_cursor(cursor, Input.CURSOR_ARROW, Vector2(16, 16))
