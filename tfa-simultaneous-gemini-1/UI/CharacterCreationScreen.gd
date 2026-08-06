## CharacterCreationScreen
## Full-screen host for the carta d'identità. Two jobs: dim the world behind the
## document, and keep the card centred and legible at any window size.
##
## Mode.CREATE — the new-game gate. Game._ready() awaits `completed` before the
##               first map load, so the world never exists without a protagonist.
## Mode.VIEW   — the character sheet. Escape or CHIUDI emits `dismissed`.
##
## Instantiate from code (no .tscn):
##     var screen = load("res://UI/CharacterCreationScreen.gd").new()
##     screen.mode = CartaIdentita.Mode.VIEW
##     screen.subject = some_character          # VIEW only
##     add_child(screen)
class_name CharacterCreationScreen
extends CanvasLayer

signal completed(draft: Dictionary)
signal dismissed()

## Above every gameplay layer, below nothing.
const SCREEN_LAYER: int = 128
## Breathing room kept around the card when the window is too small for it.
const MARGIN := Vector2(48, 48)

@export var mode: int = CartaIdentita.Mode.CREATE
## VIEW mode only: the character whose document this is.
var subject: Node = null
## CREATE mode only: skip the opening roll and start from this draft.
var initial_draft: Dictionary = {}

var _carta: CartaIdentita = null
var _root: Control = null

func _ready() -> void:
	layer = SCREEN_LAYER
	# The creation gate runs before the map exists and the sheet may be opened
	# while the game is paused; either way the document has to keep working.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.05, 0.04, 0.03, 0.78)
	# STOP so a click that misses the card doesn't fall through to the world.
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	_carta = CartaIdentita.new()
	_carta.setup(_resolve_draft(), mode)
	_carta.confirmed.connect(_on_confirmed)
	_carta.closed.connect(_on_closed)
	_root.add_child(_carta)

	get_viewport().size_changed.connect(_layout_card)
	_layout_card.call_deferred()

func _resolve_draft() -> Dictionary:
	if mode == CartaIdentita.Mode.VIEW and subject != null and is_instance_valid(subject):
		return _carta.draft_from_character(subject)
	if not initial_draft.is_empty():
		return initial_draft
	return CharacterCreationDatabase.roll_draft()

## Centre the card, shrinking it to fit rather than letting it run off a small
## window. Scale (not a container) so the engraving stays proportional.
func _layout_card() -> void:
	if _carta == null or not is_instance_valid(_carta):
		return
	var view: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var card: Vector2 = CartaIdentita.CARD_SIZE
	_carta.size = card
	var scale_factor: float = minf(1.0, minf(
			(view.x - MARGIN.x) / card.x,
			(view.y - MARGIN.y) / card.y))
	scale_factor = maxf(scale_factor, 0.2)
	_carta.scale = Vector2(scale_factor, scale_factor)
	_carta.position = ((view - card * scale_factor) * 0.5).floor()

func _unhandled_key_input(event: InputEvent) -> void:
	if mode != CartaIdentita.Mode.VIEW:
		return
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_on_closed()

func _on_confirmed(draft: Dictionary) -> void:
	completed.emit(draft)

func _on_closed() -> void:
	dismissed.emit()
