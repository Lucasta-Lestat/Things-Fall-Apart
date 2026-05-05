class_name CollisionLayers
extends Object

# Layer bit values (1 << (layer_index - 1)).
# Use these for collision_layer and collision_mask assignments.
const STRUCTURES := 1        # Layer 1 — solid structures (walls, terrain)
const CHARACTERS := 2        # Layer 2 — characters (CharacterBody2D body + Area2D soft-sep child)
const VISION_BLOCKERS := 4   # Layer 3 — vision blockers; queried by LOS raycasts
const PROJECTILES := 8       # Layer 4 — projectiles in flight
const ITEMS := 16            # Layer 5 — world items (walkable, force-affectable)

# Composite masks — name describes the intent, not the bits, so callsites read clearly.

# Structures sit on both their own layer and the vision-blocker layer so a single
# raycast can detect "anything that blocks vision" without enumerating bodies.
const STRUCTURE_LAYERS := STRUCTURES | VISION_BLOCKERS

# What a projectile should collide against in flight.
const PROJECTILE_HIT_MASK := STRUCTURES | CHARACTERS

# What a force-pushed item should collide against (walls and other items).
const ITEM_PHYSICS_MASK := STRUCTURES | ITEMS

# Mask passed to PhysicsRayQueryParameters2D for line-of-sight checks.
const VISION_RAY_MASK := VISION_BLOCKERS
