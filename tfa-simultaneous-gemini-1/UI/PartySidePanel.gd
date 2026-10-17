# UI/PartySidePanel.gd
# Side panel showing party character portraits, school-resource icons, and
# inventories. Toggle visibility with Tab. Supports drag-drop and right-click
# context menus.
extends PanelContainer

signal panel_visibility_changed(now_visible: bool)

const PANEL_WIDTH := 250.0
const SLIDE_DURATION := 0.3
const DUMMY_ICON_PATH := "res://Icons/dummy_icon.png"
const CONTEXT_MENU_SCENE := preload("res://UI/ContextMenu.tscn")
const ITEM_SLOT_SIZE := Vector2(40, 40)
# 26, not 16. Under the old EXPAND_FIT_WIDTH_PROPORTIONAL these rects inherited
# the header's full 40px portrait height and KEEP_ASPECT_CENTERED drew the square
# icons at ~40px, so 16 was never the size anyone actually saw. Pinning them to
# EXPAND_IGNORE_SIZE (needed to stop tall item art stretching slot rows) made the
# declared size real for the first time and the pips shrank to genuinely 16px.
# 26 restores a legible pip while still clearing the 40px row with margin —
# turn it up if the row can afford it, down if a heavily-conditioned character
# overflows the header.
const COND_ICON_SIZE := Vector2(26, 26)
# Header budget. The header is the one row here whose width is driven by DATA
# (name length, condition count), so it is the one that can overflow the panel.
# Rather than reserve a fixed name column — which wasted the pips' share of the
# row on every character who had no conditions, truncating names for no reason —
# the name is measured and given whatever the pips actually leave:
#   name = clamp(text width, NAME_MIN, PANEL_WIDTH - portrait - live pip width)
# See _fit_name_column. Worst case (4 pips) still fits: 40 + 44 + 112 = 196.
const HEADER_PORTRAIT_W := 40.0
const HEADER_WAIT_W := 18.0
const HEADER_PAD := 10.0
const NAME_MIN_WIDTH := 44.0
const MAX_COND_PIPS := 4
const COND_OVERFLOW_TAG_W := 22.0
const RESOURCE_ICON_SIZE := Vector2(32, 32)

# School trait → (resource_field, icon_path, fill_color). Icons live in
# UI/UI Icons/.
const SCHOOL_RESOURCES := [
	{"school": "Martial", "resource": "adrenaline", "icon": "res://UI/UI Icons/Adrenaline Icon.png", "color": Color(0.9, 0.2, 0.2)},
	{"school": "Arcane", "resource": "focus", "icon": "res://UI/UI Icons/Focus Icon.png", "color": Color(0.3, 0.5, 0.95)},
	{"school": "Primal", "resource": "harmony", "icon": "res://UI/UI Icons/Harmony Icon.png", "color": Color(0.3, 0.8, 0.4)},
	{"school": "Holy", "resource": "devotion", "icon": "res://UI/UI Icons/Devotion Icon.png", "color": Color(0.95, 0.85, 0.45)},
	{"school": "Occult", "resource": "souls", "icon": "res://UI/UI Icons/soul icon.png", "color": Color(0.5, 0.2, 0.6)},
]

# Health bar color thresholds (matching old dual_health_bars style)
const HP_COLOR_FULL := Color(0.2, 0.8, 0.2)
const STRESS_COLOR := Color(0.6, 0.3, 0.8)
# Stress at or past ProceduralCharacter.STRESS_DANGER_RATIO: each gain rolls Will.
const STRESS_DANGER_COLOR := Color(0.9, 0.2, 0.7)
const HP_COLOR_MID := Color(0.9, 0.8, 0.1)
const HP_COLOR_LOW := Color(0.8, 0.1, 0.1)
const HP_MID_THRESHOLD := 0.5
const HP_LOW_THRESHOLD := 0.25

var game_node: Node = null
var panel_visible: bool = true
var _shown_x: float = 0.0
var _hidden_x: float = 0.0
var _tween: Tween = null
var _character_panels: Array = []  # Array of dictionaries with UI references

# TextureProgressBar.custom_minimum_size is only a floor; the bar's real
# minimum is max(floor, texture.get_size()). The source PNGs are 1k+ so
# we resize once at first use and cache.
var _resource_icon_cache: Dictionary = {}  # "path@WxH" -> Texture2D

# Downtime mode: panel hides while active and restores prior state on exit.
var _saved_panel_visible_pre_downtime: bool = true
var _in_downtime_hide: bool = false

# Scroll container for the character list
var scroll: ScrollContainer
var vbox: VBoxContainer

func _ready() -> void:
	game_node = get_node_or_null("/root/Game")
	mouse_filter = Control.MOUSE_FILTER_STOP

	# Compute slide positions (panel anchored to right edge)
	_shown_x = -PANEL_WIDTH
	_hidden_x = 0.0

	# Build internal layout
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.mouse_filter = Control.MOUSE_FILTER_STOP
	# This panel is a FIXED PANEL_WIDTH strip pinned to the screen edge, so there
	# is no such thing as a legitimate horizontal scroll here — the content is
	# supposed to fit. Left enabled, any child whose minimum width crept past
	# PANEL_WIDTH (a long character name, one pip too many in the header) silently
	# turned the whole panel into a horizontally scrollable surface and let it
	# slide off screen. Disabling it also makes ScrollContainer CLAMP the child to
	# the viewport width instead of letting it grow to its own minimum, which is
	# what actually keeps the layout honest. The header is separately bounded
	# below (fixed name width + a capped pip row) so nothing has to be clipped.
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.mouse_filter = Control.MOUSE_FILTER_STOP
	scroll.add_child(vbox)
	_forward_dnd(scroll)
	_forward_dnd(vbox)

	# Populate after a frame so characters exist
	call_deferred("_populate_party")

	# Hide while downtime mode is active so the CampDowntimePanel can take
	# the right side. Restore prior state when downtime ends.
	if game_node and game_node.has_signal("downtime_mode_changed"):
		game_node.connect("downtime_mode_changed", _on_downtime_mode_changed)

	# A map warp frees the old party nodes and respawns fresh ones, so the
	# cached character references in _character_panels go stale. Rebuild from
	# the new party_chars once the map has finished loading.
	if game_node and game_node.has_signal("map_loaded"):
		game_node.connect("map_loaded", _on_map_loaded)

func _on_downtime_mode_changed(active: bool) -> void:
	if active:
		_saved_panel_visible_pre_downtime = panel_visible
		_in_downtime_hide = true
		if panel_visible:
			_toggle_panel()
		_in_downtime_hide = false
	else:
		if not panel_visible and _saved_panel_visible_pre_downtime:
			_in_downtime_hide = true
			_toggle_panel()
			_in_downtime_hide = false

func _disconnect_panel_signals(data: Dictionary) -> void:
	# A warp frees the character (and its inventory), so guard validity first.
	var character = data.get("character")
	if not is_instance_valid(character):
		return
	var inv = character.inventory
	if not is_instance_valid(inv):
		return
	var on_changed: Callable = data.get("_sig_on_changed", Callable())
	var on_active: Callable = data.get("_sig_on_active", Callable())
	var on_add_failed: Callable = data.get("_sig_on_add_failed", Callable())
	if on_add_failed.is_valid() and inv.add_failed.is_connected(on_add_failed):
		inv.add_failed.disconnect(on_add_failed)
	if on_changed.is_valid():
		if inv.item_added.is_connected(on_changed):
			inv.item_added.disconnect(on_changed)
		if inv.item_removed.is_connected(on_changed):
			inv.item_removed.disconnect(on_changed)
		if inv.weapon_equipped.is_connected(on_changed):
			inv.weapon_equipped.disconnect(on_changed)
		if inv.weapon_unequipped.is_connected(on_changed):
			inv.weapon_unequipped.disconnect(on_changed)
	if on_active.is_valid() and inv.active_weapon_changed.is_connected(on_active):
		inv.active_weapon_changed.disconnect(on_active)

func _on_map_loaded(_map_id: String) -> void:
	# Defer so the freed old party nodes are fully gone and the respawned ones
	# are settled before we read game_node.party_chars.
	call_deferred("_populate_party")

## Give the name label exactly the width the header can spare: its own measured
## text width, capped by whatever the condition pips are actually using right
## now. A character with no conditions therefore shows their full name, and only
## a genuinely crowded header truncates — the earlier fixed column reserved the
## pips' share from everyone and cut names that had room to spare.
## Called from _update_conditions, which is the only place the pip count is known.
func _fit_name_column(data: Dictionary, pip_count: int, has_overflow: bool) -> void:
	var name_label: Label = data.get("name_label")
	if name_label == null or not is_instance_valid(name_label):
		return
	var pips_w: float = float(pip_count) * (COND_ICON_SIZE.x + 2.0)
	if has_overflow:
		pips_w += COND_OVERFLOW_TAG_W
	var wait_icon = data.get("wait_icon")
	var wait_w: float = HEADER_WAIT_W if (wait_icon != null and is_instance_valid(wait_icon) and wait_icon.visible) else 0.0
	var avail: float = PANEL_WIDTH - HEADER_PORTRAIT_W - wait_w - pips_w - HEADER_PAD

	# Measure the actual glyphs rather than guessing from character count: the
	# project theme is Cinzel, whose caps are far wider than a default sans, so a
	# character-count estimate would truncate early on exactly the names this is
	# meant to stop truncating.
	var font: Font = name_label.get_theme_font("font")
	var fsize: int = name_label.get_theme_font_size("font_size")
	var natural: float = avail
	if font != null:
		natural = font.get_string_size(
			name_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsize
		).x + 2.0  # a hair of slack so the last glyph never clips on rounding
	var target: float = clampf(natural, NAME_MIN_WIDTH, maxf(NAME_MIN_WIDTH, avail))
	if not is_equal_approx(name_label.custom_minimum_size.x, target):
		name_label.custom_minimum_size = Vector2(target, 0)


## Report any row whose minimum width would widen the panel past PANEL_WIDTH.
## Purely diagnostic — it changes no layout, it just names the culprit so the
## next data-driven row that outgrows the strip shows up in the console instead
## of only on screen. Deferred one frame so minimum sizes have settled.
func _warn_if_too_wide() -> void:
	if vbox == null or not is_instance_valid(vbox):
		return
	var worst: Control = null
	var worst_w: float = PANEL_WIDTH
	for panel in vbox.get_children():
		if not (panel is Control):
			continue
		for row in (panel as Control).get_children():
			if not (row is Control):
				continue
			var w: float = (row as Control).get_combined_minimum_size().x
			if w > worst_w:
				worst_w = w
				worst = row as Control
	if worst != null:
		push_warning(
			"PartySidePanel: '%s' has a minimum width of %.0fpx, wider than PANEL_WIDTH (%.0f). "
			% [worst.name if worst.name != "" else worst.get_class(), worst_w, PANEL_WIDTH]
			+ "A PanelContainer sizes to max(anchor, minimum), so this widens the whole panel. "
			+ "Make the row wrap (HFlowContainer) or bound its contents."
		)


func _populate_party() -> void:
	if not game_node:
		return

	# Tear down old connections before freeing the panels, otherwise a surviving
	# inventory keeps firing into freed grids (e.g. on a non-warp repopulate where
	# the character node persists).
	for old_data in _character_panels:
		_disconnect_panel_signals(old_data)
	for child in vbox.get_children():
		child.queue_free()
	_character_panels.clear()
	# This panel is a PanelContainer, so its width is max(anchor width, minimum
	# width) — a single over-wide row silently drags the whole panel out past its
	# 250px anchor instead of being clipped. That has now happened twice (a
	# one-line resource pip row at 11 * 32px, and an unbounded header), and it is
	# invisible until someone looks at the screen. Check it instead.
	call_deferred("_warn_if_too_wide")

	for i in range(game_node.party_chars.size()):
		var character = game_node.party_chars[i]
		if not is_instance_valid(character):
			continue
		var panel_data = _create_character_panel(character, i)
		_character_panels.append(panel_data)

func _create_character_panel(character, index: int) -> Dictionary:
	var container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.mouse_filter = Control.MOUSE_FILTER_STOP

	# --- Header: Icon + Name (clickable to select character) ---
	var header = HBoxContainer.new()
	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.mouse_filter = Control.MOUSE_FILTER_STOP

	var icon = TextureRect.new()
	icon.custom_minimum_size = Vector2(40, 40)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_load_character_icon(icon, character)
	header.add_child(icon)

	# WAIT badge: same stop hand as the in-world indicator (T / context menu).
	# Sits between portrait and name; hidden unless the character is holding.
	var wait_icon = TextureRect.new()
	wait_icon.texture = preload("res://UI/wait_hand.png")
	wait_icon.custom_minimum_size = Vector2(18, 18)
	wait_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	wait_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wait_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wait_icon.visible = false
	header.add_child(wait_icon)

	var name_label = Label.new()
	name_label.text = character.display_name
	# Width is assigned by _fit_name_column once the condition pips are known, so
	# a character with no conditions gets the whole row for their name and only a
	# genuinely cramped header truncates. SHRINK_BEGIN (not EXPAND_FILL) keeps
	# the pips immediately beside the name instead of splitting the leftover
	# space evenly with it; clip_text stops a long name growing the header, which
	# is what widened the whole panel.
	name_label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	name_label.clip_text = true
	# A name cut by a crowded header ends in "…" rather than mid-letter.
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(name_label)

	# Click header to select this character
	header.gui_input.connect(_on_header_gui_input.bind(index))

	# --- Condition icons row (next to portrait area) ---
	var cond_container = HBoxContainer.new()
	cond_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cond_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cond_container.add_theme_constant_override("separation", 2)
	header.add_child(cond_container)

	container.add_child(header)

	# --- Health Bar (single bar replaces the old head + torso pair) ---
	# The HP numbers sit on their own row, which per-character readouts (the
	# footsteps label, added on the right by _add_footsteps_label) share,
	# keeping them off the crowded header whose width _fit_name_column budgets.
	var hp_row = HBoxContainer.new()
	hp_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(hp_row)

	var hp_label = Label.new()
	hp_label.text = "HP"
	hp_label.add_theme_font_size_override("font_size", 9)
	hp_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hp_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hp_row.add_child(hp_label)

	var health_bar = ProgressBar.new()
	health_bar.custom_minimum_size = Vector2(0, 12)
	health_bar.max_value = 100
	health_bar.value = 100
	health_bar.show_percentage = false
	health_bar.mouse_filter = Control.MOUSE_FILTER_PASS  # PASS so the HP tooltip shows
	var health_fill = StyleBoxFlat.new()
	health_fill.bg_color = HP_COLOR_FULL
	health_bar.add_theme_stylebox_override("fill", health_fill)
	var health_bg = StyleBoxFlat.new()
	health_bg.bg_color = Color(0.3, 0.1, 0.1, 0.6)
	health_bar.add_theme_stylebox_override("background", health_bg)
	container.add_child(health_bar)

	# --- Stress meter (below health; max scales with Will) ---
	var stress_label = Label.new()
	stress_label.text = "Stress"
	stress_label.add_theme_font_size_override("font_size", 9)
	stress_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(stress_label)

	var stress_bar = ProgressBar.new()
	stress_bar.custom_minimum_size = Vector2(0, 10)
	stress_bar.max_value = 100
	stress_bar.value = 0
	stress_bar.show_percentage = false
	stress_bar.mouse_filter = Control.MOUSE_FILTER_PASS  # PASS so the stress tooltip shows
	var stress_fill = StyleBoxFlat.new()
	stress_fill.bg_color = STRESS_COLOR
	stress_bar.add_theme_stylebox_override("fill", stress_fill)
	var stress_bg = StyleBoxFlat.new()
	stress_bg.bg_color = Color(0.12, 0.1, 0.18, 0.6)
	stress_bar.add_theme_stylebox_override("background", stress_bg)
	container.add_child(stress_bar)

	# --- School Resources Row ---
	# One TextureProgressBar per school in which the character has tier > 0.
	# The icon fills left-to-right as the resource recovers; missing resources
	# are hidden entirely (a pure Martial fighter sees only the Adrenaline icon).
	# HFlowContainer, not HBoxContainer. A single row of pips is what forced the
	# whole panel wide: this is a PanelContainer, and a Container's width is
	# max(anchor width, minimum width), so an 11-pip row (11 * 32 = ~380px)
	# dragged the panel out past its 250px anchor rather than being clipped.
	# Flowing wraps to a second line instead of growing sideways, and because
	# each SCHOOL is its own inner HBox child (see _build_resource_bars), a
	# school's pips always stay together on one line — the group is what wraps,
	# never the pips inside it.
	var resource_row = HFlowContainer.new()
	resource_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	resource_row.add_theme_constant_override("h_separation", 4)
	resource_row.add_theme_constant_override("v_separation", 2)
	resource_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(resource_row)
	var resource_bars := _build_resource_bars(character, resource_row)

	# --- Inventory Grid ---
	var inv_label = Label.new()
	inv_label.text = "Inventory"
	inv_label.add_theme_font_size_override("font_size", 11)
	inv_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(inv_label)

	var inv_grid = GridContainer.new()
	inv_grid.columns = 5
	inv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_grid.mouse_filter = Control.MOUSE_FILTER_STOP
	container.add_child(inv_grid)

	# Separator
	var sep = HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 8)
	container.add_child(sep)

	vbox.add_child(container)
	for c in [container, header, inv_grid, sep]:
		_forward_dnd(c)

	var data = {
		"character": character,
		"index": index,
		"container": container,
		"icon": icon,
		"wait_icon": wait_icon,
		"name_label": name_label,
		"hp_row": hp_row,
		"hp_label": hp_label,
		"health_bar": health_bar,
		"health_fill": health_fill,
		"stress_label": stress_label,
		"stress_bar": stress_bar,
		"stress_fill": stress_fill,
		"condition_container": cond_container,
		"resource_row": resource_row,
		"resource_bars": resource_bars,
		"resource_schools": _resource_schools(character),
		"inv_label": inv_label,
		"inv_grid": inv_grid,
	}

	# Connect inventory signals — any change refreshes the unified grid.
	# Stash the bound Callables so a later repopulate can disconnect the exact
	# same connections (see _disconnect_panel_signals). Without this, rebuilding
	# the panels frees their grids but leaves these connections live on a
	# still-alive inventory, so the next change fires _refresh_inventory on a
	# freed grid and crashes.
	var on_changed: Callable = _on_inventory_changed.bind(data)
	var on_active: Callable = _on_active_weapon_changed.bind(data)
	var on_add_failed: Callable = _on_inventory_add_failed.bind(data)
	data["_sig_on_changed"] = on_changed
	data["_sig_on_active"] = on_active
	data["_sig_on_add_failed"] = on_add_failed
	if character.inventory:
		character.inventory.item_added.connect(on_changed)
		character.inventory.item_removed.connect(on_changed)
		character.inventory.add_failed.connect(on_add_failed)
		character.inventory.weapon_equipped.connect(on_changed)
		character.inventory.weapon_unequipped.connect(on_changed)
		character.inventory.active_weapon_changed.connect(on_active)

	_add_footsteps_label(data, hp_row)
	_refresh_inventory(data)
	# Seed the name width for the no-conditions case. _update_conditions re-fits
	# it as pips come and go, but it early-returns for a character with no
	# ConditionManager at all — without this seed such a name would be left at a
	# zero minimum and collapse to nothing.
	_fit_name_column(data, 0, false)
	return data

func _load_character_icon(tex_rect: TextureRect, character) -> void:
	# A per-character portrait (chosen at character creation) outranks the
	# template's shared icon.
	var icon_path: String = String(character.get("icon_path")) if "icon_path" in character else ""
	if icon_path.is_empty():
		var template = TopDownCharacterDatabase.get_template(
			character.get("template_id") if "template_id" in character else character.display_name.to_lower()
		)
		icon_path = template.get("icon", "")
	if not icon_path.is_empty() and ResourceLoader.exists(icon_path):
		tex_rect.texture = load(icon_path)
	elif ResourceLoader.exists(DUMMY_ICON_PATH):
		tex_rect.texture = load(DUMMY_ICON_PATH)
	else:
		# Create a colored placeholder
		var img = Image.create(40, 40, false, Image.FORMAT_RGBA8)
		img.fill(character.skin_color if "skin_color" in character else Color.GRAY)
		tex_rect.texture = ImageTexture.create_from_image(img)

# ---------------------------------------------------------------------------
# Character selection via portrait click
# ---------------------------------------------------------------------------

func _on_header_gui_input(event: InputEvent, index: int) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if game_node:
				var party = game_node.get_party()
				if index >= 0 and index < party.size():
					var character = party[index]
					if event.ctrl_pressed and game_node.has_method("toggle_character_selection"):
						game_node.toggle_character_selection(character)
					elif game_node.has_method("select_character_by_index"):
						game_node.select_character_by_index(index)
			get_viewport().set_input_as_handled()

# ---------------------------------------------------------------------------
# Inventory display
# ---------------------------------------------------------------------------

func _refresh_inventory(data: Dictionary) -> void:
	var grid: GridContainer = data["inv_grid"]
	var character = data["character"]

	for child in grid.get_children():
		child.queue_free()

	if not character.inventory:
		return

	# Item slots used vs the hard cap that makes pick-ups and transfers fail.
	# Weapons, abilities and the hidden hand-weapon dicts don't count
	# (Inventory.slots_used, the count add_item checks).
	var inv_label: Label = data.get("inv_label")
	if inv_label:
		var used: int = character.inventory.slots_used()
		var cap: int = character.inventory.max_slots
		inv_label.text = "Inventory %d/%d" % [used, cap]
		inv_label.modulate = Color.ORANGE if used >= cap else Color.WHITE

	var entries = _build_inventory_entries(character.inventory)
	# On the world map, show only abilities that carry the "overworld" trait
	# (e.g. Force March). Items and weapons are unaffected — they're still
	# visible. Game.gd tracks current_map_data.is_world_map for this gate.
	if game_node and game_node.current_map_data.get("is_world_map", false):
		entries = entries.filter(func(e):
			if e.get("kind", "") != "ability":
				return true
			var aid: String = str(e.get("ability_id", ""))
			var ability_data: Dictionary = AbilityDatabase.get_ability_data(aid)
			return ability_data.get("traits", {}).has("overworld"))
	# Ability slots grey out while their cost can't be paid (see _process).
	var ability_slots: Array = []
	for entry in entries:
		if entry.get("kind", "") == "ability":
			_set_ability_costs(entry, character)
		var slot = _create_item_slot(entry, data)
		grid.add_child(slot)
		if entry.get("kind", "") == "ability" and not entry.get("costs", {}).is_empty():
			ability_slots.append({"slot": slot, "costs": entry["costs"],
				"concentration": entry.get("concentration", false)})
	data["ability_slots"] = ability_slots

# The real cost of an ability slot comes from its school traits (Arcane 2 ->
# 2 focus), not the deprecated "costs" field, so ask AbilityManager. Racial
# abilities, and casters with unlimited resources, pay nothing: AbilityManager
# skips their resource gate, so show them free and never grey them out.
func _set_ability_costs(entry: Dictionary, character) -> void:
	var node = entry.get("raw")
	var costs: Dictionary = {}
	if is_instance_valid(node) and node.raw_data is Dictionary and not node.raw_data.is_empty():
		var ability: Ability = Ability.from_dict(node.raw_data)
		var am = character.get("ability_manager")
		var innate: bool = am != null and is_instance_valid(am) and am.has_method("_is_innate_ability") \
			and am._is_innate_ability(ability)
		var unlimited: bool = "npc_unlimited_resources" in character and character.npc_unlimited_resources
		if innate or unlimited:
			entry["innate"] = innate
		else:
			costs = AbilityManager.school_costs_for(ability)
			# A new Concentration cast ends the held one, so the slot counts
			# held focus as available (AbilityManager._check_ability_usable).
			entry["concentration"] = ability.is_concentration()
	entry["costs"] = costs

# Builds a unified list of display entries covering inventory.items, hand-equipped
# weapons/abilities, and stowed weapons/abilities. Abilities are deduped by ability_id
# so the same ability in both hands collapses to one slot with hand="Both".
func _build_inventory_entries(inventory) -> Array:
	var entries: Array = []

	# 1. Dictionary items. Skip ghost dict entries for hand-slot equipment — those
	# are also represented by a WeaponShape/AbilityShape in main_hand/off_hand/stowed
	# (TopDownCharacterDatabase calls add_item AND equip_weapon_from_data for starter
	# weapons), and we don't want both rows.
	for i in range(inventory.items.size()):
		var item: Dictionary = inventory.items[i]
		var equip_slot: String = str(item.get("equip_slot", ""))
		if equip_slot == "Main Hand" or equip_slot == "Off Hand":
			continue
		var raw_stacks = item.get("num_stacks", 1)
		entries.append({
			"kind": "item",
			"display_name": item.get("display_name", item.get("id", "?")),
			"sprite_path": str(item.get("sprite_path", "")) if item.get("sprite_path") != null else "",
			"num_stacks": int(raw_stacks) if raw_stacks != null else 1,
			"equipped": bool(item.get("_equipped", false)),
			"hand": "",
			"source_index": i,
			"raw": item,
		})

	var main = inventory.main_hand_item
	var off = inventory.off_hand_item

	# 2. Abilities — dedupe by ability_id across stowed + hands
	var ability_entries: Dictionary = {}  # ability_id -> entry dict
	var ability_order: Array = []          # preserves first-seen order
	for shape in inventory.stowed_items:
		if shape is AbilityShape:
			_ensure_ability_entry(shape, ability_entries, ability_order, false, "")
	if main is AbilityShape:
		_ensure_ability_entry(main, ability_entries, ability_order, true, "Main")
	if off is AbilityShape:
		_ensure_ability_entry(off, ability_entries, ability_order, true, "Off")
	for aid in ability_order:
		entries.append(ability_entries[aid])

	# 3. Weapons — one entry per WeaponShape instance
	if main is WeaponShape:
		var hand_label = "Both" if main.is_two_handed() else "Main"
		entries.append(_make_weapon_entry(main, hand_label, true))
	if off is WeaponShape:
		entries.append(_make_weapon_entry(off, "Off", true))
	for shape in inventory.stowed_items:
		if shape is WeaponShape:
			entries.append(_make_weapon_entry(shape, "", false))

	return entries

func _ensure_ability_entry(node: AbilityShape, entries: Dictionary, order: Array, equipped: bool, hand: String) -> void:
	var aid: String = node.ability_id
	if not entries.has(aid):
		var icon_path: String = ""
		if node.raw_data is Dictionary and node.raw_data.has("icon"):
			icon_path = str(node.raw_data["icon"])
		entries[aid] = {
			"kind": "ability",
			"ability_id": aid,
			"display_name": node.display_name,
			"sprite_path": icon_path,
			"num_stacks": 1,
			"equipped": equipped,
			"hand": hand,
			"source_index": -1,
			"raw": node,
		}
		order.append(aid)
		return

	var entry: Dictionary = entries[aid]
	if equipped:
		entry["equipped"] = true
		if entry["hand"] == "":
			entry["hand"] = hand
		elif entry["hand"] != hand:
			entry["hand"] = "Both"

func _make_weapon_entry(node: WeaponShape, hand: String, equipped: bool) -> Dictionary:
	var sprite_path = node.sprite_path if "sprite_path" in node else ""
	return {
		"kind": "weapon",
		"display_name": node.display_name,
		"sprite_path": str(sprite_path) if sprite_path != null else "",
		"num_stacks": 1,
		"equipped": equipped,
		"hand": hand,
		"source_index": -1,
		"raw": node,
	}

func _create_item_slot(entry: Dictionary, panel_data: Dictionary) -> PanelContainer:
	var slot = PanelContainer.new()
	slot.custom_minimum_size = ITEM_SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.tooltip_text = preload("res://UI/ItemTooltip.gd").detail_text(entry)

	var bg = StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.2, 0.25, 0.8)
	bg.set_corner_radius_all(4)
	if entry.get("equipped", false):
		bg.set_border_width_all(2)
		bg.border_color = Color(1.0, 0.85, 0.2, 1.0)  # gold equipped highlight
	slot.add_theme_stylebox_override("panel", bg)

	# Icon, scaled to fit the slot
	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex_rect = TextureRect.new()
		tex_rect.texture = load(sprite_path)
		tex_rect.custom_minimum_size = ITEM_SLOT_SIZE
		tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# IGNORE_SIZE, never FIT_WIDTH_PROPORTIONAL. That mode derives the rect's
		# MINIMUM HEIGHT from the texture's aspect ratio, so custom_minimum_size
		# becomes a floor it sails straight past: item art is authored at wildly
		# different aspects (arrow.png is 21x128, so in a 40px-wide slot it
		# demanded 244px of height and stretched the whole inventory column;
		# greatsword 197px, longsword 178px). With IGNORE_SIZE the rect is
		# exactly ITEM_SLOT_SIZE and KEEP_ASPECT_CENTERED fits the art inside it,
		# which is what every call site here already intended. It also avoids the
		# 4.6 layout crash documented in QuestLogPanel._build_quest_block.
		tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tex_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(tex_rect)
	else:
		var label = Label.new()
		label.text = _get_entry_short_name(entry)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 9)
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(label)

	# Stack count badge
	var num_stacks: int = int(entry.get("num_stacks", 1))
	if num_stacks > 1:
		var stack_label = Label.new()
		stack_label.text = str(num_stacks)
		stack_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		stack_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		stack_label.add_theme_font_size_override("font_size", 10)
		stack_label.add_theme_color_override("font_color", Color.WHITE)
		stack_label.add_theme_color_override("font_shadow_color", Color.BLACK)
		stack_label.add_theme_constant_override("shadow_offset_x", 1)
		stack_label.add_theme_constant_override("shadow_offset_y", 1)
		stack_label.custom_minimum_size = ITEM_SLOT_SIZE
		stack_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(stack_label)

	# L/R activation markers — the MOUSE BUTTON that fires the slot, NOT the
	# anatomical hand: left-click drives the Main hand (character's right arm),
	# right-click drives the Off hand (left arm). The old anatomical letters
	# read as click bindings and pointed at the wrong button (playtest find:
	# "the inventory has an L, which would seem to indicate left clicking").
	var hand: String = entry.get("hand", "")
	if hand == "Main" or hand == "Both":
		slot.add_child(_make_hand_label("L", HORIZONTAL_ALIGNMENT_LEFT))
	if hand == "Off" or hand == "Both":
		slot.add_child(_make_hand_label("R", HORIZONTAL_ALIGNMENT_RIGHT))

	slot.set_meta("entry", entry)
	slot.set_meta("panel_data", panel_data)
	slot.gui_input.connect(_on_slot_gui_input.bind(slot))
	_forward_dnd(slot)
	return slot

func _make_hand_label(text: String, alignment: int) -> Label:
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = alignment
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.custom_minimum_size = ITEM_SLOT_SIZE
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _get_entry_short_name(entry: Dictionary) -> String:
	var n: String = entry.get("display_name", "?")
	if n.length() > 5:
		return n.substr(0, 4) + "."
	return n

# Player-facing item name: display_name, else the id with underscores spaced.
func _item_name(item_data: Dictionary) -> String:
	var n = item_data.get("display_name")
	if n != null and str(n) != "":
		return str(n)
	return str(item_data.get("id", "item")).replace("_", " ")

func _item_icon(item_data: Dictionary) -> Texture2D:
	var sprite_path = item_data.get("sprite_path", "")
	if sprite_path is String and not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		return load(sprite_path)
	return null

# ---------------------------------------------------------------------------
# Drag and Drop
# ---------------------------------------------------------------------------

# Godot starts a drag, and looks for a drop target, at the control under the
# cursor and climbs to its parents only through MOUSE_FILTER_PASS controls. The
# slots, grids and containers here are STOP, so the panel's own drag-and-drop
# methods below never ran. Each STOP control that can be under the cursor
# forwards to them instead, with the position moved into the panel's space.
func _forward_dnd(ctrl: Control) -> void:
	ctrl.set_drag_forwarding(_fwd_get_drag_data.bind(ctrl), _fwd_can_drop_data.bind(ctrl), _fwd_drop_data.bind(ctrl))

func _to_panel_local(ctrl: Control, pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * (ctrl.get_global_transform_with_canvas() * pos)

func _fwd_get_drag_data(at_position: Vector2, ctrl: Control):
	return _get_drag_data(_to_panel_local(ctrl, at_position))

func _fwd_can_drop_data(at_position: Vector2, data, ctrl: Control) -> bool:
	return _can_drop_data(_to_panel_local(ctrl, at_position), data)

func _fwd_drop_data(at_position: Vector2, data, ctrl: Control) -> void:
	_drop_data(_to_panel_local(ctrl, at_position), data)

func _get_drag_data(at_position: Vector2):
	var slot = _find_slot_at(at_position)
	if not slot:
		return null

	var entry: Dictionary = slot.get_meta("entry")
	var panel_data = slot.get_meta("panel_data")

	# Abilities are not draggable between characters
	if entry.get("kind", "") == "ability":
		return null

	set_drag_preview(_create_drag_preview_from_entry(entry))

	return {
		"source_character": panel_data["character"],
		"entry": entry,
		"source_panel": panel_data,
	}

func _create_drag_preview_from_entry(entry: Dictionary) -> Control:
	var sprite_path: String = str(entry.get("sprite_path", ""))
	if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
		var tex = TextureRect.new()
		tex.texture = load(sprite_path)
		tex.custom_minimum_size = ITEM_SLOT_SIZE
		tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		return tex
	var label = Label.new()
	label.text = entry.get("display_name", "Item")
	label.add_theme_font_size_override("font_size", 12)
	return label

func _can_drop_data(at_position: Vector2, data) -> bool:
	if data is not Dictionary:
		return false
	# Downtime portrait drags carry a source_character but no item entry.
	if not (data.get("entry") is Dictionary):
		return false
	var target_panel = _find_panel_at(at_position)
	if not target_panel:
		return false
	# The dead receive nothing: loot flows OUT of a corpse via Search Body,
	# never in — and a drop onto a dead member's row re-entered its own
	# inventory through add_stack, destroying the stack (review find).
	var target_char = target_panel["character"]
	if is_instance_valid(target_char) and target_char.has_method("is_alive") \
			and not target_char.is_alive():
		return false
	if data.has("source_character"):
		# Can't drop onto same character
		return target_char != data["source_character"]
	if data.has("source_chest"):
		# A corpse loot window must not feed the corpse's own party row.
		return data["source_chest"] != target_char
	if data.has("source_npc"):
		# Trade window's NPC side -> party member
		return target_char != data["source_npc"]
	return false

func _drop_data(at_position: Vector2, data) -> void:
	var target_panel = _find_panel_at(at_position)
	if not target_panel:
		return

	var target_char = target_panel["character"]
	var entry: Dictionary = data.get("entry", {})

	# Drop from a chest window: pull from chest_item.contents into target inventory.
	if data.has("source_chest"):
		var chest_item = data["source_chest"]
		if not is_instance_valid(chest_item):
			return
		if _refuse_during_trade(target_char, entry):
			return
		var item_dict: Dictionary = entry.get("raw", {})
		# Transfer first; only erase from the chest if the target accepted it
		# (full inventory shouldn't lose the dragged item).
		var transferred := false
		var stacks_val = item_dict.get("num_stacks", 1)
		var stacks_before: int = int(stacks_val) if stacks_val != null else 1
		if entry.get("kind", "") == "weapon":
			target_char.inventory.stow_weapon_from_data(item_dict)
			transferred = true
		else:
			# add_stack transfers the full num_stacks (add_item would only +1).
			transferred = target_char.inventory.add_stack(item_dict)
		if not transferred:
			# Full pack, but part of the stack may have merged into one carried
			# (add_stack writes the remainder back): report that take and redraw.
			var left_val = item_dict.get("num_stacks", 1)
			if (int(left_val) if left_val != null else 1) < stacks_before:
				CrimeManager.report(target_char, "loot", CrimeManager.loot_payload(chest_item))
				var partial_window = data.get("source_window")
				if partial_window != null and is_instance_valid(partial_window) and partial_window.has_method("_populate_grid"):
					partial_window._populate_grid()
			return
		# Law: the drag-take twin of ChestInventoryWindow's tap-take.
		CrimeManager.report(target_char, "loot", CrimeManager.loot_payload(chest_item))
		if chest_item.contents is Array:
			chest_item.contents.erase(item_dict)
		SfxManager.play_ui("chest_item_out")
		var src_window = data.get("source_window")
		if src_window != null and is_instance_valid(src_window) and src_window.has_method("_populate_grid"):
			src_window._populate_grid()
		return

	# Drop from a trade window's NPC grid OR from TownServicesPanel.
	# When source_npc is null we're in TownServicesPanel snapshot mode and
	# the source_window owns the persisted inventory.
	if data.has("source_npc"):
		var npc = data["source_npc"]
		var source_window = data.get("source_window")
		# The TradeWindow's own NPC side is the trade itself; a service card isn't.
		var from_trade: bool = is_instance_valid(source_window) and source_window is TradeWindow
		if not from_trade and _refuse_during_trade(target_char, entry):
			return

		# Snapshot mode: NPC isn't on this map. Pull from the persisted
		# snapshot via the source window. Enforce TradeWindow's value-balance
		# rule per-drop so players can't drain a service without giving first.
		if not is_instance_valid(npc):
			if source_window == null or not is_instance_valid(source_window):
				return
			if not source_window.has_method("remove_snapshot_item"):
				return
			var uid: String = str(data.get("snapshot_uid", ""))
			var region_id: String = str(data.get("snapshot_region", ""))
			if uid.is_empty() or region_id.is_empty():
				return
			# Value balance check (snapshot path).
			var item_cost: float = _entry_cost_for_balance(entry)
			if source_window.has_method("can_accept_value_loss") \
					and not source_window.can_accept_value_loss(uid, item_cost):
				_refuse_service_take(target_char, source_window, uid, entry, item_cost)
				return
			# The snapshot has no put-back, so check room before removing.
			var snap_raw = entry.get("raw", {})
			if snap_raw is Dictionary and not _inventory_can_take(target_char.inventory, snap_raw):
				_refuse_full(target_char, snap_raw)
				return
			var snap_item = source_window.remove_snapshot_item(uid, region_id, entry.get("source_index", -1))
			if not snap_item.is_empty():
				# The NPC's worn flag stays behind, as in _transfer_one_item.
				snap_item.erase("_equipped")
				# The whole snapshot stack moves (add_item would keep only one).
				target_char.inventory.add_stack(snap_item)
			return

		# Live NPC path. If the source window enforces a per-drop balance
		# (TownServicesPanel does), respect it. TradeWindow doesn't and the
		# call is a no-op safe-default.
		if source_window and is_instance_valid(source_window) and source_window.has_method("can_accept_value_loss"):
			# One unit moves from a live inventory, so check one unit's value.
			var item_cost_live: float = _entry_cost_for_balance(entry, true)
			var uid_live: String = str(data.get("snapshot_uid", ""))
			if not uid_live.is_empty() and not source_window.can_accept_value_loss(uid_live, item_cost_live):
				_refuse_service_take(target_char, source_window, uid_live, entry, item_cost_live)
				return
		match entry.get("kind", ""):
			"item":
				_transfer_one_item(npc, target_char, entry.get("source_index", -1))
			"weapon":
				_transfer_weapon(npc, target_char, entry.get("raw"))
		return

	# Drop from another party member (existing behavior).
	var source_char = data["source_character"]

	match entry.get("kind", ""):
		"item":
			_transfer_one_item(source_char, target_char, entry.get("source_index", -1))
		"weapon":
			_transfer_weapon(source_char, target_char, entry.get("raw"))

# Move one unit of the item at `index` between inventories. The target gets a
# copy first and the source loses it only if that worked, so a full target
# refuses the drop (add_item shows "Inventory full") instead of eating the item.
func _transfer_one_item(source_char, target_char, index: int) -> void:
	var src_inv = source_char.inventory
	var src_item: Dictionary = src_inv.get_item(index)
	if src_item.is_empty():
		return
	# A 1-count copy: the source's dict stays with the source's stack. The
	# worn flag stays behind too; the receiver hasn't put it on.
	var one: Dictionary = src_item.duplicate(true)
	one["num_stacks"] = 1
	one.erase("_equipped")
	# Handing over worn gear takes it off first, as Drop does, which is refused
	# while it is a pack holding more than its wearer could carry without it.
	# Asked before anything moves, so a refusal leaves both sides as they were.
	var worn: bool = src_item.get("_equipped", false)
	if worn and source_char.has_method("worn_capacity_problem"):
		var why: String = source_char.worn_capacity_problem(src_item, {}, 1)
		if why != "":
			source_char.notify("Too full to remove", Color(1.0, 0.75, 0.3), why)
			SfxManager.play_ui("trade_decline")
			return
	if not target_char.inventory.add_item(one):
		SfxManager.play_ui("trade_decline")
		return
	if worn:
		_unequip_item(source_char, index, src_item, 1)
	src_inv.remove_item(index)

# True if `inv` can hold every unit of `item`: a free slot, or enough room in
# matching stacks for the whole count (the way add_stack merges).
func _inventory_can_take(inv, item: Dictionary) -> bool:
	if inv.slots_used() < inv.max_slots:
		return true
	if not item.get("is_stackable", false):
		return false
	var ns = item.get("num_stacks", 1)
	var need: int = max(1, int(ns) if ns != null else 1)
	var ms = item.get("max_stack_size", 20)
	var max_stack: int = int(ms) if ms != null else 20
	var item_id := str(item.get("id", ""))
	for it in inv.items:
		if str(it.get("id", "")) == item_id:
			var cur = it.get("num_stacks", 1)
			need -= max(0, max_stack - (int(cur) if cur != null else 1))
	return need <= 0

# A drop the target can't hold: decline sound, and the inventory's add_failed,
# which gives party members the usual "Inventory full" notice and log line.
func _refuse_full(target_char, item: Dictionary) -> void:
	SfxManager.play_ui("trade_decline")
	target_char.inventory.add_failed.emit(item, "Inventory full")

# An open TradeWindow puts every party inventory back from its snapshot on
# Cancel, so an item taken from a chest or a service card meanwhile would
# vanish from both, and one dropped, thrown or used would come back while its
# copy stays on the ground (or its effect stays spent). Refuse those moves
# until the trade is closed. `verb` names the move in the log line.
func _refuse_during_trade(character, entry: Dictionary, verb: String = "take") -> bool:
	for w in get_tree().get_nodes_in_group("trade_window"):
		if not w.is_queued_for_deletion():
			SfxManager.play_ui("trade_decline")
			character.notify("Finish the trade first", Color(1.0, 0.6, 0.4),
				"%s can't %s the %s while a trade is open: accept or cancel it first." % [character.Name, verb, entry.get("display_name", "item")])
			return true
	return false

# A service NPC won't hand over goods until the player has traded them at
# least as much value (TownServicesPanel.can_accept_value_loss). Say so.
func _refuse_service_take(target_char, source_window, uid: String, entry: Dictionary, item_cost: float) -> void:
	SfxManager.play_ui("trade_decline")
	var raw = entry.get("raw")
	var item_name := _item_name(raw) if raw is Dictionary else str(entry.get("display_name", "item"))
	var log_text := "%s can't take the %s (%d gold) for nothing: drop goods of equal value on their card first." \
			% [target_char.Name, item_name, int(ceil(item_cost))]
	if source_window.has_method("get_credit"):
		# Credit = value already given beyond the baseline; say what's missing.
		var short: float = item_cost - float(source_window.get_credit(uid))
		log_text = "%s can't take the %s (%d gold): drop %d gold more in goods on their card first." \
				% [target_char.Name, item_name, int(ceil(item_cost)), max(1, int(ceil(short)))]
	target_char.notify("Trade goods first", Color(1.0, 0.6, 0.4), log_text)

func _entry_cost_for_balance(entry: Dictionary, one_unit: bool = false) -> float:
	## Cost lookup safe for both item dicts and WeaponShape Nodes. one_unit
	## prices a single item from a stack instead of the whole stack.
	if entry.get("kind", "") == "weapon":
		var w = entry.get("raw")
		if w != null and "cost" in w:
			return float(w.cost)
		return 0.0
	var raw = entry.get("raw", {})
	if raw is Dictionary:
		var stacks: int = 1 if one_unit else max(1, int(entry.get("num_stacks", 1)))
		return float(raw.get("cost", 0.0)) * stacks
	return 0.0

func _transfer_weapon(source_char, target_char, weapon) -> void:
	if weapon == null or not is_instance_valid(weapon):
		return
	var weapon_data = weapon.to_data()
	var src_inv = source_char.inventory
	if weapon == src_inv.main_hand_item:
		src_inv.unequip_hand("Main")
	elif weapon == src_inv.off_hand_item:
		src_inv.unequip_hand("Off")
	else:
		src_inv.stowed_items.erase(weapon)
		src_inv.emit_signal("weapon_unequipped", weapon)
	# A starting weapon's hidden hand dict leaves with it.
	src_inv.drop_hand_ghost(str(weapon_data.get("id", "")))
	weapon.queue_free()
	target_char.inventory.stow_weapon_from_data(weapon_data)

func _find_slot_at(pos: Vector2) -> PanelContainer:
	for panel_data in _character_panels:
		var grid: GridContainer = panel_data["inv_grid"]
		for child in grid.get_children():
			if child is PanelContainer and child.get_global_rect().has_point(get_global_transform() * pos):
				return child
	return null

func _find_panel_at(pos: Vector2) -> Dictionary:
	var global_pos = get_global_transform() * pos
	for panel_data in _character_panels:
		var container = panel_data["container"]
		if container.get_global_rect().has_point(global_pos):
			return panel_data
	return {}

# ---------------------------------------------------------------------------
# Right-click context menu
# ---------------------------------------------------------------------------

# Item options _on_item_menu_selected handles (Equip/Unequip are added by state).
const _ITEM_MENU_OPTIONS := ["Use", "Consume", "Throw", "Drop", "Drop All", "Split"]
# Menu options refused while a trade window is open (_refuse_during_trade),
# by entry kind, and how the refusal names them.
const _TRADE_LOCKED_OPTIONS := {
	"item": ["Equip", "Unequip", "Drop", "Drop All", "Split", "Use", "Consume", "Throw"],
	"weapon": ["Drop", "Throw"],
}
const _TRADE_LOCKED_VERBS := {"Drop All": "drop"}

func _on_slot_gui_input(event: InputEvent, slot: PanelContainer) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_show_item_context_menu(slot)
			get_viewport().set_input_as_handled()
		# Left clicks are NOT consumed here — they need to flow through
		# to _get_drag_data for drag-and-drop to work. The panel's
		# MOUSE_FILTER_STOP already prevents them from reaching the world.

func _show_item_context_menu(slot: PanelContainer) -> void:
	var entry: Dictionary = slot.get_meta("entry")
	var panel_data: Dictionary = slot.get_meta("panel_data")
	var character = panel_data["character"]

	var options: Array = []
	var kind: String = entry.get("kind", "")

	if kind == "item":
		var item_data: Dictionary = entry.get("raw", {})
		# Undeclared options: "Use" only when there is an ability to use
		# (arrows and bullets have none, and Use would just delete one).
		var default_opts: Array = ["Drop"]
		var use_id = item_data.get("use_ability", "")
		if use_id is String and not use_id.is_empty():
			default_opts.push_front("Use")
		var declared = item_data.get("interact_options")
		options = (declared if declared is Array else default_opts).duplicate()
		# Offer only what _on_item_menu_selected can carry out. This drops
		# "Open" (containers open from the world), "Pick Up" (items in the
		# inventory are never picked up), and "Inspect"/"Offer to Patron",
		# which have no handler. Equip/Unequip are re-added below by state.
		options = options.filter(func(o): return o in _ITEM_MENU_OPTIONS)
		# Inventory invariant: items can always be dropped.
		if not options.has("Drop"):
			options.append("Drop")
		# Stack drop controls: whole stack + a slider split.
		var ns_val = item_data.get("num_stacks", 1)
		var ns_count: int = int(ns_val) if ns_val != null else 1
		if ns_count > 1:
			if not options.has("Drop All"):
				options.append("Drop All")
			if not options.has("Split"):
				options.append("Split")
		# Only slots the character can wear (no "Shoulders" slot yet), and
		# exactly one of Equip/Unequip.
		var equip_slot: String = str(item_data.get("equip_slot", ""))
		if _EQUIP_SLOT_MAP.has(equip_slot):
			if item_data.get("_equipped", false):
				options.insert(0, "Unequip")
				# Throw/Use/Consume on a worn item would take the dict away
				# and leave the item (and what it grants) on the body.
				options = options.filter(func(o): return o in ["Unequip", "Drop"])
			else:
				options.insert(0, "Equip")
	elif kind == "weapon" or kind == "ability":
		# Pull declared interact_options off the weapon node first (e.g. "Throw",
		# "Drop"). "Sheathe"/"Equip"/"Stow" are synonyms for the state-dependent
		# entries appended below, so filter them out to avoid duplicates.
		var node = entry.get("raw")
		if kind == "weapon" and is_instance_valid(node) and node is WeaponShape:
			for opt in node.options:
				if opt in ["Sheathe", "Equip", "Stow"]:
					continue
				if not options.has(opt):
					options.append(opt)
		if entry.get("equipped", false):
			var hand: String = entry.get("hand", "")
			if hand == "Both":
				options.append("Stow Main")
				options.append("Stow Off")
				options.append("Stow Both")
			else:
				options.append("Stow")
		else:
			options.append("Equip to Main")
			options.append("Equip to Off")
		# Inventory invariant: weapons can always be dropped.
		if kind == "weapon" and not options.has("Drop"):
			options.append("Drop")

	if options.is_empty():
		return

	var menu = PopupMenu.new()
	for i in range(options.size()):
		menu.add_item(options[i], i)
	menu.id_pressed.connect(_on_item_menu_selected.bind(character, entry, options))

	if game_node:
		game_node.context_menu_open = true
	menu.popup_hide.connect(func(): game_node.call_deferred("set", "context_menu_open", false))

	add_child(menu)
	menu.popup(Rect2i(
		Vector2i(slot.get_screen_position() + Vector2(slot.size.x, 0)),
		Vector2i.ZERO
	))

func _on_item_menu_selected(id: int, character, entry: Dictionary, options: Array) -> void:
	SfxManager.play_ui("ui-click")
	var option_name = options[id] if id < options.size() else ""
	var kind: String = entry.get("kind", "")

	# Cancelling an open trade restores every party inventory from its
	# snapshot, so what changes hands, body or ground meanwhile would be
	# duplicated or desynced (worn gear and its conditions follow the body,
	# not the restored dicts). These wait until the trade is closed.
	if option_name in _TRADE_LOCKED_OPTIONS.get(kind, []):
		var verb: String = _TRADE_LOCKED_VERBS.get(option_name, option_name.to_lower())
		if _refuse_during_trade(character, entry, verb):
			return

	if kind == "item":
		var item_index: int = entry.get("source_index", -1)
		var item_data: Dictionary = entry.get("raw", {})
		match option_name:
			"Use":
				_use_item(character, item_index, item_data)
			"Consume":
				_consume_item(character, item_index, item_data)
			"Throw":
				_throw_item(character, item_index, item_data)
			"Drop":
				_drop_item(character, item_index, item_data)
			"Drop All":
				_drop_item_amount(character, item_index, item_data, int(item_data.get("num_stacks", 1)))
			"Split":
				_show_split_popup(character, item_index, item_data)
			"Equip":
				_equip_item(character, item_index, item_data)
			"Unequip":
				_unequip_item(character, item_index, item_data)
			_:
				print("Unhandled item option: ", option_name)
		return

	if kind == "weapon" or kind == "ability":
		match option_name:
			"Stow":
				var hand: String = entry.get("hand", "")
				if hand == "Main" or hand == "Off":
					character.inventory.stow_hand(hand)
			"Stow Main":
				character.inventory.stow_hand("Main")
			"Stow Off":
				character.inventory.stow_hand("Off")
			"Stow Both":
				character.inventory.stow_hand("Main")
				character.inventory.stow_hand("Off")
			"Equip to Main":
				_equip_shape_to_hand(character, entry, "Main")
			"Equip to Off":
				_equip_shape_to_hand(character, entry, "Off")
			"Throw":
				_throw_weapon(character, entry)
			"Drop":
				_drop_weapon(character, entry)
			_:
				print("Unhandled shape option: ", option_name)

func _equip_shape_to_hand(character, entry: Dictionary, hand: String) -> void:
	var node = entry.get("raw")
	if node == null or not is_instance_valid(node):
		return
	if entry.get("kind", "") == "ability":
		# entry.raw is the canonical AbilityShape — spawn a copy for the hand
		character.inventory.equip_ability_to_hand(node, hand)
	else:  # weapon
		if node in character.inventory.stowed_items:
			character.inventory.stowed_items.erase(node)
		# The menu named the hand; don't let _pick_hand move it to the other.
		character.inventory.equip_item(node, hand, true)

# Paused inventory orders go onto the path node being placed, else onto the
# action queue. Returns false when the queue is full.
func _plan_item_action(character, callable: Callable, icon: Texture2D) -> bool:
	if character.path_input_handler and character.path_input_handler.is_placing_action():
		character.path_input_handler.assign_item_to_pending_node(
			ActionQueue.ActionType.CUSTOM,
			{"callable": callable},
			icon
		)
		return true
	return character.action_queue.queue_action(ActionQueue.ActionType.CUSTOM, {"callable": callable})

# Where `item_data` sits in the inventory now. A planned use captured the
# index at click time; the inventory may have shifted since. -1 if it's gone.
func _current_item_index(inventory, item_index: int, item_data: Dictionary) -> int:
	if is_same(inventory.get_item(item_index), item_data):
		return item_index
	for i in range(inventory.items.size()):
		if is_same(inventory.items[i], item_data):
			return i
	return -1

func _use_item(character, item_index: int, item_data: Dictionary) -> void:
	# When paused: plan it at the pending path node or queue it, like Consume.
	if PauseManager.is_paused:
		_plan_item_action(character, Callable(self, "_execute_use").bind(character, item_index, item_data),
			_item_icon(item_data))
		return
	_execute_use(character, item_index, item_data)

func _execute_use(character, item_index: int, item_data: Dictionary) -> void:
	var item_name := _item_name(item_data)
	var index := _current_item_index(character.inventory, item_index, item_data)
	if index < 0:
		character.notify("Item gone", Color(1.0, 0.6, 0.4),
			"%s can't use the %s: it is no longer in the inventory." % [character.Name, item_name])
		return
	var ability_data: Dictionary = {}
	var use_ability_id = item_data.get("use_ability", "")
	if use_ability_id is String and not use_ability_id.is_empty():
		ability_data = AbilityDatabase.get_ability_data(use_ability_id)
	if ability_data.is_empty() or not character.ability_manager:
		# Nothing to use: keep the item rather than deleting one silently.
		character.notify("Nothing happens", Color(1.0, 0.6, 0.4),
			"%s can't use the %s: it does nothing on its own." % [character.Name, item_name])
		return
	var ability_obj = Ability.from_dict(ability_data)
	# The item pays for the spell ("free"). A failed cast (including a law
	# refusal) is announced by the character, and the item is kept.
	if not character.ability_manager.use_ability(ability_obj, {"position": character.global_position, "free": true}):
		return
	character.inventory.remove_item(index)

func _consume_item(character, item_index: int, item_data: Dictionary) -> void:
	"""Use an item on the currently selected character (e.g. potions, food)."""
	# The recipient is whoever is selected at the click, not whoever happens
	# to be selected when a planned consume finally runs.
	var recipient = game_node.selected_character if game_node and game_node.selected_character else character
	# When paused: assign to pending action node or queue
	if PauseManager.is_paused:
		_plan_item_action(character, Callable(self, "_execute_consume").bind(character, recipient, item_index, item_data),
			_item_icon(item_data))
		return

	# Unpaused: consume immediately
	_execute_consume(character, recipient, item_index, item_data)

func _execute_consume(character, recipient, item_index: int, item_data: Dictionary) -> void:
	var item_name := _item_name(item_data)
	var index := _current_item_index(character.inventory, item_index, item_data)
	if index < 0:
		character.notify("Item gone", Color(1.0, 0.6, 0.4),
			"%s can't use the %s: it is no longer in the inventory." % [character.Name, item_name])
		return
	var target = recipient if is_instance_valid(recipient) else character
	if target.has_method("is_alive") and not target.is_alive():
		character.notify("Recipient is dead", Color(1.0, 0.6, 0.4),
			"%s can't give the %s to %s: they are dead." % [character.Name, item_name, target.Name])
		return
	# Same rules as a queued USE_ITEM: one heal for a healing item, and the
	# log line. False when nothing took effect (a failed cast is announced
	# by the character): keep the item, like _execute_use.
	if not ActionQueue.apply_consumable(character, target, item_data):
		return
	character.inventory.remove_item(index)

func _throw_item(character, item_index: int, item_data: Dictionary) -> void:
	if not game_node:
		return

	# When paused: assign to pending action node on tactical path, or queue to ActionQueue
	if PauseManager.is_paused:
		# Pending action node on the tactical path if there is one, else the queue
		_plan_item_action(character, Callable(self, "_execute_throw").bind(character, item_index, item_data),
			_item_icon(item_data))
		return

	# Unpaused: enter throw targeting mode on the character
	character.start_throw_targeting(item_index, item_data)

func _execute_throw(character, item_index: int, item_data: Dictionary, weapon_node = null) -> void:
	if not game_node:
		return

	# A planned weapon throw (see _throw_weapon) takes the weapon out of the
	# inventory only now. It may have been thrown, dropped or handed over since.
	if typeof(weapon_node) == TYPE_OBJECT:
		if not is_instance_valid(weapon_node) or not _remove_weapon_from_inventory(character.inventory, weapon_node):
			var weapon_name := str(item_data.get("name", "weapon"))
			character.notify("Weapon gone", Color(1.0, 0.6, 0.4),
				"%s can't throw the %s: it is no longer carried." % [character.Name, weapon_name])
			return
		weapon_node.queue_free()

	# item_index == -1 means the projectile data is already fully in item_data
	# (e.g. a weapon node already taken out of the inventory).
	var item: Dictionary
	if item_index >= 0:
		# Planned at click time; find the item again in case the inventory shifted.
		var index := _current_item_index(character.inventory, item_index, item_data)
		if index < 0:
			character.notify("Item gone", Color(1.0, 0.6, 0.4),
				"%s can't throw the %s: it is no longer in the inventory." % [character.Name, _item_name(item_data)])
			return
		item = character.inventory.remove_item(index)
	else:
		item = item_data
	if item.is_empty():
		return

	# Get mouse position in world space
	var mouse_pos = character.get_global_mouse_position()
	var direction = (mouse_pos - character.global_position).normalized()
	var speed = 600.0

	# Create a thrown projectile
	var projectile = {
		"type": "thrown_item",
		"item_data": item,
		"position": character.global_position,
		"velocity": direction * speed,
		"shooter": character,
		"max_range": ProceduralCharacter.THROW_RANGE,
		"distance_traveled": 0.0,
		"damage": item.get("damage", {"bludgeoning": 2}),
		"size": Vector2(8, 8),
	}

	# Use the game's projectile system if available
	if game_node.has_method("_add_thrown_projectile"):
		game_node._add_thrown_projectile(projectile)
	else:
		# Fallback: just drop the item at mouse position
		game_node.create_item(item.get("id", ""), mouse_pos)

# Ownership keys a dropped item carries back into the world. A stolen item
# stays the owner's property (owner_faction = stolen_from), so re-taking it
# is theft again.
#
# Quest-proof provenance rides along for the same reason: create_item rebuilds
# the item from canonical database data, so without these keys dropping a bounty
# head and picking it back up would launder away whose head it was.
func _drop_extras(item: Dictionary) -> Dictionary:
	var extras: Dictionary = {}
	var src: String = str(item.get("stolen_from", ""))
	if not src.is_empty():
		extras["owner_faction"] = src
		extras["stolen_from"] = src
	var origin = item.get("origin", null)
	if origin is Dictionary and not (origin as Dictionary).is_empty():
		extras["origin"] = (origin as Dictionary).duplicate(true)
		extras["origin_display_name"] = str(item.get("display_name", ""))
	return extras

func _drop_item(character, item_index: int, item_data: Dictionary) -> void:
	if not game_node:
		return

	# If item is currently equipped, unequip it first (refused when it is a
	# pack holding more than its wearer could carry without it)
	if item_data.get("_equipped", false) and not _unequip_item(character, item_index, item_data, 1):
		return

	var item = character.inventory.remove_item(item_index)
	if item.is_empty():
		return

	# Ownership survives the drop: without extras, drop-and-retake launders
	# a stolen item clean (create_item would rebuild it from canonical data).
	game_node.create_item(item.get("id", ""), character.global_position, 1, _drop_extras(item))

	if item.has("primary_damage_type"):
		SfxManager.play("sword-fall", character.global_position)

# Drop a chosen quantity from a stacked inventory item. Spawns a single world
# item carrying the dropped stack count.
func _drop_item_amount(character, item_index: int, item_data: Dictionary, amount: int) -> void:
	if not game_node:
		return
	var ns_val = item_data.get("num_stacks", 1)
	var total: int = int(ns_val) if ns_val != null else 1
	amount = clampi(amount, 1, total)
	# Equipped items are single (num_stacks 1), but guard anyway.
	if item_data.get("_equipped", false) and not _unequip_item(character, item_index, item_data, 1):
		return
	var item = character.inventory.remove_amount(item_index, amount)
	if item.is_empty():
		return
	var world_item = game_node.create_item(item.get("id", ""), character.global_position, 1, _drop_extras(item))
	# create_item's stack_count is overwritten by _apply_item_data, so set the
	# dropped count after it exists in the world.
	if world_item != null and amount > 1:
		world_item.stack_count = amount
		if world_item.has_method("_update_stack_label"):
			world_item._update_stack_label()
	if item.has("primary_damage_type"):
		SfxManager.play("sword-fall", character.global_position)

# Compact slider popup to drop part of a stack. "Drop" commits the slider value.
func _show_split_popup(character, item_index: int, item_data: Dictionary) -> void:
	var ns_val = item_data.get("num_stacks", 1)
	var total: int = int(ns_val) if ns_val != null else 1
	if total <= 1:
		_drop_item(character, item_index, item_data)
		return

	var popup := PopupPanel.new()
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.custom_minimum_size = Vector2(220, 0)
	popup.add_child(vbox)

	var title := Label.new()
	title.text = "Split %s" % str(item_data.get("display_name", item_data.get("id", "item")))
	vbox.add_child(title)

	var slider := HSlider.new()
	slider.min_value = 1
	slider.max_value = total
	slider.step = 1
	slider.value = int(max(1, total / 2))
	slider.custom_minimum_size = Vector2(200, 0)
	vbox.add_child(slider)

	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.text = "Drop %d of %d" % [int(slider.value), total]
	vbox.add_child(value_label)
	slider.value_changed.connect(func(v: float): value_label.text = "Drop %d of %d" % [int(v), total])

	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	buttons.add_theme_constant_override("separation", 8)
	vbox.add_child(buttons)

	var drop_btn := Button.new()
	drop_btn.text = "Drop"
	drop_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	drop_btn.pressed.connect(_drop_split.bind(character, item_index, item_data, slider, popup))
	buttons.add_child(drop_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = "Cancel"
	cancel_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	cancel_btn.pressed.connect(popup.queue_free)
	buttons.add_child(cancel_btn)

	if game_node:
		game_node.context_menu_open = true
	# Free on click-outside, and clear the world-input guard on any close path.
	popup.popup_hide.connect(popup.queue_free)
	popup.tree_exiting.connect(func(): game_node.call_deferred("set", "context_menu_open", false))

	add_child(popup)
	popup.popup_centered()

# Commit a split-drop from the popup, then close it.
func _drop_split(character, item_index: int, item_data: Dictionary, slider: HSlider, popup: PopupPanel) -> void:
	_drop_item_amount(character, item_index, item_data, int(slider.value))
	popup.queue_free()

# Remove a WeaponShape node from wherever it lives in the inventory
# (main hand, off hand, or stowed). Returns true if found and removed.
# A starting weapon's hidden hand dict leaves with it (Drop, and the planned
# or paused weapon throw).
func _remove_weapon_from_inventory(inventory, weapon) -> bool:
	if weapon == inventory.main_hand_item:
		inventory.unequip_hand("Main")
	elif weapon == inventory.off_hand_item:
		inventory.unequip_hand("Off")
	elif weapon in inventory.stowed_items:
		inventory.stowed_items.erase(weapon)
		# unequip_hand signals for the hands; a stowed weapon needs it too, or
		# its panel slot outlives the freed node (as _transfer_weapon does).
		inventory.emit_signal("weapon_unequipped", weapon)
	else:
		return false
	inventory.drop_hand_ghost(str(weapon.id))
	return true

func _throw_weapon(character, entry: Dictionary) -> void:
	if not game_node:
		return
	var node = entry.get("raw")
	if node == null or not is_instance_valid(node) or not (node is WeaponShape):
		return

	var weapon_data: Dictionary = node.to_data()
	# to_data() doesn't include id by default — make sure projectile/respawn keys work.
	weapon_data["id"] = node.id

	if PauseManager.is_paused:
		var icon: Texture2D = null
		var sprite_path = str(weapon_data.get("sprite_path", ""))
		if not sprite_path.is_empty() and ResourceLoader.exists(sprite_path):
			icon = load(sprite_path)

		# Paused: the weapon stays in the inventory until the planned throw
		# runs (as with the unpaused targeting flow), so cancelling the plan
		# by any route (Escape, a new path, a cleared node) never loses it.
		_plan_item_action(character, Callable(self, "_execute_throw").bind(character, -1, weapon_data, node), icon)
		return

	# Unpaused: hand the node to the character so it removes the weapon only
	# when the player commits the throw. Cancelling targeting leaves the
	# weapon in inventory.
	character.start_throw_targeting(-1, weapon_data, node)

func _drop_weapon(character, entry: Dictionary) -> void:
	if not game_node:
		return
	var node = entry.get("raw")
	if node == null or not is_instance_valid(node) or not (node is WeaponShape):
		return
	var weapon_id: String = node.id
	# Theft mark rides along, as for items: a fresh canonical copy would
	# launder a stolen weapon clean on drop-and-retake.
	var extras: Dictionary = _drop_extras({"stolen_from": node.stolen_from})
	if not _remove_weapon_from_inventory(character.inventory, node):
		return
	node.queue_free()
	game_node.create_item(weapon_id, character.global_position, 1, extras)
	SfxManager.play("sword-fall", character.global_position)

const EquipmentEffects = preload("res://Items/equipment_effects.gd")

# Map equip_slot strings to EquipmentShape.EquipmentSlot enum values
const _EQUIP_SLOT_MAP: Dictionary = {
	"Head": 0,   # EquipmentShape.EquipmentSlot.HEAD
	"Torso": 1,  # EquipmentShape.EquipmentSlot.TORSO
	"Back": 2,   # EquipmentShape.EquipmentSlot.BACK
	"Legs": 3,   # EquipmentShape.EquipmentSlot.LEGS
	"Feet": 4,   # EquipmentShape.EquipmentSlot.FEET
	"Cape": 2,   # capes/cloaks occupy the BACK slot
}

func _equip_item(character, item_index: int, item_data: Dictionary) -> void:
	"""Equip an equipment item from inventory onto the character."""
	# Corpses don't dress: the death-time _equipped strip exists so looted
	# armor doesn't auto-equip on the receiver's next load, and re-marking a
	# corpse's dict here would undo it (review find).
	if character != null and character.has_method("is_alive") and not character.is_alive():
		return
	var equip_slot: String = item_data.get("equip_slot", "")
	if equip_slot.is_empty() or equip_slot not in _EQUIP_SLOT_MAP:
		character.notify("Can't wear that", Color(1.0, 0.6, 0.4),
			"%s can't wear the %s: there is no slot for it." % [character.Name, _item_name(item_data)])
		return

	# Unequip whatever is currently in that slot first, returning it to inventory
	var slot_enum: int = _EQUIP_SLOT_MAP[equip_slot]
	# A worn pack displaced by this item (capes share its slot) must leave
	# room for everything carried.
	var current: Dictionary = _worn_in_slot(character, slot_enum)
	if not current.is_empty() and current != item_data and character.has_method("worn_capacity_problem"):
		var why: String = character.worn_capacity_problem(current, item_data, 0)
		if why != "":
			character.notify("Too full to swap", Color(1.0, 0.75, 0.3), why)
			SfxManager.play_ui("trade_decline")
			return
	_unequip_current_in_slot(character, slot_enum)

	# Equip the new item
	if character.has_method("equip_equipment"):
		character.equip_equipment(item_data)

	# Mark this inventory item as equipped
	item_data["_equipped"] = true

	if not current.is_empty() and current != item_data:
		var lost := EquipmentEffects.describe_worn(current)
		if not lost.is_empty():
			GameLog.add_entry("%s takes off the %s and loses %s." % [character.Name, EquipmentEffects.item_name(current), ", ".join(lost)])

	# Say what it does while worn (Shrouded, +10 inventory slots...).
	var fx := EquipmentEffects.describe_worn(item_data)
	if not fx.is_empty():
		character.notify(fx[0], Color(0.7, 0.9, 1.0),
			"%s puts on the %s: %s while worn." % [character.Name, EquipmentEffects.item_name(item_data), ", ".join(fx)])

	# Refresh UI to show the change
	_refresh_all_inventories()

func _unequip_item(character, item_index: int, item_data: Dictionary, leaving: int = 0) -> bool:
	"""Unequip an equipped item, keeping it in inventory. False (with a notice)
	when it is a worn pack and what is carried wouldn't fit without it; `leaving`
	counts items about to leave the inventory too (a Drop takes the pack itself)."""
	var equip_slot: String = item_data.get("equip_slot", "")
	if equip_slot.is_empty() or equip_slot not in _EQUIP_SLOT_MAP:
		return true

	if character.has_method("worn_capacity_problem"):
		var why: String = character.worn_capacity_problem(item_data, {}, leaving)
		if why != "":
			character.notify("Too full to remove", Color(1.0, 0.75, 0.3), why)
			SfxManager.play_ui("trade_decline")
			return false

	var slot_enum: int = _EQUIP_SLOT_MAP[equip_slot]
	if character.has_method("unequip_slot"):
		character.unequip_slot(slot_enum)

	# Clear equipped flag on the inventory item
	item_data["_equipped"] = false

	var fx := EquipmentEffects.describe_worn(item_data)
	if not fx.is_empty():
		GameLog.add_entry("%s takes off the %s and loses %s." % [character.Name, EquipmentEffects.item_name(item_data), ", ".join(fx)])

	# Refresh UI
	_refresh_all_inventories()
	return true

## The inventory dict worn in `slot_enum`, or {} when the slot is empty.
func _worn_in_slot(character, slot_enum: int) -> Dictionary:
	for item in character.inventory.items:
		if item.get("_equipped", false) and _EQUIP_SLOT_MAP.get(str(item.get("equip_slot", "")), -1) == slot_enum:
			return item
	return {}

func _unequip_current_in_slot(character, slot_enum: int) -> void:
	"""If something is already equipped in the given slot, clear its _equipped flag."""
	# Find any inventory item marked as equipped in this slot
	for item in character.inventory.items:
		if item.get("_equipped", false):
			var item_slot_str: String = item.get("equip_slot", "")
			if _EQUIP_SLOT_MAP.get(item_slot_str, -1) == slot_enum:
				item["_equipped"] = false
				break

func _refresh_all_inventories() -> void:
	"""Refresh all character inventory displays."""
	for panel_data in _character_panels:
		_refresh_inventory(panel_data)

# ---------------------------------------------------------------------------
# Inventory change callback
# ---------------------------------------------------------------------------

func _on_inventory_changed(_payload, panel_data: Dictionary) -> void:
	_refresh_inventory(panel_data)

func _on_active_weapon_changed(_weapon, _hand, panel_data: Dictionary) -> void:
	_refresh_inventory(panel_data)

# add_stack can merge part of a stack into existing ones and then run out of
# slots, emitting only add_failed: the merged counts still need showing.
func _on_inventory_add_failed(_item_data, _reason, panel_data: Dictionary) -> void:
	_refresh_inventory(panel_data)

# ---------------------------------------------------------------------------
# Tab toggle with slide tween
# ---------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_TAB:
			_toggle_panel()
			get_viewport().set_input_as_handled()



func _toggle_panel() -> void:
	if _tween and _tween.is_running():
		_tween.kill()

	panel_visible = not panel_visible
	var target_x: float = _shown_x if panel_visible else _hidden_x

	_tween = create_tween()
	_tween.tween_property(self, "offset_left", target_x, SLIDE_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	SfxManager.play_ui("ui-navigation")

	# Suppress the visibility signal while downtime mode is force-hiding us,
	# so the TownServicesPanel (which mirrors this signal) doesn't think the
	# player pressed Tab and start animating its own slide as well.
	if not _in_downtime_hide:
		emit_signal("panel_visibility_changed", panel_visible)

# ---------------------------------------------------------------------------
# Per-frame updates (MP bars etc.)
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	for data in _character_panels:
		var character = data["character"]
		if not is_instance_valid(character):
			continue

		# Selection highlight
		var container = data["container"]
		if game_node:
			if game_node.primary_selected == character:
				container.modulate = Color(1.0, 1.0, 1.0, 1.0)
			elif game_node.is_character_selected(character):
				container.modulate = Color(0.8, 0.9, 1.0, 1.0)
			else:
				container.modulate = Color(0.6, 0.6, 0.6, 1.0)

		# Red-tint the portrait when the character is dead
		var icon: TextureRect = data.get("icon")
		if icon:
			icon.modulate = Color(1.0, 0.3, 0.3, 1.0) if not character.is_alive() else Color.WHITE

		# WAIT badge tracks the hold flag (set via T or the context menu)
		var wicon: TextureRect = data.get("wait_icon")
		if wicon:
			wicon.visible = ("hold_position" in character) and character.hold_position \
				and character.is_alive()

		# Update the single character HP bar
		_update_health_bar(data, character)
		_update_stress_bar(data, character)

		# Update conditions display
		_update_conditions(data, character)

		_update_resource_bars(data, character)
		_update_footsteps(data, character, _delta)
		_update_ability_slots(data, character)

func _update_health_bar(data: Dictionary, character) -> void:
	var bar: ProgressBar = data["health_bar"]
	var fill_style: StyleBoxFlat = data["health_fill"]
	var max_hp: int = max(1, character.max_health)
	var pct: float = float(character.current_health) / float(max_hp)
	bar.value = pct * 100.0
	if pct <= HP_LOW_THRESHOLD:
		fill_style.bg_color = HP_COLOR_LOW
	elif pct <= HP_MID_THRESHOLD:
		fill_style.bg_color = HP_COLOR_MID
	else:
		fill_style.bg_color = HP_COLOR_FULL
	# Numbers on the label and the bar's tooltip; only touch them on change.
	var hp_label: Label = data.get("hp_label")
	var hp_text := "HP %d/%d" % [character.current_health, character.max_health]
	if hp_label and hp_label.text != hp_text:
		hp_label.text = hp_text
		bar.tooltip_text = hp_text


func _update_stress_bar(data: Dictionary, character) -> void:
	if not data.has("stress_bar"):
		return
	var bar: ProgressBar = data["stress_bar"]
	if not is_instance_valid(bar):
		return
	var cap: int = max(1, int(character.max_stress)) if "max_stress" in character else 1
	var cur: int = int(character.stress) if "stress" in character else 0
	bar.value = clamp(float(cur) / float(cap) * 100.0, 0.0, 100.0)
	# Show the numbers and where breakdown rolls start. The cap follows Will,
	# so the same fill means different amounts on different characters.
	var stress_label: Label = data.get("stress_label")
	var stress_text := "Stress %d/%d" % [cur, cap]
	if stress_label == null or stress_label.text == stress_text:
		return
	stress_label.text = stress_text
	var danger: int = int(ceil(cap * ProceduralCharacter.STRESS_DANGER_RATIO))
	if danger < cap:
		bar.tooltip_text = "%s\nFrom %d up, every stress gain risks a breakdown (Will save); at %d a breakdown is certain." % [stress_text, danger, cap]
	else:
		bar.tooltip_text = "%s\nAt %d a breakdown is certain." % [stress_text, cap]
	var stress_fill: StyleBoxFlat = data.get("stress_fill")
	if stress_fill:
		stress_fill.bg_color = STRESS_DANGER_COLOR if cur >= danger else STRESS_COLOR


# --- Footstep noise readout ---
# "<Quiet|Normal|Loud> steps" on the right of the HP row, with the breakdown
# (floor, boots, gear, race, sneaking, how far a step carries) in its tooltip.
# The numbers are ProceduralCharacter.footstep_noise and
# HearingManager.audible_radius, the same calculation the step itself sends
# to HearingManager, so the readout is what NPCs hear.
const FOOTSTEP_REFRESH_SEC := 0.25
const FOOTSTEP_TIER_COLORS := {
	"Quiet": Color(0.55, 0.85, 1.0),
	"Normal": Color(1.0, 0.9, 0.45),
	"Loud": Color(1.0, 0.5, 0.35),
}

func _add_footsteps_label(data: Dictionary, row: Control) -> void:
	var lbl := Label.new()
	lbl.add_theme_font_size_override("font_size", 9)
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# PASS: its own tooltip shows, and clicks still pass on.
	lbl.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(lbl)
	data["noise_label"] = lbl
	data["_noise_t"] = 0.0

func _update_footsteps(data: Dictionary, character, delta: float) -> void:
	var lbl = data.get("noise_label")
	if lbl == null or not is_instance_valid(lbl):
		return
	data["_noise_t"] = float(data.get("_noise_t", 0.0)) - delta
	if data["_noise_t"] > 0.0:
		return
	data["_noise_t"] = FOOTSTEP_REFRESH_SEC
	# Nobody hears footsteps on the world map, and the dead don't walk.
	var on_world_map: bool = game_node != null and game_node.current_map_data.get("is_world_map", false)
	if on_world_map or not character.is_alive() or not character.has_method("footstep_noise"):
		lbl.text = ""
		lbl.tooltip_text = ""
		return
	var noise: Dictionary = character.footstep_noise()
	var tier: String = HearingManager.loudness_tier(float(noise["loudness"]))
	var text := "%s steps" % tier
	if lbl.text != text:
		lbl.text = text
		lbl.add_theme_color_override("font_color", FOOTSTEP_TIER_COLORS.get(tier, Color.WHITE))
	var tip := _footsteps_tooltip(noise, tier)
	if lbl.tooltip_text != tip:
		lbl.tooltip_text = tip

func _footsteps_tooltip(noise: Dictionary, tier: String) -> String:
	var loudness: float = noise["loudness"]
	var tile := float(GridManager.TILE_SIZE)
	var lines := PackedStringArray()
	lines.append("Footsteps: %s. Heard about %.1f tiles away in the open, %.1f through a wall (normal hearing)." % [
		tier, HearingManager.audible_radius(loudness) / tile, HearingManager.audible_radius(loudness, 1.0, 1) / tile])
	lines.append("Floor: %s %.2f, %s" % [noise["floor_name"], float(noise["floor_base"]),
		"in boots" if noise["boots"] else "bare feet x0.5"])
	var gear: float = noise["gear"]
	if gear > 0.0:
		var parts := PackedStringArray()
		for g in noise["gear_items"]:
			parts.append("%s %.2f" % [g[0], float(g[1])])
		lines.append("Gear: +%.2f (%s)" % [gear, ", ".join(parts)])
	if not is_equal_approx(float(noise["race_mult"]), 1.0):
		lines.append("Race tread: x%.1f" % float(noise["race_mult"]))
	if float(noise["sneak_mult"]) < 1.0:
		lines.append("Sneaking: x%.1f" % float(noise["sneak_mult"]))
	# (floor x footwear + gear) x race x sneaking, as ProceduralCharacter.footstep_noise
	var sum_text := "%.2f" % (float(noise["floor_base"]) * float(noise["footwear_mult"]))
	if gear > 0.0:
		sum_text += " + %.2f" % gear
	var mult: float = float(noise["race_mult"]) * float(noise["sneak_mult"])
	if is_equal_approx(mult, 1.0):
		lines.append("Per step: %s" % ("%.2f" % loudness if gear <= 0.0 else "%s = %.2f" % [sum_text, loudness]))
	else:
		lines.append("Per step: (%s) x %.2f = %.2f" % [sum_text, mult, loudness])
	return "\n".join(lines)


# Build one TextureProgressBar per school resource for which the character has
# tier > 0. Returns a list of dicts the per-frame updater consumes.
## `row` is an HFlowContainer (it wraps school groups to a second line rather
## than widening the panel); typed as the shared Container base so the pip
## grouping below doesn't care which of the two it is handed.
func _build_resource_bars(character, row: Container) -> Array:
	# One pip (TextureRect) per point of the resource's current maximum.
	# Pips are coloured by the school's tint when "filled" and grey when empty,
	# so a Holy:2 character with devotion=1 sees [filled][grey] devotion icons.
	# Pips for the same school are grouped in their own inner HBox so they sit
	# together; schools are then laid out side by side in `row`.
	var bars: Array = []
	for entry in SCHOOL_RESOURCES:
		var school: String = entry["school"]
		var tier: int = int(character.traits.get(school, 0))
		if tier <= 0:
			continue
		var icon_path: String = entry["icon"]
		if not ResourceLoader.exists(icon_path):
			continue
		var tex: Texture2D = _get_scaled_icon(icon_path, RESOURCE_ICON_SIZE)
		if tex == null:
			continue
		var resource_name: String = entry["resource"]
		var pip_box := HBoxContainer.new()
		pip_box.add_theme_constant_override("separation", 2)
		pip_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(pip_box)
		var pips: Array = _rebuild_pips(pip_box, tex, _resource_max(character, resource_name), entry["color"], int(character.get(resource_name)), resource_name, school, character)
		bars.append({
			"pip_box": pip_box,
			"pips": pips,
			"icon": tex,
			"resource": resource_name,
			"school": school,
			"color": entry["color"],
		})
	return bars


# Creates `max_val` TextureRect pips inside `pip_box`, returns the array.
# Pips with index < current are tinted with the school colour (focus held by
# Concentration in lavender, after the spendable ones); the rest grey.
func _rebuild_pips(pip_box: HBoxContainer, tex: Texture2D, max_val: int, color: Color, current: int, resource_name: String, school: String, character = null) -> Array:
	for child in pip_box.get_children():
		child.queue_free()
	var held: int = _held_amount(character, resource_name)
	var pips: Array = []
	for i in range(max(0, max_val)):
		var pip := TextureRect.new()
		pip.texture = tex
		pip.custom_minimum_size = RESOURCE_ICON_SIZE
		pip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		pip.mouse_filter = Control.MOUSE_FILTER_STOP
		pip.tooltip_text = _resource_tooltip(resource_name, school, current, max_val, character)
		pip.modulate = _pip_color(i, current, held, color)
		_forward_dnd(pip)
		pip_box.add_child(pip)
		pips.append(pip)
	return pips


# How much of a pool is held and can't be spent: focus held by Concentration.
func _held_amount(character, resource_name: String) -> int:
	if character != null and resource_name == "focus" and "concentration_locked_focus" in character:
		return int(character.concentration_locked_focus)
	return 0


# Spendable pips in the school colour, then held pips in lavender (the
# Concentration colour), then empty grey.
func _pip_color(i: int, current: int, held: int, color: Color) -> Color:
	if i < current - held:
		return color
	if i < current:
		return Color(0.8, 0.65, 1.0)
	return Color(0.3, 0.3, 0.3, 1.0)


# "\n2 held by Concentration: Gravity Well" for the focus pip tooltip, else "".
func _held_tooltip(character, resource_name: String) -> String:
	var held: int = _held_amount(character, resource_name)
	if held <= 0 or not character.has_method("get_concentration_names"):
		return ""
	return "\n%d held by Concentration: %s" % [held, ", ".join(character.get_concentration_names())]


# Per-school resource cap (mirrors max_<resource> getters on ProceduralCharacter,
# falls back to the trait tier if those properties don't exist on whatever node
# we're handed).
func _resource_max(character, resource_name: String) -> int:
	var max_prop := "max_" + resource_name
	if max_prop in character:
		return int(character.get(max_prop))
	for entry in SCHOOL_RESOURCES:
		if String(entry["resource"]) == resource_name:
			return int(character.traits.get(entry["school"], 0))
	return 0


# How each pool fills, from ProceduralCharacter (_tick_school_resources, the
# damage and ally-witness hooks, soul binding), shown under the pip count.
const RESOURCE_RULES := {
	"adrenaline": "Recovers over time (Constitution). +1 when hit or when a nearby ally is hurt.",
	"focus": "Recovers over time (Intelligence). -1 when hit; a hit that would dip into focus held by Concentration ends the spell instead.",
	"harmony": "Recovers over time (Will).",
	"devotion": "Recovers over time (Will).",
	"souls": "Gained by binding the souls of the dead; extras become Soul items.",
}

# The pip count, any focus held by Concentration (_held_tooltip), then how
# the pool fills.
func _resource_tooltip(resource_name: String, school: String, current: int, max_val: int, character = null) -> String:
	var tip := "%s (%s) %d/%d" % [resource_name.capitalize(), school, current, max_val] + _held_tooltip(character, resource_name)
	if RESOURCE_RULES.has(resource_name):
		tip += "\n" + RESOURCE_RULES[resource_name]
	return tip


# Returns a downsampled copy of an icon at the requested size, cached so we
# don't reload + resize on every panel rebuild. Returns null if the source
# can't be read as an Image (e.g. a streaming-only texture).
func _get_scaled_icon(icon_path: String, target: Vector2) -> Texture2D:
	var key := "%s@%dx%d" % [icon_path, int(target.x), int(target.y)]
	if _resource_icon_cache.has(key):
		return _resource_icon_cache[key]
	var raw: Texture2D = load(icon_path)
	if raw == null:
		return null
	var img: Image = raw.get_image()
	if img == null:
		return raw
	img.resize(int(target.x), int(target.y), Image.INTERPOLATE_LANCZOS)
	var scaled := ImageTexture.create_from_image(img)
	_resource_icon_cache[key] = scaled
	return scaled


# Schools the character has a tier in, i.e. the ones that get a pip row.
func _resource_schools(character) -> Array:
	var schools: Array = []
	for entry in SCHOOL_RESOURCES:
		if int(character.traits.get(entry["school"], 0)) > 0:
			schools.append(entry["school"])
	return schools


func _update_resource_bars(data: Dictionary, character) -> void:
	# A school gained or lost mid-run (patron reward, downtime trait, vow)
	# needs its own pip row, so rebuild the row when the set changes.
	var schools: Array = _resource_schools(character)
	if schools != data.get("resource_schools", []):
		var row: Container = data["resource_row"]
		for child in row.get_children():
			row.remove_child(child)
			child.queue_free()
		data["resource_bars"] = _build_resource_bars(character, row)
		data["resource_schools"] = schools
		call_deferred("_warn_if_too_wide")
		return
	var bars: Array = data.get("resource_bars", [])
	for entry in bars:
		var resource_name: String = entry["resource"]
		var school: String = entry["school"]
		var current: int = int(character.get(resource_name))
		var max_val: int = _resource_max(character, resource_name)
		var pips: Array = entry["pips"]
		# Max can grow mid-run (vow_holy_bonus from Chastity, saint-day bonuses,
		# etc.) so rebuild the pip row if the displayed count is stale.
		if pips.size() != max_val:
			pips = _rebuild_pips(entry["pip_box"], entry["icon"], max_val, entry["color"], current, resource_name, school, character)
			entry["pips"] = pips
			continue
		var color: Color = entry["color"]
		var held: int = _held_amount(character, resource_name)
		for i in range(pips.size()):
			var pip: TextureRect = pips[i]
			pip.modulate = _pip_color(i, current, held, color)
			pip.tooltip_text = _resource_tooltip(resource_name, school, current, max_val, character)

# Grey an ability slot while the character can't pay its school cost, so an
# unaffordable spell is visible before the cast fails. Costs were worked out
# at refresh (_set_ability_costs); free abilities have none and stay lit.
func _update_ability_slots(data: Dictionary, character) -> void:
	if not character.has_method("_get_character_resource"):
		return
	for a in data.get("ability_slots", []):
		var slot = a["slot"]
		if not is_instance_valid(slot):
			continue
		var affordable := true
		var costs: Dictionary = a["costs"]
		for res in costs:
			var have = character._get_character_resource(res)
			if res == "focus" and a.get("concentration", false) and "concentration_locked_focus" in character:
				have += character.concentration_locked_focus
			if have < int(costs[res]):
				affordable = false
				break
		var tint := Color.WHITE if affordable else Color(0.55, 0.55, 0.55)
		if slot.modulate != tint:
			slot.modulate = tint

func _update_conditions(data: Dictionary, character) -> void:
	var cond_container: HBoxContainer = data["condition_container"]
	var cm = character.get_node_or_null("ConditionManager")
	if not cm:
		return

	var conditions: Dictionary = cm.conditions
	var existing_children = cond_container.get_children()

	# The header is a fixed-width row, so the pip count has to be bounded or a
	# heavily-conditioned character pushes it past PANEL_WIDTH. Show the first
	# MAX_COND_PIPS and fold the rest into a "+N" tag, which is strictly better
	# than letting them silently clip off the edge: the player can still see that
	# more are active, and the tooltip on each pip carries the detail.
	var all_ids: Array = conditions.keys()
	var overflow: int = maxi(0, all_ids.size() - MAX_COND_PIPS)
	var cond_ids: Array = all_ids.slice(0, mini(all_ids.size(), MAX_COND_PIPS))

	# The name label shares the header row with these pips, so re-fit it whenever
	# the pip count changes (a condition landing or expiring mid-fight resizes
	# the space the name is allowed to occupy).
	_fit_name_column(data, cond_ids.size(), overflow > 0)

	# Quick check: if count matches and IDs match, just update tooltips
	var expected_children: int = cond_ids.size() + (1 if overflow > 0 else 0)
	var needs_rebuild := existing_children.size() != expected_children
	if not needs_rebuild:
		for i in range(cond_ids.size()):
			if i >= existing_children.size() or existing_children[i].get_meta("cond_id", "") != cond_ids[i]:
				needs_rebuild = true
				break

	if needs_rebuild:
		for child in existing_children:
			child.queue_free()
		for cond_id in cond_ids:
			var instance = conditions[cond_id]
			var cond_res = instance.condition
			var icon_tex = cond_res.icon if cond_res else null
			var tex_rect = TextureRect.new()
			tex_rect.custom_minimum_size = COND_ICON_SIZE
			tex_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tex_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tex_rect.mouse_filter = Control.MOUSE_FILTER_STOP
			if icon_tex and icon_tex is Texture2D:
				tex_rect.texture = icon_tex
			tex_rect.set_meta("cond_id", cond_id)
			_forward_dnd(tex_rect)
			cond_container.add_child(tex_rect)
		if overflow > 0:
			var more := Label.new()
			more.text = "+%d" % overflow
			more.add_theme_font_size_override("font_size", 10)
			more.tooltip_text = "%d more condition(s)" % overflow
			more.mouse_filter = Control.MOUSE_FILTER_STOP
			# Tagged so the ID-match check above treats it as a stable child
			# rather than seeing a mismatch and rebuilding the row every frame.
			more.set_meta("cond_id", "__overflow__")
			_forward_dnd(more)
			cond_container.add_child(more)

	# Update tooltips with current stacks/duration
	var time_manager = get_node_or_null("/root/TimeManager")
	# expires_at is on the absolute clock — comparing against the wrapping
	# intraday game_time would show garbage countdowns after any midnight.
	var game_time: float = time_manager.absolute_time() if time_manager else 0.0
	var children = cond_container.get_children()
	for i in range(children.size()):
		if i >= cond_ids.size():
			break
		var cond_id = cond_ids[i]
		var instance = conditions[cond_id]
		# Name, stacks, time left, suppressed, description: the same wording
		# as the world hover (ConditionInstance.get_tooltip_text).
		var tip: String = instance.get_tooltip_text(game_time)
		if children[i].tooltip_text != tip:
			children[i].tooltip_text = tip
		# Suppressed (the cloak's Invisible an attack broke): dimmed, as overhead.
		children[i].modulate.a = 0.4 if instance.is_suppressed else 1.0
	# The "+N" tag names the conditions it folds away.
	if overflow > 0 and children.size() > cond_ids.size():
		var hidden_names: PackedStringArray = []
		for cond_id in all_ids.slice(cond_ids.size()):
			var res = conditions[cond_id].condition
			hidden_names.append(res.display_name if res and res.display_name else str(cond_id))
		var more_tip := "Also: " + ", ".join(hidden_names)
		var tag = children[cond_ids.size()]
		# A condition landing past the shown pips doesn't rebuild the row (only
		# those are compared above), so keep the count in step with the list.
		var more_text := "+%d" % overflow
		if tag is Label and tag.text != more_text:
			tag.text = more_text
		if tag.tooltip_text != more_tip:
			tag.tooltip_text = more_tip
