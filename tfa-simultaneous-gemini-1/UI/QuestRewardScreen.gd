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
## learner then has to actually spend - see TrainingManager.
##
## LAYOUT NOTES, every one of them learned by rendering the thing rather than by
## reading it (tests/reward_screen_preview.tscn shoots this screen windowed):
##
##  - Prose sits on its own flat parchment PLATE. GuillocheRect's wave field is
##    drawn at 0.17 alpha directly under whatever you put on top of it, and
##    small type over that pattern swims.
##  - The icon gets a deliberate MEDALLION and GuillocheRect's own rosette is
##    switched off. The rosette was a fixed size, so a large round icon (Heal, a
##    coin) covered most of it and left a ragged crescent poking out behind.
##  - A Label with no `autowrap_mode` reports its full single-line width as a
##    MINIMUM and drags the whole VBox out past the card edge.
##  - Never combine `_letterspace` with AUTOWRAP_WORD_SMART: the letterspacing
##    injects real spaces between characters and the wrap then breaks words
##    mid-way ("Potion of Heal / ing").
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
const CARD_SIZE := Vector2(320, 524)
const CARD_GAP: float = 26.0
const FONT_PATH: String = "res://Fonts/Cinzel-Regular.ttf"

## Diameter of the disc behind the icon, and the icon's box inside it. The gap
## between the two is the ring of paper that makes it read as a medallion rather
## than as a circle the art failed to cover.
const MEDALLION_SIZE: float = 118.0
const ICON_SIZE: float = 78.0

# Ink shared with the carta d'identita so the two documents read as one hand.
const ENGRAVED := Color(0.365, 0.110, 0.180)
const TYPED := Color(0.176, 0.129, 0.098)
const TYPED_DIM := Color(0.176, 0.129, 0.098, 0.75)
const RULE := Color(0.365, 0.110, 0.180, 0.40)
## Flat paper for the plates that carry text, a shade lighter than
## GuillocheRect's own paper so the wave field reads as sitting behind them.
const PLATE := Color(0.965, 0.933, 0.878, 0.94)
const PLATE_SUNK := Color(0.878, 0.816, 0.729, 0.80)

var quest_id: String = ""
var offers: Array = []
var character: Node = null

var _root: Control = null
var _row: Control = null
var _cards: Array = []
var _font: FontFile = null
var _body_font: SystemFont = null
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
	# STOP so a click that misses a card does not fall through to the world.
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
	column.add_theme_constant_override("separation", 22)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	_root.add_child(column)

	# The heading sits on the dim overlay, not on paper, so it takes the
	# parchment colour rather than the engraved plate ink. Maroon on near-black
	# is unreadable, which is not obvious until you actually render it.
	var heading := _engraved("YOUR REWARD", 30, 5.0)
	heading.add_theme_color_override("font_color", Color(0.918, 0.867, 0.796, 0.96))
	column.add_child(heading)

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
	# Backstop: a long unwrapped string in a future offer type gets cut at the
	# card edge instead of sprawling across its neighbour.
	card.clip_contents = true

	var paper := GuillocheRect.new()
	paper.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Both of GuillocheRect's centrepieces are off. They are sized for the carta
	# d'identita's portrait, and behind a reward icon the rosette showed as a
	# ragged ring peeking out from under whatever art happened to sit on it.
	paper.show_sunburst = false
	paper.show_rosette = false
	# Vary the engine-turning per card so a row does not look printed from one
	# plate. Deterministic in the offer, not random, so a relayout is stable.
	paper.pattern_seed = 43454 + abs(hash(_offer_key(offer))) % 9973
	card.add_child(paper)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	# GuillocheRect's border band occupies roughly the first 20px of the card, so
	# a 20px margin lands content flush against the engraved frame.
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 30)
	card.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	box.add_child(_build_medallion(offer))

	# NO letterspacing on the title. See the header note about autowrap.
	var title := _engraved(_offer_title(offer), 21, 0.0)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(title)

	box.add_child(_build_rule(1.0))

	# The one number that decides whether you take this card, stamped rather
	# than buried in a sentence.
	var figure: Dictionary = _offer_figure(offer)
	if not figure.is_empty():
		box.add_child(_build_figure_plaque(str(figure["value"]), str(figure["unit"])))

	var body := _offer_body(offer)
	var footnote := _offer_footnote(offer)
	if not body.strip_edges().is_empty() or not footnote.strip_edges().is_empty():
		box.add_child(_build_text_plate(body, footnote))

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	var take := _small_button("TAKE", _on_take.bind(offer), true)
	# Taking plays the reward's own sound (_on_take), not the click.
	take.set_meta("sfx_silent", true)
	box.add_child(take)
	return card

## The icon on its disc. A PanelContainer with a full corner radius IS a circle
## and costs nothing extra; the inner margin guarantees a ring of paper all the
## way round whatever shape the art turns out to be.
func _build_medallion(offer: Dictionary) -> Control:
	var centre := CenterContainer.new()

	var disc := PanelContainer.new()
	disc.custom_minimum_size = Vector2(MEDALLION_SIZE, MEDALLION_SIZE)
	var style := StyleBoxFlat.new()
	style.bg_color = PLATE_SUNK
	style.set_corner_radius_all(int(MEDALLION_SIZE * 0.5))
	style.set_border_width_all(1)
	style.border_color = RULE
	disc.add_theme_stylebox_override("panel", style)
	centre.add_child(disc)

	var pad := MarginContainer.new()
	var inset: int = int((MEDALLION_SIZE - ICON_SIZE) * 0.5)
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, inset)
	disc.add_child(pad)

	var path := _offer_icon_path(offer)
	if path.is_empty() or not ResourceLoader.exists(path):
		return centre
	var tex := TextureRect.new()
	tex.texture = load(path)
	# EXPAND_IGNORE_SIZE plus an explicit minimum: a proportional expand mode
	# beside an expanding sibling is the Godot 4.6 layout crash documented at
	# UI/QuestLogPanel.gd:200-205.
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.custom_minimum_size = Vector2(ICON_SIZE, ICON_SIZE)
	pad.add_child(tex)
	return centre

## Big numeral, small unit beneath, on a sunken plate. Reads at a glance from
## across the row, which the same fact in a sentence does not.
func _build_figure_plaque(value: String, unit: String) -> Control:
	var plaque := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PLATE_SUNK
	style.set_corner_radius_all(2)
	style.set_border_width_all(1)
	style.border_color = RULE
	style.content_margin_top = 4
	style.content_margin_bottom = 6
	style.content_margin_left = 8
	style.content_margin_right = 8
	plaque.add_theme_stylebox_override("panel", style)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 0)
	plaque.add_child(stack)

	stack.add_child(_engraved(value, 34, 0.0))
	stack.add_child(_engraved(unit, 11, 2.5, 0.80))
	return plaque

## Prose on flat paper. The plate IS the readability fix: the wave field beneath
## is drawn at 0.17 alpha and small type sitting directly on it swims.
func _build_text_plate(body: String, footnote: String) -> Control:
	var plate := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PLATE
	style.set_corner_radius_all(2)
	style.content_margin_left = 10
	style.content_margin_right = 10
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	plate.add_theme_stylebox_override("panel", style)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 6)
	plate.add_child(stack)

	if not body.strip_edges().is_empty():
		var body_label := _typed(body, 15, TYPED)
		body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		stack.add_child(body_label)

	if not footnote.strip_edges().is_empty():
		var foot := _typed(footnote, 13, TYPED_DIM)
		foot.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		stack.add_child(foot)
	return plate

# ---------------------------------------------------------------------------
# Offer presentation
# ---------------------------------------------------------------------------

func _offer_key(offer: Dictionary) -> String:
	return "%s:%s:%s" % [str(offer.get("type", "")), str(offer.get("item_id", "")),
		str(offer.get("ability_id", str(offer.get("amount", ""))))]

func _offer_title(offer: Dictionary) -> String:
	match str(offer.get("type", "")):
		"item":
			var data: Dictionary = ItemDatabase.get_item_data(str(offer.get("item_id", "")))
			return str(data.get("display_name", offer.get("item_id", "")))
		"money":
			# The amount is the plaque's job; repeating it here wastes the title.
			return "Payment"
		"training":
			var ability: Dictionary = AbilityDatabase.get_ability_data(str(offer.get("ability_id", "")))
			return str(ability.get("display_name", offer.get("ability_id", "")))
	return "Reward"

## The single number worth stamping, or {} for offers that have none.
func _offer_figure(offer: Dictionary) -> Dictionary:
	match str(offer.get("type", "")):
		"money":
			return {"value": str(int(offer.get("amount", 0))), "unit": "COIN"}
		"training":
			var days: int = maxi(1, int(offer.get("base_days", 3)))
			var unit: String = "DAYS OF STUDY"
			if days == 1:
				unit = "DAY OF STUDY"
			return {"value": str(days), "unit": unit}
	return {}

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
func _offer_footnote(offer: Dictionary) -> String:
	if str(offer.get("type", "")) != "training":
		return ""
	var teacher: String = str(offer.get("teacher_title", "")).strip_edges()
	var who: String = teacher if not teacher.is_empty() else "your teacher"
	return "Taught by %s. You must stay in town and do the work." % who

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
	# Guard the double-click: the buttons stay live for a beat after the first.
	if _resolved:
		return
	_resolved = true
	match str(offer.get("type", "")):
		"money":
			# Shares DowntimeEffectApplier._apply_money's throttle id, which
			# pays this out in the same frame: one clink.
			SfxManager.play_ui_throttled("coin_pickup", 0.15, "coin_pickup")
		"item":
			SfxManager.play_ui("chest_item_in")
		_:
			SfxManager.play_ui("charm_chime", Vector2(0.95, 1.05), -4.0)
	chosen.emit(offer)

func _unhandled_key_input(event: InputEvent) -> void:
	# Escape declines the whole thing. The quest is already complete either way,
	# since turn_in() ran before this screen opened, so this forfeits the reward
	# rather than rolling anything back.
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		if not _resolved:
			_resolved = true
			SfxManager.play_ui("trade_decline")
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
		CARD_SIZE.y + 100.0)
	column.size = wanted
	var scale_factor: float = minf(1.0, minf(
			(view.x - MARGIN.x) / wanted.x,
			(view.y - MARGIN.y) / wanted.y))
	scale_factor = maxf(scale_factor, 0.2)
	column.scale = Vector2(scale_factor, scale_factor)
	column.position = ((view - wanted * scale_factor) * 0.5).floor()

# ---------------------------------------------------------------------------
# Type builders. Deliberate twins of CartaIdentita's, kept local because those
# are private methods on that Control. Same palette, same display face.
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

## Cinzel is an all-caps display face and it is ALSO ThemeDB.fallback_font here,
## so prose left on the default comes out engraved and barely readable.
##
## The carta d'identita uses a monospace typewriter face for its field entries,
## which is right for a clerk filling in a form. This card is prose being read
## at a glance, and a serif book face is markedly more legible at these sizes.
func _body_face() -> SystemFont:
	if _body_font == null:
		_body_font = SystemFont.new()
		_body_font.font_names = PackedStringArray([
			"Georgia", "Palatino Linotype", "Book Antiqua", "Cambria",
			"Constantia", "Liberation Serif", "DejaVu Serif", "serif"])
	return _body_font

func _typed(text: String, font_size: int, color: Color = TYPED) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", _body_face())
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
	btn.add_theme_font_size_override("font_size", 15 if not emphatic else 18)
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
		style.content_margin_top = 8
		style.content_margin_bottom = 8
		btn.add_theme_stylebox_override(state, style)
	btn.add_theme_color_override("font_color", ENGRAVED)
	btn.add_theme_color_override("font_hover_color", TYPED)
	btn.add_theme_color_override("font_pressed_color", TYPED)
	btn.pressed.connect(handler)
	return btn
