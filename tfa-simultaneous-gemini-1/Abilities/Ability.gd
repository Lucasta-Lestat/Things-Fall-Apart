# res://Abilities/Ability.gd
extends Resource
class_name Ability

enum TargetType { SELF, ALLY, ENEMY, ANY_CHARACTER, GROUND }
enum ActionEffect { DAMAGE, HEAL, MOVE }
enum RangeType { ABILITY, TOUCH, WEAPON_MELEE, WEAPON_RANGED }


@export var id: StringName = &"" # Unique ID, e.g., "fireball", "move"
@export var display_name: String = "Ability"
@export var description: String = "Description"
# NEW: Lists of trait IDs that modify the success roll
@export var advantages: Array = []
@export var disadvantages: Array = []

@export var ap_cost: int = 1 # Total AP slots this ability takes to fully execute/charge
@export var range: float = 100.0 # In pixels. 0 for self.
@export var target_type: TargetType = TargetType.ENEMY
@export var area_of_effect_radius: float = 0.0 # 0 for single target
@export var icon: Texture2D # For hotbar
# @export var animation_name: StringName # To play on caster
@export var sfx_path: String # Sound effect path
@export var effect: ActionEffect = ActionEffect.DAMAGE

# NEW: The stat used for the success roll (e.g., "dex", "str", "int")
@export var success_stat: StringName = &"dex" 


# NEW: Fields for damage calculation
@export var is_weapon_attack: bool = false # If true, uses weapon damage and Str mod
@export var flat_damage: int = 0 # For non-weapon abilities like spells


func requires_target() -> bool:
	return target_type != TargetType.SELF

func _to_string() -> String:
	return "Ability('%s', Cost:%d, Range:%.0f, Target:%s, AOE:%.0f)" % [display_name, ap_cost, range, TargetType.keys()[target_type], area_of_effect_radius]
