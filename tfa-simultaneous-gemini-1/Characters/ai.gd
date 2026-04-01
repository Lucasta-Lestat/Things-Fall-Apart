### AI
enum AIState {
	DEAD,           # Does nothing for now, want to implement some spirit world mechanics later
	IDLE,           # No enemies nearby, standing still
	PATROL,         # Moving along patrol path (optional)
	CHASE,          # Moving toward target
	APPROACH,       # Getting into attack range
	ATTACK,         # Performing attack
	RETREAT,        # Backing away (low health, etc)
	STUNNED         # Recovering from hit/stagger
}

# Current state
var current_state: AIState = AIState.IDLE
var state_timer: float = 0.0
# Target tracking
var current_target: ProceduralCharacter = null
var last_known_target_pos: Vector2 = Vector2.ZERO

var target_item: Node = null
var goal_reassess_timer: float = 0.0
const GOAL_REASSESS_INTERVAL: float = 2.0

# Wander settings
var wander_cooldown: float = 0.0
const WANDER_COOLDOWN_TIME: float = 3.0
const WANDER_RANGE_TILES: int = 5

# Hunger threshold
var hunger: float = 0.0
const HUNGER_THRESHOLD: float = 50.0

@onready var game = get_node("/root/Game")
#trigger "Talk" should search the dialogues in the dialogue file until it finds one for which prerequisites are met.
#  Can set an already played prereq to keep it from repeating
var interact_options = ["Attack", "Talk"]
# Detection settings
@export var detection_range: float = 1440*sight   # How far AI can see enemies
@export var attack_range: float = 70.0 * body_size_mod      # Range to start attacking
@export var preferred_range: float = 40.0 *body_size_mod     # Ideal combat distance
@export var too_close_range: float = 20.0 *body_size_mod    # Back up if closer than this

# Minimum approach distance (prevents walking into other characters)
var min_approach_distance: float:
	get: return collision_radius + minimum_separation + 10.0  # Never get closer than this

# Behavior settings
@export var aggression: float = 0.7           # 0-1, higher = more aggressive
@export var reaction_time: float = 0.15       # Delay before responding
@export var attack_cooldown: float = 0.2      # Minimum time between attacks

# Timing
var attack_cooldown_timer: float = 0.0
var reaction_timer: float = 0.0

signal state_changed(old_state: AIState, new_state: AIState)
signal target_acquired(target: ProceduralCharacter)
signal target_lost()
	
func _update_target() -> void:
	"""Find and track enemy targets"""
	# If we have a valid target, check if still valid
	if current_target:
		if not is_instance_valid(current_target):
			print("losing target because instance invalid")
			_lose_target()
			return
		
		if not current_target.is_alive():
			print("losing target because target is dead")
			_lose_target()
			return
		
		# Check if target is now too far
		var dist = self.global_position.distance_to(current_target.global_position)
		if dist > detection_range * 1.5:  # Hysteresis to prevent flickering
			print("losing target because target is too far")
			_lose_target()
			return
		
		# Update last known position
		last_known_target_pos = current_target.global_position
		return
	
	# Search for new target
	var best_target: ProceduralCharacter = null
	var best_distance: float = detection_range
	
	# Get all characters in scene (this could be optimized with groups)
	var characters = game2.characters_in_scene
	#print("Searching for target in: ",characters)
	for node in characters:
		if node == self:
			#print("not targeting self")
			continue
		
		var other = node as ProceduralCharacter
		if not other:
			#print("no other potential targets but self")
			continue
		
		# Check if enemy faction
		if not _is_enemy(other):
			#print("potential target is not an enemy, continuing")
			continue
		#print("enemy target found")
		# Check if alive
		if not other.is_alive():
			continue
		#print("living enemy target found")
		# Check distance
		var dist = self.global_position.distance_to(other.global_position)
		if dist < best_distance:
			print("updating to closer target")
			best_distance = dist
			best_target = other
	
	if best_target:
		print("found best target, attempting to acquire")
		_acquire_target(best_target)

func _is_enemy(other: ProceduralCharacter) -> bool:
	"""Check if other character is an enemy"""
	if self.faction_id == other.faction_id:
		#print("same faction identified")
		return false
	
	# Use faction system if available
	var factions = game2.factions
	if factions:
		#print("My factions enemies are ", factions[self.faction_id].enemies)
		#print("The potential target is in the faction: ", other.faction_id)
		if other.faction_id in factions[self.faction_id].enemies:
			#print("Identified target as enemy")
			return true
	
	# Default: different factions are enemies (except neutral)
	return self.faction_id != "neutral" and other.faction_id != "neutral"

func _acquire_target(target: ProceduralCharacter) -> void:
	current_target = target
	last_known_target_pos = target.global_position
	emit_signal("target_acquired", target)
	print("target acquired")
	# Start reaction delay before responding
	reaction_timer = reaction_time

func _lose_target() -> void:
	current_target = null
	emit_signal("target_lost")
	_change_state(AIState.IDLE)

func _change_state(new_state: AIState) -> void:
	if new_state == current_state:
		return
	
	var old_state = current_state
	current_state = new_state
	state_timer = 0.0
	emit_signal("state_changed", old_state, new_state)

# ===== STATE PROCESSING =====

func _process_idle(delta: float) -> void:
	if current_target and reaction_timer <= 0:
		_change_state(AIState.CHASE)

func _process_chase(delta: float) -> void:
	#print("processing chase")
	if not current_target:
		_change_state(AIState.IDLE)
		return
	
	var dist = self.global_position.distance_to(current_target.global_position)
	
	# Calculate safe approach distance
	var combined_collision_dist = collision_radius + current_target.collision_radius + minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	
	# Switch to approach when getting close
	if dist <= safe_attack_range * 1.2:
		print("Distance closed, approaching target for attack")
		_change_state(AIState.APPROACH)
		return
	
	# Move toward target, but aim for a position at attack range, not directly on top
	var dir_to_target = (current_target.global_position - self.global_position).normalized()
	var target_pos = current_target.global_position - dir_to_target * safe_attack_range * 0.8
	_move_toward(target_pos)

func _process_approach(delta: float) -> void:
	#print("processing approach")
	if not current_target:
		_change_state(AIState.IDLE)
		return
	
	var dist = self.global_position.distance_to(current_target.global_position)
	var dir_to_target = (current_target.global_position - self.global_position).normalized()
	
	# Calculate combined collision distance (both characters' radii + buffer)
	var combined_collision_dist = collision_radius + current_target.collision_radius + minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	var safe_preferred_range = max(preferred_range, combined_collision_dist + 10.0)
	var safe_too_close = max(too_close_range, combined_collision_dist)
	
	# Face the target
	self.target_rotation = dir_to_target.angle() + PI / 2
	#print("checking if target is in range")
	# Too far - chase again
	if dist > safe_attack_range * 1.5:
		_change_state(AIState.CHASE)
		return
	
	# In attack range - attack!
	#print("target is in range, attack")
	if dist <= safe_attack_range and dist >= safe_too_close and attack_cooldown_timer <= 0:
		#print("actually attacking target")
		_change_state(AIState.ATTACK)
		return
	
	# Too close - back up to safe distance
	if dist < safe_too_close:
		var retreat_dir = -dir_to_target
		var retreat_pos = self.global_position + retreat_dir * (safe_preferred_range - dist + 10)
		_move_toward(retreat_pos)
		return
	
	# Strafe or approach to preferred range
	if dist > safe_preferred_range:
		# Don't move directly to target - move to a position at preferred range
		var approach_pos = current_target.global_position - dir_to_target * safe_preferred_range
		_move_toward(approach_pos)
	else:
		# At preferred range - strafe or hold position
		if randf() < 0.3 * delta:  # Occasional strafe
			var strafe_dir = dir_to_target.rotated(PI / 2 * (1 if randf() > 0.5 else -1))
			_move_toward(self.global_position + strafe_dir * 30)

func _process_attack(delta: float) -> void:
	# Calculate safe distances
	var combined_collision_dist = collision_radius + (current_target.collision_radius if current_target else 0) + minimum_separation
	var safe_attack_range = max(attack_range, combined_collision_dist + 5.0)
	
	# Start attack if not already attacking
	#print("self.attack_animator.is_attacking: ", self.attack_animator.is_attacking )
	if not self.attack_animator.is_attacking:
		#print("do we have a weapon?")
		if self.current_main_hand_item: 
		#	print("yes we do have a weapon")
			self.attack()
			attack_cooldown_timer = attack_cooldown / (self.attack_speed_multiplier )
		else:
			#print("trying attack without a weapon")
			self.attack()
	# Wait for attack to finish
	
	if not self.attack_animator.is_attacking:
		print("changing state to appraoch")
		_change_state(AIState.APPROACH)
	if current_target and global_position.distance_to(current_target.global_position) > 1.5 * safe_attack_range:
		print("changing state to approach")
		_change_state(AIState.APPROACH)

func _process_retreat(delta: float) -> void:
	if not current_target:
		_change_state(AIState.IDLE)
		return
	
	var dir_away = (self.global_position - current_target.global_position).normalized()
	var safe_retreat_dist = collision_radius + current_target.collision_radius + minimum_separation + 50.0
	_move_toward(self.global_position + dir_away * safe_retreat_dist)
	
	# Exit retreat after some time
	if state_timer > 1.5:
		_change_state(AIState.IDLE)
