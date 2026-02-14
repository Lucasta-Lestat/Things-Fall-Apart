extends Control
## Main UI controller for the procedural grass generator

@onready var terrain_generator: GrassTerrainGenerator = $SubViewportContainer/SubViewport/TerrainGenerator
@onready var viewport_container: SubViewportContainer = $SubViewportContainer
@onready var viewport: SubViewport = $SubViewportContainer/SubViewport
@onready var camera: Camera2D = $SubViewportContainer/SubViewport/Camera2D

# UI Elements
@onready var seed_spinbox: SpinBox = $UIPanel/VBoxContainer/SeedContainer/SeedSpinBox
@onready var generate_button: Button = $UIPanel/VBoxContainer/GenerateButton
@onready var terrain_options: OptionButton = $UIPanel/VBoxContainer/TerrainContainer/TerrainOption
@onready var brush_slider: HSlider = $UIPanel/VBoxContainer/BrushContainer/BrushSlider
@onready var brush_label: Label = $UIPanel/VBoxContainer/BrushContainer/BrushLabel

# Noise settings
@onready var flower_threshold_slider: HSlider = $UIPanel/VBoxContainer/FlowerContainer/FlowerSlider
@onready var flower_label: Label = $UIPanel/VBoxContainer/FlowerContainer/FlowerLabel
@onready var edge_slider: HSlider = $UIPanel/VBoxContainer/EdgeContainer/EdgeSlider
@onready var edge_label: Label = $UIPanel/VBoxContainer/EdgeContainer/EdgeLabel

# File dialogs
@onready var save_dialog: FileDialog = $SaveDialog
@onready var load_dialog: FileDialog = $LoadDialog

# State
var is_painting: bool = false
var current_terrain: GrassTerrainGenerator.TerrainType = GrassTerrainGenerator.TerrainType.PATH
var camera_drag: bool = false
var drag_start: Vector2

# Zoom settings
var zoom_level: float = 1.0
var min_zoom: float = 0.25
var max_zoom: float = 4.0
var zoom_step: float = 0.1

func _ready():
	_setup_ui()
	_connect_signals()
	
	# Initial generation
	await get_tree().process_frame
	_on_generate_pressed()

func _setup_ui():
	# Populate terrain options
	terrain_options.add_item("Path", GrassTerrainGenerator.TerrainType.PATH)
	terrain_options.add_item("Rock", GrassTerrainGenerator.TerrainType.ROCK)
	terrain_options.add_item("Water", GrassTerrainGenerator.TerrainType.WATER)
	terrain_options.add_item("Grass (Erase)", GrassTerrainGenerator.TerrainType.GRASS)
	
	# Set initial values
	seed_spinbox.value = terrain_generator.noise_seed
	brush_slider.value = terrain_generator.brush_size
	_update_brush_label()
	
	flower_threshold_slider.value = terrain_generator.flower_threshold
	_update_flower_label()
	
	edge_slider.value = terrain_generator.edge_raggedness
	_update_edge_label()
	
	# Setup file dialogs
	save_dialog.filters = ["*.grassmap ; Grass Map Files"]
	load_dialog.filters = ["*.grassmap ; Grass Map Files"]

func _connect_signals():
	generate_button.pressed.connect(_on_generate_pressed)
	terrain_options.item_selected.connect(_on_terrain_selected)
	brush_slider.value_changed.connect(_on_brush_changed)
	flower_threshold_slider.value_changed.connect(_on_flower_threshold_changed)
	edge_slider.value_changed.connect(_on_edge_changed)
	seed_spinbox.value_changed.connect(_on_seed_changed)
	
	save_dialog.file_selected.connect(_on_save_file_selected)
	load_dialog.file_selected.connect(_on_load_file_selected)
	
	terrain_generator.generation_complete.connect(_on_generation_complete)

func _input(event: InputEvent):
	# Handle viewport interactions
	if viewport_container.get_global_rect().has_point(get_global_mouse_position()):
		if event is InputEventMouseButton:
			_handle_mouse_button(event)
		elif event is InputEventMouseMotion:
			_handle_mouse_motion(event)

func _handle_mouse_button(event: InputEventMouseButton):
	match event.button_index:
		MOUSE_BUTTON_LEFT:
			is_painting = event.pressed
			if is_painting:
				_paint_at_mouse()
		MOUSE_BUTTON_RIGHT:
			# Right click to erase (paint grass)
			if event.pressed:
				is_painting = true
				var old_terrain = current_terrain
				current_terrain = GrassTerrainGenerator.TerrainType.GRASS
				_paint_at_mouse()
				current_terrain = old_terrain
			else:
				is_painting = false
		MOUSE_BUTTON_MIDDLE:
			camera_drag = event.pressed
			if camera_drag:
				drag_start = get_global_mouse_position()
		MOUSE_BUTTON_WHEEL_UP:
			_zoom(zoom_step)
		MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(-zoom_step)

func _handle_mouse_motion(event: InputEventMouseMotion):
	if is_painting:
		_paint_at_mouse()
	elif camera_drag:
		var delta = get_global_mouse_position() - drag_start
		camera.position -= delta / zoom_level
		drag_start = get_global_mouse_position()

func _paint_at_mouse():
	var mouse_pos = viewport.get_mouse_position()
	var world_pos = camera.position + (mouse_pos - Vector2(viewport.size) / 2) / zoom_level
	terrain_generator.paint_at(world_pos, current_terrain)

func _zoom(delta: float):
	zoom_level = clamp(zoom_level + delta, min_zoom, max_zoom)
	camera.zoom = Vector2(zoom_level, zoom_level)

func _on_generate_pressed():
	generate_button.disabled = true
	generate_button.text = "Generating..."
	
	# Use async generation for smoother UI
	await terrain_generator.generate_terrain_async(64)

func _on_generation_complete():
	generate_button.disabled = false
	generate_button.text = "Regenerate"

func _on_terrain_selected(index: int):
	current_terrain = terrain_options.get_item_id(index) as GrassTerrainGenerator.TerrainType

func _on_brush_changed(value: float):
	terrain_generator.brush_size = int(value)
	_update_brush_label()

func _update_brush_label():
	brush_label.text = "Brush: %d" % terrain_generator.brush_size

func _on_flower_threshold_changed(value: float):
	terrain_generator.flower_threshold = value
	_update_flower_label()

func _update_flower_label():
	flower_label.text = "Flowers: %.2f" % terrain_generator.flower_threshold

func _on_edge_changed(value: float):
	terrain_generator.edge_raggedness = value
	_update_edge_label()

func _update_edge_label():
	edge_label.text = "Edge: %.1f" % terrain_generator.edge_raggedness

func _on_seed_changed(value: float):
	terrain_generator.set_noise_seed(int(value))

# File operations
func _on_save_pressed():
	save_dialog.popup_centered()

func _on_load_pressed():
	load_dialog.popup_centered()

func _on_save_file_selected(path: String):
	terrain_generator.save_map(path)

func _on_load_file_selected(path: String):
	if terrain_generator.load_map(path):
		# Update UI to reflect loaded settings
		seed_spinbox.value = terrain_generator.noise_seed
		flower_threshold_slider.value = terrain_generator.flower_threshold
		edge_slider.value = terrain_generator.edge_raggedness
		# Regenerate with loaded settings
		_on_generate_pressed()

func _on_clear_pressed():
	terrain_generator.clear_terrain()
	_on_generate_pressed()

func _on_export_pressed():
	var path = "user://grass_map_export.png"
	terrain_generator.export_image(path)
	print("Exported to: ", ProjectSettings.globalize_path(path))
