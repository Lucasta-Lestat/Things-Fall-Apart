# MeleeReach.gd
# The single answer to "how far, and through what arc, does a melee swing reach?"
#
# Character melee used to be resolved by the weapon's blade Area2D. That Area2D
# hangs off the rig's hand anchor, ~60px off the body centre-line, so the region
# it swept was a circle centred THERE, not on the character: measured coverage
# was roughly -105deg..+20deg of the wielder's facing (the entire right flank was
# immune), piercing weapons never crossed the centreline and landed nothing at
# any distance, and reach scaled with `rig_scale` — a cosmetic per-race art
# number spanning 3.8x across races.json. Meanwhile the authored Items.json
# "range" reached exactly one consumer (ai.gd) and was discarded by a collision
# floor for anything short.
#
# Now the authored range IS the reach, both here and in ai.gd's stand-off, and
# the arc is centred on facing. Deliberately a class_name static utility rather
# than methods on Game.gd: Game.gd has no class_name and is a scene-root
# singleton, so the AI and the headless harnesses could not share its formulas —
# which is precisely how the stand-off and the hit test drifted apart before.
class_name MeleeReach
extends Object

# Half-width of the swing arc, in DEGREES either side of the attacker's facing.
# A slash sweeps wide, a thrust is a line. An individual weapon can override via
# a "swing_arc" key in Items.json (-> WeaponShape.swing_arc_deg).
const ARC_DEG_BY_DAMAGE := {
	"slashing": 60.0,
	"bludgeoning": 50.0,
	"piercing": 25.0,
}
const ARC_DEG_DEFAULT := 50.0

# Unarmed reach, attacker centre -> target surface, before body_size_mod.
# Short on purpose: a punch needs body contact.
const UNARMED_REACH_PX := 34.0

# Every attacker reaches at least this far past its OWN body circle. Without it
# a very large creature holding a short weapon would be walled out by its own
# girth — its body gap would exceed the authored reach and it could never close.
# This floor also guarantees max_center_dist() always exceeds the pair's contact
# distance, which is what lets ai.gd drop its old "stand-off floor" entirely.
const MIN_CLEARANCE_PX := 12.0


## Reach in px, measured attacker CENTRE -> target SURFACE. The authored
## Items.json "range" (in TILES) is the source of truth; nothing here consults
## the rig, the art scale, or the physical blade geometry.
static func reach_px(attacker: Node2D, weapon: Node2D) -> float:
	var base: float = UNARMED_REACH_PX
	if "body_size_mod" in attacker:
		base = UNARMED_REACH_PX * float(attacker.body_size_mod)
	if weapon is WeaponShape and float(weapon.weapon_range) > 0.0:
		base = float(weapon.weapon_range) * float(GridManager.TILE_SIZE)
	var own_radius: float = 0.0
	if attacker != null and attacker.has_method("_body_circle_radius"):
		own_radius = attacker._body_circle_radius()
	return maxf(base, own_radius + MIN_CLEARANCE_PX)


## Largest centre-to-centre distance at which `attacker` can hit `target`.
## Adding the target's body radius means a bigger target is easier to hit, which
## the old blade-overlap model also did (the blade had to touch that circle).
static func max_center_dist(attacker: Node2D, target: Node2D, weapon: Node2D) -> float:
	var r: float = 0.0
	if target != null and target.has_method("_body_circle_radius"):
		r = target._body_circle_radius()
	return reach_px(attacker, weapon) + r


## Half-width of the swing arc, in RADIANS.
static func half_arc_rad(weapon: Node2D, damage_type: String) -> float:
	var deg: float = ARC_DEG_DEFAULT
	if weapon is WeaponShape and float(weapon.swing_arc_deg) > 0.0:
		deg = float(weapon.swing_arc_deg)
	elif ARC_DEG_BY_DAMAGE.has(damage_type):
		deg = float(ARC_DEG_BY_DAMAGE[damage_type])
	return deg_to_rad(deg)


## Is `target` inside `attacker`'s swing? Forward is the character's local -Y
## (see ProceduralCharacter's facing convention: target_rotation is
## `direction.angle() + PI/2`).
static func in_swing(attacker: Node2D, target: Node2D, weapon: Node2D, damage_type: String) -> bool:
	var to_target: Vector2 = target.global_position - attacker.global_position
	var dist: float = to_target.length()
	if dist < 0.001:
		return true
	if dist > max_center_dist(attacker, target, weapon):
		return false
	var facing: Vector2 = Vector2.UP.rotated(attacker.global_rotation)
	return absf(facing.angle_to(to_target)) <= half_arc_rad(weapon, damage_type)


## The point on `target`'s body circle facing the attacker — where a blade would
## bite. Feeds Game.process_weapon_hit's limb resolution, replacing the contact
## point the Area2D overlap used to supply (WeaponShape._compute_contact_point).
static func contact_point(attacker: Node2D, target: Node2D) -> Vector2:
	var to_target: Vector2 = target.global_position - attacker.global_position
	var dist: float = to_target.length()
	if dist < 0.001:
		return target.global_position
	var r: float = 0.0
	if target.has_method("_body_circle_radius"):
		r = target._body_circle_radius()
	return target.global_position - (to_target / dist) * r
