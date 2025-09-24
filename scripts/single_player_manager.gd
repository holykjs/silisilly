extends Node

# Single-player game settings
var is_single_player: bool = false
var ai_count: int = 4
var ai_difficulty: String = "Normal"

# AI behavior settings based on difficulty
var ai_settings = {
	"Easy": {
		"reaction_time": 2.0,
		"movement_speed_multiplier": 0.7,
		"tag_accuracy": 0.6,
		"rescue_priority": 0.4
	},
	"Normal": {
		"reaction_time": 1.2,
		"movement_speed_multiplier": 0.9,
		"tag_accuracy": 0.8,
		"rescue_priority": 0.7
	},
	"Hard": {
		"reaction_time": 0.8,
		"movement_speed_multiplier": 1.1,
		"tag_accuracy": 0.95,
		"rescue_priority": 0.9
	}
}

func setup_game(ai_player_count: int, difficulty: String):
	"""Setup single-player game with AI settings"""
	is_single_player = true
	ai_count = ai_player_count
	ai_difficulty = difficulty
	
	print("[SP Manager] Single-player game setup - AI Count:", ai_count, "Difficulty:", ai_difficulty)

func get_ai_settings() -> Dictionary:
	"""Get current AI behavior settings"""
	return ai_settings.get(ai_difficulty, ai_settings["Normal"])

func reset():
	"""Reset to multiplayer mode"""
	is_single_player = false
	ai_count = 3
	ai_difficulty = "Normal"
