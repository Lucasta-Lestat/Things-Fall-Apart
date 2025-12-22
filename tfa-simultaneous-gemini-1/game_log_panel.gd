# =====================
# game_log_panel.gd - Attach to LogPanel node
# =====================

extends PanelContainer

@onready var scroll_container: ScrollContainer = $MarginContainer/ScrollContainer
@onready var log_content: VBoxContainer = $MarginContainer/ScrollContainer/LogContent

var auto_scroll: bool = true
const MAX_VISIBLE_ENTRIES: int = 50

func _ready():
	GameLog.entry_added.connect(_on_entry_added)
	
	# Create parchment-style panel
	var style = StyleBoxTexture.new()
	# Load your parchment texture
	style.texture = preload("res://UI/paper texture.png")
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	# Position in bottom right
	anchor_left = 1.0
	anchor_top = 1.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	
	# Set size
	custom_minimum_size = Vector2(400, 250)
	
	# Offset from bottom right corner (negative values move left/up)
	offset_left = -420
	offset_top = -270
	offset_right = 0
	offset_bottom = -20
	add_theme_stylebox_override("panel", style)
	
	# Configure scroll container
	scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll_container.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO

	# Load existing entries
	for entry in GameLog.get_entries():
		_add_log_label(entry.text, entry.game_time)

func _on_entry_added(text: String, timestamp: String):
	_add_log_label(text, timestamp)
	
	# Auto-scroll to bottom
	if auto_scroll:
		await get_tree().process_frame
		scroll_container.scroll_vertical = scroll_container.get_v_scroll_bar().max_value

func _add_log_label(text: String, timestamp: String):
	var label = RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.custom_minimum_size.x = scroll_container.size.x - 20
	
	# Format: [timestamp] message
	label.text = "[color=gray][" + timestamp + "][/color] " + text
	
	log_content.add_child(label)
	
	# Remove old entries if too many
	while log_content.get_child_count() > MAX_VISIBLE_ENTRIES:
		var old_child = log_content.get_child(0)
		log_content.remove_child(old_child)
		old_child.queue_free()
	
	
