## CartaIdentita
## The Scarlatti identity card — character creation and the character sheet are
## the same document. In Mode.CREATE the holder's particulars are editable and
## the profession and photograph can be chosen; in Mode.VIEW everything is set
## in type and the only control is CHIUDI. The examination is sat once either
## way — there is no re-rolling a score.
##
## Pure GDScript, no .tscn (house style — see ReadableWindow). Instantiate with
##     var carta = load("res://UI/CartaIdentita.gd").new()
##     carta.setup(draft, CartaIdentita.Mode.CREATE)
## and connect `confirmed` / `closed`.
##
## A "draft" is the dictionary CharacterCreationDatabase.roll_draft() returns:
##   {name, gender, background_id, portrait_id,
##    body_metrics: {height, weight, age, height_unit, weight_unit},
##    stats: {strength: int, ...}}
## It is exactly what Game stores in party_state[0].overrides, so the card can
## always be rebuilt from a save.
class_name CartaIdentita
extends Control

signal confirmed(draft: Dictionary)
signal closed()

enum Mode { CREATE, VIEW }

const CARD_SIZE := Vector2(1060, 734)

## The seeded portraits are circular character tokens (see
## tools/generate_character_icons.py): the artwork sits inside radius 113 of
## centre 128,128 on a 256px canvas, with a tan ring outside it and transparent
## corners beyond that. Dropped whole into a rectangular frame, that ring and
## those corners are the first thing you see. So crop instead to the largest
## frame-shaped rectangle that fits wholly inside the artwork circle, nudged up
## so the sitter's face lands centre. Expressed as fractions of the source, so
## it holds whatever resolution the token is.
const TOKEN_CROP := Rect2(0.230, 0.156, 0.539, 0.656)
const FONT_PATH: String = "res://Fonts/Cinzel-Regular.ttf"
const PHOTO_SIZE := Vector2(196, 236)

# The card's ink. Captions are engraved in the plate colour; the clerk's
# entries are typed over the top in a different, darker ink.
const ENGRAVED := Color(0.365, 0.110, 0.180)
const TYPED := Color(0.176, 0.129, 0.098)
const TYPED_DIM := Color(0.176, 0.129, 0.098, 0.62)
## Body prose. Set apart from the field entries so the profession's description
## reads as a note rather than a filled-in value, but kept dark enough to
## actually read — it is the longest run of text on the card and it was set at
## 12px in placeholder grey.
const TYPED_BODY := Color(0.176, 0.129, 0.098, 0.90)
const RULE := Color(0.365, 0.110, 0.180, 0.40)

var mode: int = Mode.CREATE
var draft: Dictionary = {}

var _font: FontFile = null
## The clerk's typewriter. Built lazily and shared by every typed entry.
var _typewriter: SystemFont = null
var _portrait_index: int = 0
var _background_ids: Array = []

# Widgets rebuilt on demand.
var _name_edit: LineEdit = null
var _name_label: Label = null
var _number_label: Label = null
var _photo_rect: TextureRect = null
var _photo_counter: Label = null
var _gender_buttons: Dictionary = {}   # gender_id -> Button
var _gender_value: Label = null
var _background_option: OptionButton = null
var _background_value: Label = null
var _background_blurb: Label = null
var _age_value: Label = null
var _height_value: Label = null
var _weight_value: Label = null
var _marks_value: Label = null
var _stat_values: Dictionary = {}      # stat_key -> value Label
var _verdict_label: Label = null

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

## Populate and build. Safe to call before or after the node enters the tree.
func setup(initial_draft: Dictionary, in_mode: int = Mode.CREATE) -> void:
	draft = initial_draft.duplicate(true)
	mode = in_mode
	if is_inside_tree():
		_rebuild()

func _ready() -> void:
	custom_minimum_size = CARD_SIZE
	size = CARD_SIZE
	if ResourceLoader.exists(FONT_PATH):
		_font = load(FONT_PATH)
	if draft.is_empty():
		draft = CharacterCreationDatabase.roll_draft()
	_rebuild()

## Read a live character back into draft form so the same document can be shown
## as that character's sheet. Falls back gracefully for party members who were
## never created through this screen (they have a template, not a card).
func draft_from_character(character) -> Dictionary:
	var stats: Dictionary = {}
	for stat_key in CharacterCreationDatabase.stat_keys():
		if stat_key in character:
			stats[stat_key] = int(character.get(stat_key))

	# A protagonist created through this screen carries the convalidated
	# document itself. Reprint that, with the live scores — an examination
	# result is a snapshot, but the card is the card.
	var issued: Dictionary = character.get_meta("carta", {})
	if not issued.is_empty():
		var reprint: Dictionary = issued.duplicate(true)
		reprint["name"] = String(character.display_name)
		if not stats.is_empty():
			reprint["stats"] = stats
		return reprint

	var metrics: Dictionary = {
		"height": int(character.get("race_height")) if "race_height" in character else 0,
		"weight": int(character.get("race_weight")) if "race_weight" in character else 0,
		"age": int(character.get("age")) if "age" in character else 0,
		"height_unit": "cm",
		"weight_unit": "kg",
	}
	# A character built straight from a template has never had metrics rolled.
	if int(metrics["height"]) <= 0:
		var race_id: String = String(character.get("race_id")) if "race_id" in character else "human"
		var gender_id: String = String(character.get("gender")) if "gender" in character else "male"
		metrics = RaceDatabase.roll_body_metrics(race_id, gender_id)

	var portrait_id: String = ""
	var icon_path: String = String(character.get("icon_path")) if "icon_path" in character else ""

	return {
		"name": String(character.display_name),
		"gender": String(character.get("gender")) if "gender" in character else "male",
		"background_id": String(character.get("background_id")) if "background_id" in character else "",
		"portrait_id": portrait_id,
		"icon_path": icon_path,
		"body_metrics": metrics,
		"stats": stats,
	}

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func _rebuild() -> void:
	# remove_child before queue_free: a queued node is still a child for the
	# rest of the frame, and the containers below would lay out against the old
	# document as well as the new one.
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_stat_values.clear()
	_gender_buttons.clear()

	var bg := GuillocheRect.new()
	bg.pattern_seed = abs(String(draft.get("name", "")).hash())
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 34)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	margin.add_child(column)

	column.add_child(_build_header())
	column.add_child(_build_rule(1.4))
	column.add_child(_build_body())
	column.add_child(_build_rule(1.4))
	column.add_child(_build_exam())
	column.add_child(_build_actions())

	_sync_all()

# --- Header -----------------------------------------------------------------

func _build_header() -> Control:
	var header := VBoxContainer.new()
	header.add_theme_constant_override("separation", 2)

	header.add_child(_engraved(
			CharacterCreationDatabase.doc_text("republic_line", "REPVBBLICA DI SCARLATTI"),
			16, 5.0))
	var emblem := ScarlattiEmblem.new()
	emblem.custom_minimum_size = Vector2(76, 76)
	emblem.ink = ENGRAVED
	emblem.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	header.add_child(emblem)

	header.add_child(_engraved(
			CharacterCreationDatabase.doc_text("title", "CARTA D'IDENTITA'"), 25, 7.0))

	var number_row := HBoxContainer.new()
	number_row.alignment = BoxContainer.ALIGNMENT_CENTER
	number_row.add_theme_constant_override("separation", 12)
	number_row.add_child(_engraved(
			CharacterCreationDatabase.doc_text("number_label", "Nº"), 13, 2.0))
	_number_label = _typed("", 15)
	number_row.add_child(_number_label)
	header.add_child(number_row)

	return header

# --- Body: photograph + particulars -----------------------------------------

func _build_body() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 26)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(_build_photo_column())
	row.add_child(_build_fields_column())
	return row

func _build_photo_column() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size.x = PHOTO_SIZE.x

	# The photograph sits in a plain printer's frame.
	var frame := PanelContainer.new()
	var frame_style := StyleBoxFlat.new()
	frame_style.bg_color = Color(0.937, 0.898, 0.839)
	frame_style.set_border_width_all(2)
	frame_style.border_color = ENGRAVED
	frame_style.set_content_margin_all(4)
	frame.add_theme_stylebox_override("panel", frame_style)
	frame.custom_minimum_size = PHOTO_SIZE
	col.add_child(frame)

	_photo_rect = TextureRect.new()
	_photo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_photo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_photo_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_photo_rect.custom_minimum_size = PHOTO_SIZE - Vector2(8, 8)
	frame.add_child(_photo_rect)

	if mode == Mode.CREATE:
		var nav := HBoxContainer.new()
		nav.alignment = BoxContainer.ALIGNMENT_CENTER
		nav.add_theme_constant_override("separation", 8)
		nav.add_child(_small_button(
				CharacterCreationDatabase.button_label("prev"), _on_prev_portrait))
		_photo_counter = _typed("", 12)
		_photo_counter.custom_minimum_size.x = 56
		_photo_counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		nav.add_child(_photo_counter)
		nav.add_child(_small_button(
				CharacterCreationDatabase.button_label("next"), _on_next_portrait))
		col.add_child(nav)

	return col

func _build_fields_column() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 9)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# COGNOME E NOME
	var name_control: Control
	if mode == Mode.CREATE:
		_name_edit = LineEdit.new()
		_name_edit.placeholder_text = CharacterCreationDatabase.doc_text(
				"name_placeholder", "")
		_name_edit.max_length = 40
		_name_edit.flat = true
		_name_edit.add_theme_font_override("font", _typewriter_font())
		_name_edit.add_theme_color_override("font_color", TYPED)
		_name_edit.add_theme_color_override("font_placeholder_color", TYPED_DIM)
		_name_edit.add_theme_font_size_override("font_size", 22)
		_name_edit.text_changed.connect(_on_name_changed)
		name_control = _name_edit
	else:
		_name_label = _typed("", 22)
		name_control = _name_label

	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 8)
	name_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(name_control)
	if mode == Mode.CREATE:
		# Buttons that play their own sound in the handler, not the click.
		name_row.add_child(_silent(_small_button(
				CharacterCreationDatabase.button_label("roll_name"), _on_roll_name)))
	col.add_child(_field(CharacterCreationDatabase.field_label("name"), name_row))

	# SESSO + ETÀ / STATURA / PESO on one line. The three measurements are
	# rolled off the holder's sex, so they belong beside it — and picking a sex
	# is the only thing on the card that changes them.
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 22)

	var gender_control: Control
	if mode == Mode.CREATE:
		var gender_row := HBoxContainer.new()
		gender_row.add_theme_constant_override("separation", 6)
		for entry in CharacterCreationDatabase.genders():
			var gid: String = String(entry.get("id", ""))
			var btn := _small_button(String(entry.get("abbrev", "?")),
					func() -> void: _on_gender_picked(gid))
			btn.toggle_mode = true
			btn.set_meta("sfx_silent", true)
			btn.custom_minimum_size.x = 40
			btn.tooltip_text = String(entry.get("label", gid))
			_gender_buttons[gid] = btn
			gender_row.add_child(btn)
		gender_control = gender_row
	else:
		_gender_value = _typed("", 18)
		gender_control = _gender_value
	var gender_field: Control = _field(
			CharacterCreationDatabase.field_label("gender"), gender_control)
	gender_field.custom_minimum_size.x = 118
	row2.add_child(gender_field)

	_age_value = _typed("", 18)
	_height_value = _typed("", 18)
	_weight_value = _typed("", 18)
	for pair in [
			["age", _age_value], ["height", _height_value], ["weight", _weight_value]]:
		var f: Control = _field(
				CharacterCreationDatabase.field_label(String(pair[0])), pair[1])
		f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(f)
	col.add_child(row2)

	# PROFESSIONE
	var bg_control: Control
	if mode == Mode.CREATE:
		_background_option = _option_button()
		_background_option.item_selected.connect(_on_background_selected)
		bg_control = _background_option
	else:
		_background_value = _typed("", 18)
		bg_control = _background_value
	col.add_child(_field(
			CharacterCreationDatabase.field_label("profession"), bg_control))

	_background_blurb = _typed("", 14, TYPED_BODY)
	_background_blurb.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# Monospace at this measure needs the leading opened up or the lines mat
	# together into a block.
	_background_blurb.add_theme_constant_override("line_spacing", 5)
	# Reserved for the longest description in backgrounds.json (carnie, four
	# lines at this measure). Fixing it to the worst case keeps every field
	# below from shifting as the player scrolls through professions.
	_background_blurb.custom_minimum_size.y = 90
	_background_blurb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_child(_background_blurb)

	# Distinguishing marks. The citizenship line above this used to read
	# "Scarlattina" for every holder, which is not information.
	_marks_value = _typed("", 15)
	col.add_child(_field(CharacterCreationDatabase.field_label("marks"), _marks_value))

	return col

# --- The medical examination ------------------------------------------------

func _build_exam() -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)

	col.add_child(_engraved(
			CharacterCreationDatabase.exam_text("header", ""), 15, 5.0))

	# Two half-width columns of three measurements: name left, score right. One
	# wide grid instead would run the left half's score into the right half's
	# name, and "77 Volonta" reads as a single entry.
	var entries: Array = CharacterCreationDatabase.stats()
	var half: int = int(ceil(float(entries.size()) * 0.5))

	var halves := HBoxContainer.new()
	halves.add_theme_constant_override("separation", 56)
	halves.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for c in range(2):
		var grid := GridContainer.new()
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 14)
		grid.add_theme_constant_override("v_separation", 3)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		for r in range(half):
			var index: int = r + c * half
			if index >= entries.size():
				continue
			var entry: Dictionary = entries[index]
			var stat_key: String = String(entry.get("key", ""))

			var label: Label = _engraved(String(entry.get("label", stat_key)), 14, 1.0, 0.9)
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(label)

			var value: Label = _typed("", 20)
			value.custom_minimum_size.x = 58
			value.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			grid.add_child(value)

			_stat_values[stat_key] = value
		halves.add_child(grid)
	col.add_child(halves)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	footer.add_child(_engraved(
			CharacterCreationDatabase.exam_text("verdict_label", "ESITO") + ":", 13, 3.0))
	_verdict_label = _typed("", 20)
	footer.add_child(_verdict_label)
	col.add_child(footer)

	return col

# --- Action strip -----------------------------------------------------------

func _build_actions() -> Control:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)

	if mode == Mode.CREATE:
		row.add_child(_silent(_small_button(
				CharacterCreationDatabase.button_label("confirm"), _on_confirm, true)))
	else:
		row.add_child(_small_button(
				CharacterCreationDatabase.button_label("close"), _on_close))
	return row

# ---------------------------------------------------------------------------
# State -> widgets
# ---------------------------------------------------------------------------

func _sync_all() -> void:
	_sync_identity()
	_sync_options()
	_sync_portrait()
	_sync_metrics()
	_sync_stats()

func _sync_identity() -> void:
	var holder: String = String(draft.get("name", ""))
	if _name_edit and _name_edit.text != holder:
		_name_edit.text = holder
	if _name_label:
		_name_label.text = holder
	if _number_label:
		_number_label.text = CharacterCreationDatabase.document_number(holder)

	var gender: String = String(draft.get("gender", "male"))
	for gid in _gender_buttons:
		var btn: Button = _gender_buttons[gid]
		btn.set_pressed_no_signal(String(gid) == gender)
	if _gender_value:
		_gender_value.text = CharacterCreationDatabase.gender_label(gender)

	var bg_id: String = String(draft.get("background_id", ""))
	if _background_value:
		_background_value.text = CharacterCreationDatabase.background_label(bg_id)
	if _background_blurb:
		_background_blurb.text = CharacterCreationDatabase.background_description(bg_id)
	if _marks_value:
		_marks_value.text = CharacterCreationDatabase.background_marks(bg_id)

## Refill the two dropdowns. The profession list depends on the chosen sex, so
## this runs again on every sex change.
func _sync_options() -> void:
	if _background_option:
		var gender: String = String(draft.get("gender", "male"))
		_background_ids = CharacterCreationDatabase.background_ids_for(gender)
		_background_option.clear()
		for bg_id in _background_ids:
			_background_option.add_item(CharacterCreationDatabase.background_label(bg_id))
		var current: String = String(draft.get("background_id", ""))
		var idx: int = _background_ids.find(current)
		if idx < 0:
			# The held profession is barred to this sex; fall back to the first.
			idx = 0
			if not _background_ids.is_empty():
				draft["background_id"] = _background_ids[0]
				_sync_identity()
		if not _background_ids.is_empty():
			_background_option.select(idx)

func _sync_portrait() -> void:
	if _photo_rect == null:
		return

	# Re-derive the cursor from the draft rather than trusting a stale index:
	# a draft that arrives with a portrait already chosen (a reroll, a load, a
	# preset) would otherwise show that face while the counter — and the next
	# ◀/▶ press — believed it was sitting on entry 1.
	var pool: Array = CharacterCreationDatabase.portraits_for(
			String(draft.get("gender", "male")))
	var current_id: String = String(draft.get("portrait_id", ""))
	var found: int = -1
	for i in range(pool.size()):
		if String(pool[i].get("id", "")) == current_id:
			found = i
			break
	if found < 0 and not pool.is_empty():
		# Not in this pool at all (the sex changed, or the manifest dropped the
		# entry) — adopt the first rather than leaving an empty frame.
		found = 0
		draft["portrait_id"] = String(pool[0].get("id", ""))
	_portrait_index = maxi(found, 0)

	_photo_rect.texture = _photo_texture(_current_portrait_path())
	if _photo_counter:
		_photo_counter.text = "%d/%d" % [_portrait_index + 1, maxi(pool.size(), 1)]

func _sync_metrics() -> void:
	var metrics: Dictionary = draft.get("body_metrics", {})
	if _age_value:
		_age_value.text = "%d anni" % int(metrics.get("age", 0))
	if _height_value:
		_height_value.text = _format_height(int(metrics.get("height", 0)))
	if _weight_value:
		_weight_value.text = "%d %s" % [
			int(metrics.get("weight", 0)), String(metrics.get("weight_unit", "kg"))]

func _sync_stats() -> void:
	var stats: Dictionary = draft.get("stats", {})
	for stat_key in _stat_values:
		_stat_values[stat_key].text = str(int(stats.get(stat_key, 0)))
	if _verdict_label:
		_verdict_label.text = CharacterCreationDatabase.verdict_text(
				String(draft.get("gender", "male")))

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_name_changed(new_text: String) -> void:
	draft["name"] = new_text
	if _number_label:
		_number_label.text = CharacterCreationDatabase.document_number(new_text)

func _on_roll_name() -> void:
	SfxManager.play_ui("dice_roll", Vector2(0.95, 1.05), -4.0)
	draft["name"] = CharacterCreationDatabase.random_name(String(draft.get("gender", "male")))
	_sync_identity()

## Picking a sex re-measures the holder: height, weight and age all come off
## the gendered dice in races.json, so they cannot survive the change.
func _on_gender_picked(gender_id: String) -> void:
	if String(draft.get("gender", "")) == gender_id:
		SfxManager.play_ui("ui-click", Vector2(0.95, 1.05), -6.0)
		_sync_identity()   # re-press the button the player just un-toggled
		return
	# The card is re-filled with new measurements.
	SfxManager.play_ui("paper_rustle", Vector2(0.95, 1.05), -6.0)
	draft["gender"] = gender_id
	draft["body_metrics"] = RaceDatabase.roll_body_metrics(
			CharacterCreationDatabase.PLAYER_RACE, gender_id)
	_portrait_index = 0
	draft["portrait_id"] = _portrait_id_at(0)
	_sync_options()
	_sync_identity()
	_sync_portrait()
	_sync_metrics()
	_sync_stats()

func _on_background_selected(index: int) -> void:
	if index < 0 or index >= _background_ids.size():
		return
	draft["background_id"] = _background_ids[index]
	_sync_identity()

func _on_prev_portrait() -> void:
	_step_portrait(-1)

func _on_next_portrait() -> void:
	_step_portrait(1)

func _step_portrait(delta: int) -> void:
	var pool: Array = CharacterCreationDatabase.portraits_for(
			String(draft.get("gender", "male")))
	if pool.is_empty():
		return
	_portrait_index = posmod(_portrait_index + delta, pool.size())
	draft["portrait_id"] = String(pool[_portrait_index].get("id", ""))
	_sync_portrait()

func _on_confirm() -> void:
	if String(draft.get("name", "")).strip_edges().is_empty():
		# No name yet: the confirm rolls one instead of stamping.
		SfxManager.play_ui("dice_roll", Vector2(0.95, 1.05), -4.0)
		draft["name"] = CharacterCreationDatabase.random_name(
				String(draft.get("gender", "male")))
		_sync_identity()
		return
	draft["name"] = String(draft["name"]).strip_edges()
	# The carta is stamped and issued.
	SfxManager.play_ui("stamp", Vector2(0.95, 1.05), -4.0)
	confirmed.emit(draft.duplicate(true))

func _on_close() -> void:
	closed.emit()

# ---------------------------------------------------------------------------
# Small builders
# ---------------------------------------------------------------------------

## An engraved caption: Cinzel, letter-spaced, plate-coloured, centred.
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

## The face the holder's particulars are typed in. The project sets Cinzel as
## gui/theme/custom_font — an all-caps display face — and that propagates into
## ThemeDB.fallback_font too, so an entry left on the default would come out
## engraved like the caption above it and a paragraph of it is barely readable.
## A system typewriter face gives the plate-vs-typewriter contrast the reference
## card has, and every one of these names is a standard OS font.
func _typewriter_font() -> SystemFont:
	if _typewriter == null:
		_typewriter = SystemFont.new()
		_typewriter.font_names = PackedStringArray([
			"Courier New", "Consolas", "Liberation Mono", "DejaVu Sans Mono",
			"Menlo", "monospace"])
	return _typewriter

## A clerk's entry.
func _typed(text: String, font_size: int, color: Color = TYPED) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", _typewriter_font())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

## Godot has no letter-spacing on Label, and the wide-tracked capitals are half
## of why the reference looks official. Space-padding is the cheap trick that
## gets there without a custom draw.
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

## Caption above a ruled line, with the value sitting on the rule.
func _field(caption: String, value_control: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)

	var label := Label.new()
	label.text = _letterspace(caption, 2.0)
	label.add_theme_font_size_override("font_size", 9)
	label.add_theme_color_override("font_color", Color(ENGRAVED.r, ENGRAVED.g, ENGRAVED.b, 0.75))
	if _font:
		label.add_theme_font_override("font", _font)
	box.add_child(label)

	var ruled := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.draw_center = false
	style.border_width_bottom = 1
	style.border_color = RULE
	style.content_margin_left = 2
	style.content_margin_bottom = 2
	ruled.add_theme_stylebox_override("panel", style)
	ruled.add_child(value_control)
	box.add_child(ruled)
	return box

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

## Opts a button out of the global click; its handler plays its own sound.
func _silent(btn: Button) -> Button:
	btn.set_meta("sfx_silent", true)
	return btn

func _option_button() -> OptionButton:
	var opt := OptionButton.new()
	opt.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	opt.add_theme_font_override("font", _typewriter_font())
	opt.add_theme_font_size_override("font_size", 17)
	opt.add_theme_color_override("font_color", TYPED)
	opt.add_theme_color_override("font_hover_color", ENGRAVED)
	opt.add_theme_color_override("font_focus_color", TYPED)
	opt.alignment = HORIZONTAL_ALIGNMENT_LEFT
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var style := StyleBoxFlat.new()
		style.draw_center = false
		style.content_margin_left = 2
		style.content_margin_right = 2
		style.content_margin_top = 1
		style.content_margin_bottom = 1
		if state == "hover":
			style.draw_center = true
			style.bg_color = Color(0.365, 0.110, 0.180, 0.07)
		opt.add_theme_stylebox_override(state, style)
	return opt

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

## Load a portrait, cropped into the token artwork when that is what it is.
## A purpose-built card photograph is marked "full" in the manifest and is used
## as it stands.
func _photo_texture(path: String) -> Texture2D:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	var tex: Texture2D = load(path)
	if tex == null:
		return null
	var crop: String = CharacterCreationDatabase.portrait_crop(
			String(draft.get("portrait_id", "")))
	if crop != "token":
		return tex
	var source := Vector2(float(tex.get_width()), float(tex.get_height()))
	var atlas := AtlasTexture.new()
	atlas.atlas = tex
	atlas.region = Rect2(TOKEN_CROP.position * source, TOKEN_CROP.size * source)
	atlas.filter_clip = true
	return atlas

func _current_portrait_path() -> String:
	var explicit: String = String(draft.get("icon_path", ""))
	if not explicit.is_empty():
		return explicit
	return CharacterCreationDatabase.portrait_path(String(draft.get("portrait_id", "")))

func _portrait_id_at(index: int) -> String:
	var pool: Array = CharacterCreationDatabase.portraits_for(
			String(draft.get("gender", "male")))
	if pool.is_empty():
		return ""
	return String(pool[clampi(index, 0, pool.size() - 1)].get("id", ""))

## Statura is printed in metres with a comma, the way the reference card does:
## 171 cm -> "1,71 m".
func _format_height(cm: int) -> String:
	if cm <= 0:
		return "—"
	return ("%.2f" % (float(cm) / 100.0)).replace(".", ",") + " m"
