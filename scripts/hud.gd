extends CanvasLayer

@onready var tagger_label := $HBoxContainer/TaggerLabel
@onready var status_label := $HBoxContainer/StatusLabel

func set_tagger(peer_id:int):
	tagger_label.text = "Tagger: %s" % str(peer_id)

func set_status(text:String):
	status_label.text = text
