# res://Core/CombatSystem/skill_check_helper.gd
extends Node

const CRITICAL_FAIL_THRESHOLD_HIGH: int = 96
const AUTO_CRIT_UPGRADE_ROLL_NORMAL_MAX: int = 5
const AUTO_CRIT_UPGRADE_ROLL_PIERCING_MAX: int = 10

class SkillCheckResult:
	var success: bool = false
	var is_critical_hit: bool = false
	var critical_hit_tier: int = 0 # 0=no crit, 1=1.5x, 2=2x, ..., 6=4x
	var damage_multiplier: float = 1.0
	var is_critical_fail: bool = false
	var roll_value: int = 0
	var target_value: int = 0 # The number the roll needed to be <= (Stat + TraitMod)

	func _to_string() -> String:
		return "Roll: %d vs Target: %d. Success: %s. CritTier: %d (x%.1f Mult). CritFail: %s" % \
			[roll_value, target_value, success, critical_hit_tier, damage_multiplier, is_critical_fail]

static func perform_check(
		base_stat_value: int, 
		character_traits: Array[String], 
		action_domain: String, 
		is_piercing_damage_check: bool = false
	) -> SkillCheckResult:
	
	var result = SkillCheckResult.new()
	var trait_modifier = DomainTraits.get_trait_modifier_for_check(character_traits, action_domain)
	result.target_value = base_stat_value + trait_modifier
	# Target value can be anything, effectively. Clamping to 0-100 isn't strictly necessary for roll-under.
	# result.target_value = clampi(result.target_value, 0, 1000) 

	result.roll_value = randi_range(1, 100)

	if result.roll_value >= CRITICAL_FAIL_THRESHOLD_HIGH:
		result.is_critical_fail = true
		result.success = false
		result.damage_multiplier = 0.0 
		return result

	result.success = result.roll_value <= result.target_value

	var initial_crit_tier = 0
	if result.success:
		var diff = result.target_value - result.roll_value # How much "under" the target the roll was
		if diff >= 50: initial_crit_tier = 1  #  50 to  99 below: Tier 1 (1.5x)
		if diff >= 100: initial_crit_tier = 2 # 100 to 149 below: Tier 2 (2.0x)
		if diff >= 150: initial_crit_tier = 3 # 150 to 199 below: Tier 3 (2.5x)
		if diff >= 200: initial_crit_tier = 4 # 200 to 249 below: Tier 4 (3.0x)
		if diff >= 250: initial_crit_tier = 5 # 250 to 299 below: Tier 5 (3.5x)
		if diff >= 300: initial_crit_tier = 6 # 300+ below:      Tier 6 (4.0x)
	
	result.critical_hit_tier = initial_crit_tier

	var auto_crit_upgrade_threshold = AUTO_CRIT_UPGRADE_ROLL_NORMAL_MAX
	if is_piercing_damage_check:
		auto_crit_upgrade_threshold = AUTO_CRIT_UPGRADE_ROLL_PIERCING_MAX
	
	if result.roll_value <= auto_crit_upgrade_threshold:
		if result.success: # Only upgrade crits on successes
			result.critical_hit_tier += 1
			# print("Auto crit upgrade! Roll was %d. New tier: %d" % [result.roll_value, result.critical_hit_tier])

	result.critical_hit_tier = clampi(result.critical_hit_tier, 0, 6) 

	if result.critical_hit_tier > 0:
		result.is_critical_hit = true
		result.damage_multiplier = 1.0 + (result.critical_hit_tier * 0.5)
	elif result.success:
		result.damage_multiplier = 1.0
	else: # Miss (and not crit fail)
		result.damage_multiplier = 0.0

	return result
