# MeleeReach.gd
# The single answer to "how far, and through what arc, does a melee swing reach?"
#
# Character melee used to be resolved by the weapon's blade Area2D. That Area2D
# hangs off the rig's hand anchor, ~60px off the body centre-line, so the region
# it swept was a circle centred THERE, not on the character: measured coverage
# was roughly -105deg..+20deg of the wielder's facing (the entire right flank was
# immune), piercing weapons never crossed the centreline and landed nothing at
# any distance, and reach scaled with `rig_scale` — a cosmetic per-race art
# number spanning 3.8x across races.json.
#
# The first replacement made the authored Items.json "range" (tiles * TILE_SIZE)
# the reach. That fixed the arc and centring, but blessed range values authored
# back when nothing consumed them: a spear authored 3.0 tiles (192px) while its
# drawn tip reaches ~100px from the wielder's centre, so thrusts landed from
# roughly TWICE the visible reach (and worse for the pike's 4.5).
#
# Now reach is DERIVED FROM THE WEAPON'S OWN GEOMETRY — the same numbers the art
# is fitted to — so what the player sees is what hits:
#
#     reach = (HAND_REACH_PX + total_length * grip_position) * body_size_mod
#
# total_length * grip_position is the drawn blade forward of the gripping hand
# (weapon_shape.gd fits the sprite to total_length and puts the grip on the
# node's origin, so this matches the art exactly). HAND_REACH_PX stands in for
# the hand anchor's distance from the body centre at the strike apex; it is a
# constant rather than a rig measurement precisely because rig_scale is cosmetic
# per-race art and reach must not vary with it. body_size_mod scales both terms
# because the holder node scales the drawn weapon by exactly that factor
# (ProceduralCharacter's holder setup), so a small race's shorter drawn blade
# keeps a matching shorter reach. Items.json "range" is no longer consulted for
# melee — it remains the authored range of RANGED weapons (tiles, converted via
# GridManager.COMBAT_TILE_SIZE in ai.gd's stand-off). Melee no longer touches
# GridManager.TILE_SIZE at all, which also keeps world maps (whose TILE_SIZE is
# inflated by world_render_scale while character art is not) out of melee math.
#
# Deliberately a class_name static utility rather than methods on Game.gd:
# Game.gd has no class_name and is a scene-root singleton, so the AI and the
# headless harnesses could not share its formulas — which is precisely how the
# stand-off and the hit test drifted apart before.
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

# Stand-in for the gripping hand's distance from the body centre at the strike
# apex, for a body_size_mod-1.0 character. Measured off the human male rig's
# baked thrust clip (grip anchor ~51px from centre at the hit frame, ~49px at
# full extension) and rounded down so short weapons stay honest — a dagger tip
# should still demand near body contact.
const HAND_REACH_PX := 48.0

# Every attacker reaches at least this far past its OWN body circle. Without it
# a very large creature holding a short weapon would be walled out by its own
# girth — its body gap would exceed the derived reach and it could never close.
# This floor also guarantees max_center_dist() always exceeds the pair's contact
# distance, which is what lets ai.gd drop its old "stand-off floor" entirely.
const MIN_CLEARANCE_PX := 12.0


## Reach in px, measured attacker CENTRE -> target SURFACE, derived from the
## weapon's drawn geometry so the accepted distance matches the art. Nothing
## here consults the rig, the authored "range", or GridManager.TILE_SIZE.
static func reach_px(attacker: Node2D, weapon: Node2D) -> float:
	var size_mod: float = 1.0
	if attacker != null and "body_size_mod" in attacker:
		size_mod = float(attacker.body_size_mod)
	var base: float = UNARMED_REACH_PX * size_mod
	if weapon is WeaponShape and weapon.is_melee():
		base = (HAND_REACH_PX + float(weapon.total_length) * float(weapon.grip_position)) * size_mod
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


## Walls veto blades: false if a vision-blocking body sits between the pair.
## Melee shares the sight occlusion channel (VISION_BLOCKERS via
## GridManager.sight_line_clear) rather than raw STRUCTURES so cover a character
## can see and strike over (occlude_top below eye height) does not stop a swing,
## while a solid wall does. Elevation-aware for deck fights, same as sight.
static func blade_line_clear(space: PhysicsDirectSpaceState2D, attacker: Node2D, target: Node2D) -> bool:
	if space == null:
		return true
	var a_elev: float = 0.0
	if attacker.has_method("get_elevation"):
		a_elev = attacker.get_elevation()
	var t_elev: float = 0.0
	if target.has_method("get_elevation"):
		t_elev = target.get_elevation()
	return GridManager.sight_line_clear(
		space, attacker.global_position, target.global_position, a_elev, t_elev)


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
