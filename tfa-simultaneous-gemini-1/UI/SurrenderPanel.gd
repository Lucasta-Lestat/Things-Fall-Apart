# SurrenderPanel.gd — law/crime Phase 7 (docs/law_crime_stealth_plan.md).
# Player-initiated surrender: the decision that makes binary enforcement
# survivable without an arrest ladder. Pure-GDScript window (ReadableWindow
# pattern — no .tscn). Instantiated by Game._on_surrender_pressed; call
# try_open() after adding to the tree; it returns false (caller frees) when
# the counterparty refuses (implacable) — refusal is feedback, not a panel.
#
# Profiles come from laws.json surrender.*:
#   lawful     — ledger + return-goods + fine or jail, via CrimeManager.settle_with
#   predatory  — hand over ~rob_fraction of inventory value; truce; standing untouched
#   implacable — the authored line, Door.gd's refusal protocol; no panel
extends CanvasLayer

var game = null

var _faction: String = ""
var _profile: Dictionary = {}
var _panel: PanelContainer = null

## Pick the counterparty and open (or refuse). faction_override exists for
## tests and scripted moments; normally the faction is derived from nearby
## hostiles — largest outstanding ledger wins, nearest breaks the tie.
func try_open(faction_override: String = "") -> bool:
	_faction = faction_override if not faction_override.is_empty() else _pick_counterparty()
	if _faction.is_empty():
		return false
	_profile = LawDatabase.surrender_profile(_faction)
	var line: String = str(_profile.get("line", "..."))
	if not bool(_profile.get("accepts", false)):
		# Implacable: refusal IS the interaction. Door.gd:33-36's protocol.
		if game != null and ("party_chars" in game) and not game.party_chars.is_empty():
			var protagonist = game.party_chars[0]
			if is_instance_valid(protagonist):
				Globals.show_floating_text(line, protagonist.global_position, protagonist, Color.WHITE_SMOKE)
		GameLog.add_entry("Surrender refused: %s" % line)
		return false
	_build_panel(line)
	return true

func _pick_counterparty() -> String:
	if game == null:
		return ""
	var hostiles: Array = game.hostile_characters_near_party()
	if hostiles.is_empty():
		return ""
	var best_faction: String = ""
	var best_fine: int = -1
	for c in hostiles:
		var fid: String = str(c.faction_id)
		var fine: int = FactionDatabase.fine_owed(fid)
		if fine > best_fine:
			best_fine = fine
			best_faction = fid
	return best_faction

func _build_panel(line: String) -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -240.0
	_panel.offset_right = 240.0
	_panel.offset_top = -170.0
	_panel.offset_bottom = 170.0
	add_child(_panel)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	_panel.add_child(vbox)

	var faction_name: String = str(FactionDatabase.get_faction_data(_faction).get("name", _faction)) \
		if FactionDatabase.has_faction(_faction) else _faction
	_add_label(vbox, "Surrender — %s" % faction_name, 20)
	_add_label(vbox, "\"%s\"" % line, 14)

	var options: Array = _profile.get("options", [])
	if "rob" in options:
		var fraction: float = float(_profile.get("rob_fraction", 0.5))
		_add_label(vbox, "They want roughly %d%% of everything you carry." % int(fraction * 100.0), 14)
		_add_button(vbox, "Hand over your goods", func(): _do_rob(fraction))
		_add_button(vbox, "Refuse", func(): queue_free())
		return

	# Lawful: the books, the price, the alternatives.
	var records: Array = FactionDatabase.crime_records(_faction)
	var tallies: Dictionary = {}
	for record in records:
		if not bool(record.get("settled", false)):
			var display: String = str(record.get("display_name", "?"))
			tallies[display] = int(tallies.get(display, 0)) + 1
	var charge_parts: Array = []
	for display in tallies:
		charge_parts.append("%s ×%d" % [display, tallies[display]])
	_add_label(vbox, "Charges: %s" % (", ".join(charge_parts) if not charge_parts.is_empty() else "none on record"), 14)
	var fine: int = FactionDatabase.fine_owed(_faction)
	var days: int = FactionDatabase.jail_days_owed(_faction)
	_add_label(vbox, "Stolen goods will be returned in either case.", 13)
	if "pay_fine" in options:
		_add_button(vbox, "Pay the fine (%d gold)" % fine, func(): _do_settle("pay_fine"))
	if "serve_time" in options:
		_add_button(vbox, "Serve your sentence (%d days)" % days, func(): _do_settle("serve_time"))
	_add_button(vbox, "Withdraw", func(): queue_free())

func _add_label(parent: Node, text: String, size: int) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", size)
	parent.add_child(label)

func _add_button(parent: Node, text: String, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.pressed.connect(on_pressed)
	parent.add_child(button)

func _do_settle(mode: String) -> void:
	CrimeManager.settle_with(_faction, mode)
	_end_combat()
	queue_free()

# Items.json authors "cost": null on some entries — float(null) is a crash,
# so every cost read goes through here.
static func _entry_value(entry: Dictionary) -> float:
	var cost_value = entry.get("cost", 0.0)
	var stacks_value = entry.get("num_stacks", 1)
	var cost: float = float(cost_value) if (cost_value is float or cost_value is int) else 0.0
	var stacks: float = float(stacks_value) if (stacks_value is float or stacks_value is int) else 1.0
	return cost * stacks

func _do_rob(fraction: float) -> void:
	if game == null or not ("party_chars" in game):
		queue_free()
		return
	# ~fraction of total carried value by cost, taken greedily in inventory
	# order. Fast, humiliating, survivable — and often the right play.
	var total_value: float = 0.0
	for c in game.party_chars:
		if not is_instance_valid(c) or not ("inventory" in c) or c.inventory == null:
			continue
		for entry in c.inventory.items:
			if entry is Dictionary:
				total_value += _entry_value(entry)
	var to_take: float = total_value * fraction
	var taken: float = 0.0
	for c in game.party_chars:
		if taken >= to_take:
			break
		if not is_instance_valid(c) or not ("inventory" in c) or c.inventory == null:
			continue
		for i in range(c.inventory.items.size() - 1, -1, -1):
			if taken >= to_take:
				break
			var entry = c.inventory.items[i]
			if entry is Dictionary:
				taken += _entry_value(entry)
				c.inventory.items.remove_at(i)
	GameLog.add_entry("Robbed: goods worth ~%d handed over. They let you live." % int(taken))
	# A short truce, or the robbery is pointless — hostile_by_default
	# factions would re-acquire on the next AI tick. Standing untouched.
	var truce_seconds: float = float(LawDatabase.surrender_cfg().get("truce_seconds", 90.0))
	var until: float = TimeManager.absolute_time() + truce_seconds
	if "characters_in_scene" in game:
		for c in game.characters_in_scene:
			if not is_instance_valid(c) or str(c.faction_id) != _faction:
				continue
			var ai_node = c.get_node_or_null("AI")
			if ai_node != null and ("truce_until" in ai_node):
				ai_node.truce_until = until
	_end_combat()
	queue_free()

## Clear combat with functions that already exist — no new AI state. Anyone
## still genuinely hostile (and not under truce) re-acquires next tick; that
## self-correction is the point.
func _end_combat() -> void:
	if game == null or not ("characters_in_scene" in game):
		return
	for c in game.characters_in_scene:
		if not is_instance_valid(c) or c in game.party_chars:
			continue
		var ai_node = c.get_node_or_null("AI")
		if ai_node == null:
			continue
		if ai_node.current_target != null:
			ai_node._lose_target()
		ai_node._set_alertness_value(0.0)
