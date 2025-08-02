# res://Abilities/Ability.gd
extends Resource
class_name Ability

enum TargetType { SELF, ALLY, ENEMY, ANY_CHARACTER, GROUND }

@export var id: StringName = &"" # Unique ID, e.g., "fireball", "move"
@export var display_name: String = "Ability"
@export var ap_cost: int = 1 # Total AP slots this ability takes to fully execute/charge
@export var range: float = 100.0 # In pixels. 0 for self.
@export var target_type: TargetType = TargetType.ENEMY
@export var area_of_effect_radius: float = 0.0 # 0 for single target
# @export var icon: Texture2D # For hotbar
# @export var animation_name: StringName # To play on caster
# @export var sfx_path: String # Sound effect path

func requires_target() -> bool:
	return target_type != TargetType.SELF

func _to_string() -> String:
	return "Ability('%s', Cost:%d, Range:%.0f, Target:%s, AOE:%.0f)" % [display_name, ap_cost, range, TargetType.keys()[target_type], area_of_effect_radius]
