# res://Characters/Components/stats.gd
extends Node
class_name Stats

@export_group("Core Stats")
@export_range(0, 100) var intelligence: int = 50
@export_range(0, 100) var willpower: int = 50
@export_range(0, 100) var charisma: int = 50
@export_range(0, 100) var strength: int = 50
@export_range(0, 100) var dexterity: int = 50
@export_range(0, 100) var constitution: int = 50

@export_group("Combat Resources")
var max_hp: int
var _current_hp: int # Renamed to avoid conflict with setter name

var current_hp: int: # Property with getter/setter
	get: return _current_hp
	set(value):
		var old_hp = _current_hp
		_current_hp = clampi(value, 0, max_hp)
		if old_hp != _current_hp: # Only emit if value actually changed
			hp_changed.emit(_current_hp, max_hp)
		if _current_hp == 0 and old_hp > 0: # Emit only if HP just reached 0
			no_hp_left.emit()

@export var base_max_action_points: int = 4
var action_points_max_this_round: int = 4
var _current_action_points: int # Renamed

var current_action_points: int: # Property
	get: return _current_action_points
	set(value):
		var old_ap = _current_action_points
		_current_action_points = clampi(value, 0, action_points_max_this_round)
		if old_ap != _current_action_points:
			ap_changed.emit(_current_action_points, action_points_max_this_round)

@export_group("Traits")
@export var traits: Array[String] = []

signal hp_changed(current_hp, max_hp)
signal no_hp_left
signal ap_changed(current_ap, max_ap_this_round)
signal stats_initialized

func _enter_tree(): # Changed from _ready to ensure parent is available for name
	# Initial calculation of derived stats
	recalculate_derived_stats() # Max HP calculated here
	_current_hp = max_hp # Initialize HP directly to field
	action_points_max_this_round = base_max_action_points
	_current_action_points = action_points_max_this_round # Initialize AP directly to field
	
	# Emit initial signals for UI after a brief delay to allow UI to connect
	call_deferred("_emit_initial_signals")
	stats_initialized.emit() # Emit this early for character to use

func _emit_initial_signals():
	hp_changed.emit(_current_hp, max_hp)
	ap_changed.emit(_current_action_points, action_points_max_this_round)

func recalculate_derived_stats():
	max_hp = 50 + (constitution * 2) # Example: 50 base + 2 HP per Con point
	_current_hp = clampi(_current_hp if _current_hp != null else max_hp, 0, max_hp) # Ensure current_hp is valid
	
	var owner_name = "Owner"
	if get_parent() and get_parent().has_meta("character_name"): # Check if meta exists
		owner_name = get_parent().get_meta("character_name", get_parent().name)
	elif get_parent():
		owner_name = get_parent().name

	#print("Stats recalculated for %s: MaxHP=%d" % [owner_name, max_hp])

func get_stat_value(stat_name: String) -> int:
	match stat_name.to_lower():
		"intelligence", "int": return intelligence
		"willpower", "wil": return willpower
		"charisma", "cha": return charisma
		"strength", "str": return strength
		"dexterity", "dex": return dexterity
		"constitution", "con": return constitution
		_:
			printerr("Unknown stat requested: ", stat_name, " for ", get_parent().name if get_parent() else "Unknown Owner")
			return 0

func get_damage_bonus(stat_name_for_bonus: String) -> int:
	if stat_name_for_bonus.is_empty(): return 0 # No bonus if no stat defined
	var stat_val = get_stat_value(stat_name_for_bonus)
	return int(floor(stat_val / 20.0))

func add_trait(trait_name: String):
	if not trait_name in traits:
		traits.append(trait_name)
		#print("%s gained trait: %s" % [get_parent().name if get_parent() else "Owner", trait_name])

func remove_trait(trait_name: String):
	if trait_name in traits:
		traits.erase(trait_name)
		#print("%s lost trait: %s" % [get_parent().name if get_parent() else "Owner", trait_name])

func take_damage(amount: int):
	self.current_hp -= amount # Use property to trigger setter
	#print("%s took %d damage. HP: %d/%d" % [get_parent().name if get_parent() else "Owner", amount, _current_hp, max_hp])

func heal(amount: int):
	self.current_hp += amount # Use property

func use_ap(amount: int) -> bool:
	if _current_action_points >= amount:
		self.current_action_points -= amount # Use property
		return true
	return false

func reset_ap_for_new_round(max_ap_for_round: int):
	action_points_max_this_round = max_ap_for_round
	self.current_action_points = action_points_max_this_round # Use property

func get_current_ap() -> int:
	return _current_action_points

func get_max_ap_this_round() -> int:
	return action_points_max_this_round
