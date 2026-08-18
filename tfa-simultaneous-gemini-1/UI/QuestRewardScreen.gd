## QuestRewardScreen
## The pick-one-of-N screen shown when a quest is turned in. Rewards are the
## game's progression, so this is the moment that has to feel like a choice: a
## row of guilloche-backed cards, one per offer, take one and the rest are gone.
##
## Three offer types (see data/Quests.json `rewards.offers`):
##   {"type": "item",     "item_id": "winters_grip"}
##   {"type": "money",    "amount": 150}
##   {"type": "training", "ability_id": "shield_bash", "base_days": 4,
##                        "teacher_title": "Guildmaster"}
##
## A training offer grants NOTHING here. It books time with a teacher, which the
## learner then has to actually spend — see TrainingManager.
##
## Instantiate from code (no .tscn, matching every other panel in UI/):
##     var screen = load("res://UI/QuestRewardScreen.gd").new()
##     screen.setup(quest_id, offers, character)
##     add_child(screen)
##     if not screen.try_open():        # nothing worth showing
##         screen.queue_free()
##     var offer: Dictionary = await screen.chosen
class_name QuestRewardScreen
extends CanvasLayer

## Emitted with the offer dict the player took. Never emitted if dismissed.
signal chosen(offer: Dictionary)
signal dismissed()

## Above every gameplay layer, same as CharacterCreationScreen.
const SCREEN_LAYER: int = 128
const MARGIN := Vector2(48, 48)
const CARD_SIZE := Vector2(260, 380)
const CARD_GAP: float = 24.0
const FONT_PATH: String = "res://Fonts/Cinzel-Regular.ttf"

# Ink shared with the carta d'identità so the two documents read as one hand.
const ENGRAVED := Color(0.365, 0.110, 0.180)
const TYPED := Color(0.176, 0.129, 0.098)
const TYPED_BODY := Color(0.176, 0.129, 0.098, 0.90)
const TYPED_DIM := Color(0.176, 0.129, 0.098, 0.62)
const RULE := Color(0.365, 0.110, 0.180, 0.40)

var quest_id: String = ""
var offers: Array = []
var character: Node = null

var _root: Control = null
var _row: Control = null
var _cards: Array = []
var _font: FontFile = null
var _typewriter: SystemFont = null
var _resolved: bool = false

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

func setup(p_quest_id: String, p_offers: Array, p_character: Node) -> void:
	quest_id = p_quest_id
	offers = _sanitise(p_offers)
	character = p_character

## Returns false when there is nothing worth showing, so the caller frees the
## node instead of putting an empty document on screen. Mirrors
## SurrenderPanel.try_open().
func try_open() -> bool:
	return not offers.is_empty()

func _ready() -> void:
	layer = SCREEN_LAYER
	# Turn-in usually happens mid-dialogue with the tree paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)

	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.05, 0.04, 0.03, 0.78)
	# STOP so a click that misses a card doesn't fall through to the world.
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	_build()
	get_viewport().size_changed.connect(_layout)
	_layout.call_deferred()

## Drop offers we cannot render or honour, so a typo in Quests.json costs one
## card rather than the whole screen.
func _sanitise(raw: Array) -> Array:
	var out: Array = []
	for offer in raw:
		if not (offer is Dictionary):
			continue
		match str(offer.get("type", "")):
			"item":
				if not str(offer.get("item_id", "")).is_empty():
					out.append(offer)
			"money":
				if int(offer.get("amount", 0)) != 0:
					out.append(offer)
			"training":
				if not str(offer.get("ability_id", "")).is_empty():
					out.append(offer)
			_:
				push_warning("QuestRewardScreen: unknown offer type %s" % str(offer.get("type", "")))
	return out

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

func _build() -> void:
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 18)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	_root.add_child(column)

	# The heading sits on the dim overlay, not on paper, so it takes the parchment
	# colour rather than the engraved plate ink — maroon on near-black is
	# unreadable, which is not obvious until you actually render it.
	var heading := _engraved("YOUR REWARD", 26, 5.0)
	heading.add_theme_color_override("font_color", Color(0.898, 0.839, 0.760, 0.95))
	column.add_child(heading)

	var sub := _typed("Take one.", 14, Color(0.898, 0.839, 0.760, 0.75))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(sub)

	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", int(CARD_GAP))
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(_row)

	for offer in offers:
		var card := _build_card(offer)
		_row.add_child(card)
		_cards.append(card)

func _build_card(offer: Dictionary) -> Control:
	var card := Control.new()
	card.custom_minimum_size = CARD_SIZE
	card.size = CARD_SIZE
	# Backstop for the overflow above: a long unwrapped string in any future
	# offer type gets cut at the card edge instead of sprawling across its
	# neighbour. The autowrap is the fix; this is the seatbelt.
	card.clip_contents = true

	var paper := GuillocheRect.new()
	paper.set_anchors_preset(Control.PRESET_FULL_RECT)
	# One rosette per card at the top, no sunburst — the sunburst is the carta's
	# signature and a row of them reads as noise.
	paper.show_sunburst = false
	# Centred behind the ICON, not the caption above it — at 0.18 the engine
	# turning ran straight through the "PURSE" / "GOODS" lettering.
	paper.rosette_center = Vector2(0.5, 0.26)
	paper.rosette_radius = 0.13
	# Vary the engine-turning per card so three cards don't look printed from one
	# plate. Deterministic in the offer, not random, so a re-layout is stable.
	paper.pattern_seed = 43454 + abs(hash(_offer_key(offer))) % 9973
	card.add_child(paper)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	# GuillocheRect's border band occupies roughly the first 20px of the card, so
	# a 20px margin lands the prose flush against the engraved frame with no
	# gutter at all. 30 clears the band and gives the text somewhere to sit.
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 30)
	card.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	box.add_child(_engraved(_kind_caption(offer), 10, 2.5, 0.75))

	var icon := _build_icon(offer)
	if icon != null:
		box.add_child(icon)

	# NO letterspacing on the title. _letterspace injects a real space between
	# every character, and WORD_SMART then treats each of those as a legal break
	# — "Potion of Healing" came out as "Potion of Heal / ing". The short
	# non-wrapping captions above can afford the tracking; a title that has to
	# wrap cannot.
	var title := _engraved(_offer_title(offer), 17, 0.0)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	box.add_child(_build_rule(1.0))

	var body := _typed(_offer_body(offer), 12, TYPED_BODY)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(body)

	var note := _offer_note(offer)
	if not note.is_empty():
		var note_label := _typed(note, 11, TYPED_DIM)
		# MUST autowrap. A Label without it reports its full single-line text
		# width as a minimum, which drags the whole VBox — and therefore the
		# title, icon and button — wider than the card and out past its frame.
		note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(note_label)

	box.add_child(_small_button("TAKE", _on_take.bind(offer), true))
	return card

## The icon strip. Deliberately a plain TextureRect with an explicit minimum
## size and EXPAND_IGNORE_SIZE: a proportional expand mode next to an expanding
## sibling is the Godot 4.6 layout crash documented at QuestLogPanel.gd:200-205.
func _build_icon(offer: Dictionary) -> Control:
	var path := _offer_icon_path(offer)
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var tex := TextureRect.new()
	tex.texture = load(path)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(0, 84)
	return tex

# ---------------------------------------------------------------------------
# Offer presentation
# ---------------------------------------------------------------------------

func _offer_key(offer: Dictionary) -> String:
	return "%s:%s:%s" % [str(offer.get("type", "")), str(offer.get("item_id", "")),
		str(offer.get("ability_id", str(offer.get("amount", ""))))]

func _kind_caption(offer: Dictionary) -> String:
	match str(offer.get("type", "")):
		"item":     return "GOODS"
		"money":    return "PURSE"
		"training": return "INSTRUCTION"
	return "REWARD"

func _offer_title(offer: Dictionary) -> String:
	match str(offer.get("type", "")):
		"item":
			var data: Dictionary = ItemDatabase.get_item_data(str(offer.get("item_id", "")))
			return str(data.get("display_name", offer.get("item_id", "")))
		"money":
			return "%d Coin" % int(offer.get("amount", 0))
		"training":
			var ability: Dictionary = AbilityDatabase.get_ability_data(str(offer.get("ability_id", "")))
			return str(ability.get("display_name", offer.get("ability_id", "")))
	return "Reward"

func _offer_body(offer: Dictionary) -> String:
	match str(offer.get("type", "")):
		"item":
			var data: Dictionary = ItemDatabase.get_item_data(str(offer.get("item_id", "")))
			return str(data.get("description", ""))
		"money":
			return "Paid out on the spot."
		"training":
			var ability: Dictionary = AbilityDatabase.get_ability_data(str(offer.get("ability_id", "")))
			return str(ability.get("description", ""))
	return ""

## The line that says a training offer is not a thing you walk away with.
func _offer_note(offer: Dictionary) -> String:
	if str(offer.get("type", "")) != "training":
		return ""
	var teacher: String = str(offer.get("teacher_title", "")).strip_edges()
	var days: int = max(1, int(offer.get("base_days", 3)))
	var who: String = teacher if not teacher.is_empty() else "your teacher"
	return "Roughly %d days' study with %s. You must stay and do the work." % [days, who]

func _offer_icon_path(offer: Dictionary) -> String:
	match str(offer.get("type", "")):
		"item":
			var data: Dictionary = ItemDatabase.get_item_data(str(offer.get("item_id", "")))
			return str(data.get("sprite_path", ""))
		"training":
			var ability: Dictionary = AbilityDatabase.get_ability_data(str(offer.get("ability_id", "")))
			return str(ability.get("icon", ""))
		"money":
			var gold: Dictionary = ItemDatabase.get_item_data("gold")
			return str(gold.get("sprite_path", ""))
	return ""

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func _on_take(offer: Dictionary) -> void:
	# Guard the double-click: the tween below leaves the buttons live for a beat.
	if _resolved:
		return
	_resolved = true
	chosen.emit(offer)

func _unhandled_key_input(event: InputEvent) -> void:
	# Escape declines the whole thing. The quest is already complete either way —
	# turn_in() ran before this screen opened — so this forfeits the reward
	# rather than rolling anything back.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if not _resolved:
			_resolved = true
			dismissed.emit()

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

## Centre the row and shrink it to fit rather than letting cards run off a small
## window. Scale rather than a container so the engraving stays proportional,
## matching CharacterCreationScreen._layout_card.
func _layout() -> void:
	var column := _root.get_node_or_null("Column") as Control
	if column == null:
		return
	var view: Vector2 = Vector2(get_viewport().get_visible_rect().size)
	var count: int = maxi(1, _cards.size())
	var wanted := Vector2(
		CARD_SIZE.x * count + CARD_GAP * (count - 1),
		CARD_SIZE.y + 110.0)
	column.size = wanted
	var scale_factor: float = minf(1.0, minf(
			(view.x - MARGIN.x) / wanted.x,
			(view.y - MARGIN.y) / wanted.y))
	scale_factor = maxf(scale_factor, 0.2)
	column.scale = Vector2(scale_factor, scale_factor)
	column.position = ((view - wanted * scale_factor) * 0.5).floor()

# ---------------------------------------------------------------------------
# Type builders — deliberate twins of CartaIdentita's, kept local because those
# are private methods on that Control. Same palette, same faces.
# ---------------------------------------------------------------------------

func _engraved(text: String, font_size: int, spacing: float = 0.0,
		alpha: float = 1.0) -> Label:
	var label := Label.new()
	label.text = _letterspace(text, spacing)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color",
			Color(ENGRAVED.r, ENGRAVED.g, ENGRAVED.b, alpha))
	if _font:
		label.add_theme_font_override("font", _font)
	return label

## Cinzel is an all-caps display face and it is also ThemeDB.fallback_font here,
## so prose left on the default comes out engraved and barely readable.
func _typewriter_font() -> SystemFont:
	if _typewriter == null:
		_typewriter = SystemFont.new()
		_typewriter.font_names = PackedStringArray([
			"Courier New", "Consolas", "Liberation Mono", "DejaVu Sans Mono",
			"Menlo", "monospace"])
	return _typewriter

func _typed(text: String, font_size: int, color: Color = TYPED) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", _typewriter_font())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _letterspace(text: String, spacing: float) -> String:
	if spacing <= 0.0 or text.is_empty():
		return text
	var gap: String = " ".repeat(maxi(1, int(round(spacing / 3.0))))
	var out: PackedStringArray = []
	for line in text.split("\n"):
		var chars: PackedStringArray = []
		for i in range(line.length()):
			chars.append(line[i])
		out.append(gap.join(chars))
	return "\n".join(out)

func _build_rule(width: float) -> Control:
	var rule := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.draw_center = false
	style.border_width_bottom = int(maxf(1.0, width))
	style.border_color = Color(ENGRAVED.r, ENGRAVED.g, ENGRAVED.b, 0.5)
	rule.add_theme_stylebox_override("panel", style)
	rule.custom_minimum_size.y = 6
	return rule

func _small_button(text: String, handler: Callable, emphatic: bool = false) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.add_theme_font_size_override("font_size", 13 if not emphatic else 15)
	if _font:
		btn.add_theme_font_override("font", _font)
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.898, 0.839, 0.760, 0.85 if state != "hover" else 1.0)
		if state == "pressed":
			style.bg_color = Color(0.800, 0.722, 0.639, 1.0)
		style.set_border_width_all(1 if not emphatic else 2)
		style.border_color = ENGRAVED
		style.set_corner_radius_all(2)
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 4
		style.content_margin_bottom = 4
		btn.add_theme_stylebox_override(state, style)
	btn.add_theme_color_override("font_color", ENGRAVED)
	btn.add_theme_color_override("font_hover_color", TYPED)
	btn.add_theme_color_override("font_pressed_color", TYPED)
	btn.pressed.connect(handler)
	return btn
