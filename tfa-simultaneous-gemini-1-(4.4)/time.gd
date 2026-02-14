extends Label

@export var show_seconds: bool = true
@export var use_12_hour_format: bool = false
@export var show_date: bool = true

func _ready():
	TimeManager.connect("time_updated", _on_time_updated)
	TimeManager.connect("date_changed", _on_date_changed)
	# Position in bottom Left
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 0.0
	anchor_bottom = 1.0
	offset_bottom = -300
	update_display()

func _on_time_updated(hour, minute, second):
	update_display()

func _on_date_changed(day, month, year):
	update_display()

func update_display():
	var time_str = TimeManager.get_time_string(use_12_hour_format)
	var date_str = TimeManager.get_date_string()
	
	if show_date:
		self.text = "%s\n%s" % [date_str, time_str]
	else:
		self.text = time_str
