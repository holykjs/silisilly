extends Node2D

@export var map_width: float = 1154.0
@export var map_height: float = 595.0
@export var wall_thickness: float = 20.0
@export var debug_visible: bool = false

@onready var left_wall: StaticBody2D = $LeftWall
@onready var right_wall: StaticBody2D = $RightWall
@onready var top_wall: StaticBody2D = $TopWall
@onready var bottom_wall: StaticBody2D = $BottomWall

func _ready():
	setup_boundaries()
	if debug_visible:
		make_walls_visible()

func setup_boundaries():
	"""Setup collision boundaries based on map dimensions"""
	var half_width = map_width / 2.0
	var half_height = map_height / 2.0
	
	# Left wall
	left_wall.position = Vector2(-wall_thickness / 2.0, half_height)
	var left_shape = left_wall.get_node("CollisionShape2D").shape as RectangleShape2D
	left_shape.size = Vector2(wall_thickness, map_height + wall_thickness * 2)
	
	# Right wall
	right_wall.position = Vector2(map_width + wall_thickness / 2.0, half_height)
	var right_shape = right_wall.get_node("CollisionShape2D").shape as RectangleShape2D
	right_shape.size = Vector2(wall_thickness, map_height + wall_thickness * 2)
	
	# Top wall
	top_wall.position = Vector2(half_width, -wall_thickness / 2.0)
	var top_shape = top_wall.get_node("CollisionShape2D").shape as RectangleShape2D
	top_shape.size = Vector2(map_width + wall_thickness * 2, wall_thickness)
	
	# Bottom wall
	bottom_wall.position = Vector2(half_width, map_height + wall_thickness / 2.0)
	var bottom_shape = bottom_wall.get_node("CollisionShape2D").shape as RectangleShape2D
	bottom_shape.size = Vector2(map_width + wall_thickness * 2, wall_thickness)
	
	print("[MapBoundaries] Setup boundaries for map size: ", map_width, "x", map_height)

func make_walls_visible():
	"""Make walls visible for debugging purposes"""
	for wall in [left_wall, right_wall, top_wall, bottom_wall]:
		var color_rect = ColorRect.new()
		color_rect.color = Color.RED
		color_rect.color.a = 0.3  # Semi-transparent
		var collision_shape = wall.get_node("CollisionShape2D")
		var shape = collision_shape.shape as RectangleShape2D
		color_rect.size = shape.size
		color_rect.position = -shape.size / 2.0
		wall.add_child(color_rect)

func set_map_dimensions(width: float, height: float):
	"""Dynamically set map dimensions"""
	map_width = width
	map_height = height
	if is_inside_tree():
		setup_boundaries()
