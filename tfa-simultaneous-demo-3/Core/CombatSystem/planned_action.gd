# res://Core/CombatSystem/planned_action.gd
class_name PlannedAction extends Resource

enum ActionType { IDLE, MOVE, ATTACK, SPELL_FIREBALL, SPELL_HEAL } # Ensure this matches Reaction.gd if used there

@export var type: ActionType = ActionType.IDLE
@export var caster_path: NodePath 
var caster_node: BattleCharacter # Typed for convenience

@export var target_node_path: NodePath 
var target_node: BattleCharacter # Typed

@export var target_position: Vector2 = Vector2.ZERO
	
@export var ap_cost: int = 1
@export var name: String = "Action"
@export var icon: Texture2D = null # For UI

@export_group("Skill Check & Effect")
@export var base_damage: int = 0
@export var base_heal: int = 0
@export var aoe_radius: float = 0.0
@export var relevant_stat_name: String = "" # e.g., "dexterity", "intelligence"
@export var damage_bonus_stat: String = "" # e.g., "strength", "intelligence" (also for heal bonus)
@export var action_domain: String = "default" # e.g., "weapon_attack_melee"
@export var is_piercing_damage: bool = false 
@export var spell_effect_details: Dictionary = {} # E.g. for spell-specific data not covered by base fields
@export var action_tags: Array[String] = [] # <--- ADDED: Generic traits like "Arcane", "Physical", "Targeted"

func _init(p_type: ActionType = ActionType.IDLE, p_caster: BattleCharacter = null, 
			p_ap_cost: int = 1, p_name: String = ""):
	self.type = p_type
	if p_caster:
		self.caster_node = p_caster
		if is_instance_valid(p_caster): self.caster_path = p_caster.get_path()
	self.ap_cost = p_ap_cost
	self.name = p_name if !p_name.is_empty() else ActionType.keys()[type].capitalize()

static func new_idle_action(caster: BattleCharacter, p_ap_cost: int = 1) -> PlannedAction:
	return PlannedAction.new(ActionType.IDLE, caster, p_ap_cost, "Idle")

static func new_move_action(caster: BattleCharacter, p_target_pos: Vector2, p_ap_cost: int = 1) -> PlannedAction:
	var action = PlannedAction.new(ActionType.MOVE, caster, p_ap_cost, "Move")
	action.target_position = p_target_pos
	return action

static func new_attack_action(caster: BattleCharacter, p_target_node: BattleCharacter, 
							p_ap_cost: int = 1, p_base_damage: int = 10,
							p_check_stat: String = "dexterity", p_domain: String = "weapon_attack_melee",
							p_bonus_stat: String = "strength", p_is_piercing: bool = false) -> PlannedAction:
	var action = PlannedAction.new(ActionType.ATTACK, caster, p_ap_cost, "Attack")
	action.target_node = p_target_node
	if is_instance_valid(p_target_node): action.target_node_path = p_target_node.get_path()
	action.base_damage = p_base_damage
	action.relevant_stat_name = p_check_stat
	action.action_domain = p_domain
	action.damage_bonus_stat = p_bonus_stat
	action.is_piercing_damage = p_is_piercing
	return action
	
static func new_fireball_action(caster: BattleCharacter, p_target_pos: Vector2, 
								p_ap_cost: int = 2, p_base_damage: int = 15, p_radius: float = 50.0,
								p_check_stat: String = "intelligence", p_domain: String = "spell_cast_fire",
								p_bonus_stat: String = "intelligence") -> PlannedAction:
	var action = PlannedAction.new(ActionType.SPELL_FIREBALL, caster, p_ap_cost, "Fireball")
	action.target_position = p_target_pos
	action.base_damage = p_base_damage
	action.aoe_radius = p_radius
	action.relevant_stat_name = p_check_stat
	action.action_domain = p_domain
	action.damage_bonus_stat = p_bonus_stat
	return action

static func new_heal_spell_action(caster: BattleCharacter, p_target_node: BattleCharacter,
								p_ap_cost: int = 1, p_base_heal: int = 20,
								p_check_stat: String = "willpower", p_domain: String = "spell_cast_healing",
								p_bonus_stat: String = "willpower") -> PlannedAction:
	var action = PlannedAction.new(ActionType.SPELL_HEAL, caster, p_ap_cost, "Heal")
	action.target_node = p_target_node
	if is_instance_valid(p_target_node): action.target_node_path = p_target_node.get_path()
	action.base_heal = p_base_heal
	action.relevant_stat_name = p_check_stat
	action.action_domain = p_domain
	action.damage_bonus_stat = p_bonus_stat
	return action

func get_caster_node(base_node_for_path_resolve: Node) -> BattleCharacter:
	if is_instance_valid(caster_node): return caster_node
	if caster_path and !caster_path.is_empty():
		var node = base_node_for_path_resolve.get_node_or_null(caster_path)
		if node is BattleCharacter:
			caster_node = node # Cache it
			return caster_node
	return null

func get_target_node(base_node_for_path_resolve: Node) -> BattleCharacter:
	if is_instance_valid(target_node): return target_node
	if target_node_path and !target_node_path.is_empty():
		var node = base_node_for_path_resolve.get_node_or_null(target_node_path)
		if node is BattleCharacter:
			target_node = node # Cache it
			return target_node
	return null
