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
# RENDERER RULE: a CanvasItem only RECEIVES a light's shadows when
# (item.light_mask & light.shadow_item_cull_mask) != 0. Everything lit by the
# cones (ground, structure art, characters) has light_mask 1, so every cone's
# shadow mask must include bit 1 — a cone culling on bit 2 alone casts no
# shadow on anything (the legacy HIGH tier and pink cone never have).
#
# Relief maps only (GridManager.relief_los): sight cones use ELEVATION BANDS
# instead of GROUND/HIGH. Band b (0..17) is bit SIGHT_BAND_SHIFT + b, i.e.
# light-mask bits 2..19 (values 4 .. 1 << 19); a cone's mask is GROUND | its
# band bit. So no relief occluder may carry bit 1 (it would shadow every
# cone): structures carry SIGHT_MASK_HIGH as their "structure" bit for
# ordinary lights plus their band bits; cliffs carry band bits only. The band
# math lives in GridManager (cone_band / band_mask_below).
const SIGHT_BAND_SHIFT := 2
const SIGHT_BAND_COUNT := 18
# Shadow mask for ordinary (non-cone) lights — torches, explosions: every
# structure occluder carries bit 1 (flat maps) or bit 2 (relief maps); cliffs
# carry neither. On flat maps an occluder with bit 2 always has bit 1 too, so
# this casts exactly what SIGHT_MASK_GROUND alone did there.
const LIGHT_SHADOW_MASK := SIGHT_MASK_GROUND | SIGHT_MASK_HIGH

# CanvasItem.light_mask bit carried by elevated-surface art (deck / battlement
# walkways). Only stealth mode's NPCLineOfSightHigh cone lights it
# (range_item_cull_mask); ordinary lights use bit 1 as before. Not a physics layer.
const ELEVATED_SURFACE_LIGHT := 4

# CanvasItem.light_mask bit of what the tree crown rules hide (P3-B, on maps
# whose rows carry the contract-3 canopy cells): the crowns (CanopyLayer),
# each hiding crown's rule disc of ground and every character standing under
# a live crown -- all carrying CanopyLayer.SHADED_MASK = this | LAMP_LIGHT and
# not bit 1. No full-range cone lights it; each drawn sight cone carries a
# "CanopyCone" child that does, at the range the crown rules let that viewer
# see under a crown (half range from the ground, nothing a story up:
# CanopyLayer.fit_canopy_cone), so a cone never lights what hides from that
# viewer. The child culls shadows on its viewer's mask | this bit, and those
# items receive them through it. Not a physics layer. On relief maps the same
# value is band 17's bit: an occluder carries it only with every band below
# it (band masks run up from band 0, or from the bands its main occluder
# carries), so it never shadows a canopy cone that its viewer's own band bit
# would not.
const CANOPY_LIGHT := 1 << 19

# CanvasItem.light_mask bit lit by the ORDINARY lights -- map lights and held
# lights (EquipmentEffects.make_light), glow marks, fire (CellFireFX),
# lightning and VFXEffectNode lights -- through their range_item_cull_mask
# (1 | LAMP_LIGHT); the sight cones never carry it. Only the items that trade
# bit 1 for CANOPY_LIGHT carry it (above), so a torch still lights a crown or
# a character under one, and nothing else changes. The same value as
# SIGHT_MASK_HIGH in the shadow-mask space: harmless, since every light whose
# shadow mask has bit 2 and that lights LAMP_LIGHT is an ordinary light, whose
# shadows those items should receive.
const LAMP_LIGHT := 2
# range_item_cull_mask of an ordinary light (above).
const LAMP_RANGE_MASK := 1 | LAMP_LIGHT
