class_name CollisionLayers
extends Object

# Layer bit values (1 << (layer_index - 1)).
# Use these for collision_layer and collision_mask assignments.
const STRUCTURES := 1        # Layer 1 — solid structures (walls, terrain)
const CHARACTERS := 2        # Layer 2 — characters (CharacterBody2D body + Area2D soft-sep child)
const VISION_BLOCKERS := 4   # Layer 3 — vision blockers; queried by LOS raycasts
const PROJECTILES := 8       # Layer 4 — projectiles in flight
const ITEMS := 16            # Layer 5 — world items (walkable, force-affectable)
const WEAPON_HITBOXES := 32  # Layer 6 — active melee weapon hitbox during a swing
const WARPS := 1 << 19       # Layer 20 — clickable warp Area2Ds (probed from input handlers)
const INTERACTABLES := 64    # Layer 7 — open doors: point-query clickable, physically blocks nothing.
                             # No composite mask may ever include this bit.
const CORPSES := 128         # Layer 8 — dead characters' bodies: point-query clickable
                             # (Search Body loot), physically blocks nothing. Like
                             # INTERACTABLES, no composite mask may ever include this bit.

# Composite masks — name describes the intent, not the bits, so callsites read clearly.

# Structures sit on both their own layer and the vision-blocker layer so a single
# raycast can detect "anything that blocks vision" without enumerating bodies.
const STRUCTURE_LAYERS := STRUCTURES | VISION_BLOCKERS

# What a projectile should collide against in flight.
const PROJECTILE_HIT_MASK := STRUCTURES | CHARACTERS

# What a force-pushed item should collide against (walls, other items, and
# characters — the last is groundwork for Phase B when items become RigidBody2D
# and can actually move under forces).
const ITEM_PHYSICS_MASK := STRUCTURES | ITEMS | CHARACTERS

# What an active melee weapon hitbox should detect during a swing. CHARACTERS is
# deliberately absent: character melee resolves through MeleeReach's reach + arc
# test at the animation's hit frame (Game.resolve_melee_swing), because the blade
# Area2D is parented to the rig's hand and so swept an arc offset ~50deg off the
# wielder's facing. Objects keep the physical channel — "did the blade enter this
# door" IS an overlap question, and a door cannot strafe out of the arc.
const WEAPON_OBJECT_HITBOX_MASK := ITEMS | STRUCTURES

# Mask passed to PhysicsRayQueryParameters2D for line-of-sight checks.
const VISION_RAY_MASK := VISION_BLOCKERS

# LIGHT shadow-cull mask bits — shared by the sight-cone PointLight2Ds
# (shadow_item_cull_mask) and structure LightOccluder2Ds (occluder_light_mask).
# These are NOT physics layers. Tier by viewer elevation: >= 1 story = HIGH.
const SIGHT_MASK_GROUND := 1   # existing bit: occluded by everything
const SIGHT_MASK_HIGH := 2     # elevated viewers: occluded only by occluders carrying bit 2 (occlude_top >= 2.0)

# CanvasItem.light_mask bit carried by elevated-surface art (deck / battlement
# walkways). Only stealth mode's NPCLineOfSightHigh cone lights it
# (range_item_cull_mask); ordinary lights use bit 1 as before. Not a physics layer.
const ELEVATED_SURFACE_LIGHT := 4
