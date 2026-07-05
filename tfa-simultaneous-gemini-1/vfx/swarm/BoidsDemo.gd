extends Node2D
# Standalone playground for the BoidField system. Run this scene directly
# (Run Current Scene), or temporarily set it as the main scene.
#
#   Left-click  : send every swarm toward the cursor
#   Right-click : scatter every swarm away from the cursor
#   1/2/3/4/5   : spawn arcane / fire / wisps / insects / rats at the cursor
#   Space       : clear all swarms

var _swarms: Array[BoidField] = []
var _label: Label

func _ready() -> void:
	# Dark backdrop so additive motes read well and rats stay visible.
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.08, 0.10)
	bg.size = Vector2(4000, 4000)
	bg.position = Vector2(-2000, -2000)
	bg.z_index = -100
	add_child(bg)

	var cam := Camera2D.new()
	cam.position = Vector2(950, 540)
	add_child(cam)
	cam.make_current()

	# UI on its own layer so swarm z-indices never cover it.
	var ui := CanvasLayer.new()
	add_child(ui)
	_label = Label.new()
	_label.position = Vector2(20, 18)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	ui.add_child(_label)

	# Open with a creature swarm and a spell swirl side by side.
	_spawn("rat_swarm", Vector2(700, 540))
	_spawn("arcane_motes", Vector2(1200, 540))

func _spawn(preset: String, pos: Vector2) -> void:
	_swarms.append(BoidField.spawn(self, preset, pos))
	_update_label()

func _unhandled_input(event: InputEvent) -> void:
	var m := get_global_mouse_position()
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			for f in _swarms:
				if is_instance_valid(f):
					f.set_target(m)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			for f in _swarms:
				if is_instance_valid(f):
					f.scatter(m, 1.4)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: _spawn("arcane_motes", m)
			KEY_2: _spawn("fire_swarm", m)
			KEY_3: _spawn("spirit_wisps", m)
			KEY_4: _spawn("insect_swarm", m)
			KEY_5: _spawn("rat_swarm", m)
			KEY_SPACE: _clear()

func _clear() -> void:
	for f in _swarms:
		if is_instance_valid(f):
			f.despawn(0.3)
	_swarms.clear()
	_update_label()

func _update_label() -> void:
	if _label:
		_label.text = "BoidField demo  -  swarms: %d\nLeft-click: gather to cursor    Right-click: scatter\n1 arcane   2 fire   3 wisps   4 insects   5 rats  (at cursor)    Space: clear" % _swarms.size()
