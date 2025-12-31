# faction.gd
# Faction system for managing relationships between groups
extends Resource
class_name Faction

@export var faction_id: String = ""
@export var faction_name: String = ""
@export var faction_color: Color = Color.WHITE  # For UI/indicators

# Lists of faction IDs
@export var allies: Array[String] = []
@export var enemies: Array[String] = []
# Factions not in either list are considered neutral

enum Relationship { ALLY, NEUTRAL, ENEMY }

func get_relationship_with(other_faction_id: String) -> Relationship:
	if other_faction_id == faction_id:
		return Relationship.ALLY  # Same faction = allied
	if other_faction_id in allies:
		return Relationship.ALLY
	if other_faction_id in enemies:
		return Relationship.ENEMY
	return Relationship.NEUTRAL

func is_ally(other_faction_id: String) -> bool:
	return get_relationship_with(other_faction_id) == Relationship.ALLY

func is_enemy(other_faction_id: String) -> bool:
	return get_relationship_with(other_faction_id) == Relationship.ENEMY

func is_neutral(other_faction_id: String) -> bool:
	return get_relationship_with(other_faction_id) == Relationship.NEUTRAL

# ===== FACTION MANAGER (Static/Singleton Pattern) =====

@export var factions: Dictionary = {}  # faction_id -> Faction
static var _loaded: bool = false

func get_faction(faction_id: String) -> Faction:
	if factions.has(faction_id):
		return factions[faction_id]
	return null

func get_relationship(faction_a_id: String, faction_b_id: String) -> Relationship:
	var faction_a = get_faction(faction_a_id)
	print("attempting to find target faction.  Did we?: ", faction_a)
	if faction_a:
		return faction_a.get_relationship_with(faction_b_id)
	return Relationship.NEUTRAL

func are_enemies(faction_a_id: String, faction_b_id: String) -> bool:
	return get_relationship(faction_a_id, faction_b_id) == Relationship.ENEMY

func are_allies(faction_a_id: String, faction_b_id: String) -> bool:
	return get_relationship(faction_a_id, faction_b_id) == Relationship.ALLY

func get_all_factions() -> Array[Faction]:
	var result: Array[Faction] = []
	for faction in factions.values():
		result.append(faction)
	return result

func clear_factions() -> void:
	factions.clear()
	_loaded = false

# Instance method to load from dictionary
func load_from_data(data: Dictionary) -> void:
	if data.has("id"):
		faction_id = data["id"]
	if data.has("name"):
		faction_name = data["name"]
	if data.has("color"):
		faction_color = Color.html(data["color"])
	if data.has("allies"):
		allies.clear()
		for ally_id in data["allies"]:
			allies.append(ally_id)
	if data.has("enemies"):
		enemies.clear()
		for enemy_id in data["enemies"]:
			enemies.append(enemy_id)

func to_data() -> Dictionary:
	return {
		"id": faction_id,
		"name": faction_name,
		"color": faction_color.to_html(),
		"allies": allies,
		"enemies": enemies
	}
