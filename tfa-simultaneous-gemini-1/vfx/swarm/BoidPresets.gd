# BoidPresets.gd - Named configuration profiles for BoidField.
#
# A preset is just a Dictionary of overrides applied on top of DEFAULTS. Add new
# swarms / spell looks here; nothing else needs to change. Two render modes:
#   "sprite" -> per-instance textured + rotated to heading (creatures, e.g. rats)
#   "mote"   -> soft additive (or alpha) glow tinted per-instance (spell motes)
class_name BoidPresets
extends RefCounted

const DEFAULTS := {
	"count": 60,
	"render_mode": "mote",          # "sprite" | "mote"
	"texture": "",                  # sprite-mode texture path
	"sprite_size": 28.0,            # in-world long-side px (sprite mode)
	"mote_size": 12.0,              # in-world diameter px (mote mode)
	"color": Color(1, 1, 1, 1),     # base tint (sprite) / glow color (mote)
	"color_variation": 0.25,        # 0..1 per-agent hue/brightness jitter
	"additive": true,               # mote blend: add vs alpha
	"gait": false,                  # sprite squash/stretch scurry animation
	"heading_offset": 0.0,          # radians added to atan2(vel) before rotating
	"z_index": 90,

	# spawn / containment (world px)
	"spawn_radius": 60.0,
	"bounds_half": Vector2(140, 120),

	# steering
	"max_speed": 140.0,
	"min_speed": 0.0,
	"max_force": 500.0,
	"perception": 70.0,
	"sep_radius": 18.0,
	"separation": 0.9,
	"alignment": 1.0,
	"cohesion": 1.0,
	"wander": 0.4,
	"target_weight": 1.6,
	"bounds_weight": 1.5,
	"home_weight": 0.6,
	"damping": 0.99,
	"swirl": 0.0,                   # tangential orbit force (vortex look)
}

const PRESETS := {
	# --- Creature swarms ---------------------------------------------------
	"rat_swarm": {
		"count": 40,
		"render_mode": "sprite",
		"texture": "res://art/creatures/rat_brown.png",
		"sprite_size": 30.0,
		"color": Color(1, 1, 1),
		"color_variation": 0.16,        # subtle lighter/darker fur
		"additive": false,
		"gait": true,
		"z_index": 12,
		"spawn_radius": 90.0,
		"bounds_half": Vector2(170, 130),
		"max_speed": 135.0,
		"min_speed": 40.0,              # rats never fully stop scurrying
		"max_force": 650.0,
		"perception": 64.0,
		"sep_radius": 26.0,
		"separation": 1.9,              # avoid piling up
		"alignment": 0.55,
		"cohesion": 0.85,
		"wander": 0.8,
		"target_weight": 1.7,
		"bounds_weight": 2.0,
		"home_weight": 0.5,
		"damping": 0.99,
	},
	"insect_swarm": {                   # plague of locusts / flies
		"count": 300,
		"render_mode": "mote",
		"mote_size": 5.0,
		"color": Color(0.13, 0.11, 0.08),
		"color_variation": 0.3,
		"additive": false,
		"z_index": 30,
		"spawn_radius": 50.0,
		"bounds_half": Vector2(110, 100),
		"max_speed": 190.0,
		"min_speed": 20.0,
		"max_force": 900.0,
		"perception": 40.0,
		"sep_radius": 8.0,
		"separation": 1.2,
		"alignment": 0.5,
		"cohesion": 0.7,
		"wander": 1.2,                  # erratic
		"target_weight": 1.6,
		"bounds_weight": 1.8,
		"home_weight": 0.8,
		"damping": 0.985,
	},

	# --- Spell effects -----------------------------------------------------
	"arcane_motes": {
		"count": 120,
		"render_mode": "mote",
		"mote_size": 10.0,
		"color": Color(0.35, 0.55, 0.95),
		"color_variation": 0.5,
		"additive": true,
		"z_index": 95,
		"spawn_radius": 80.0,
		"bounds_half": Vector2(110, 110),
		"max_speed": 175.0,
		"min_speed": 30.0,              # keep orbiting, never settle
		"max_force": 480.0,
		"perception": 70.0,
		"sep_radius": 24.0,
		"separation": 1.1,
		"alignment": 0.7,
		"cohesion": 0.5,
		"wander": 0.4,
		"target_weight": 1.6,
		"bounds_weight": 1.3,
		"home_weight": 0.35,            # loose - the swirl does the containment
		"damping": 0.99,
		"swirl": 1.4,                   # the magical vortex
	},
	"fire_swarm": {
		"count": 90,
		"render_mode": "mote",
		"mote_size": 13.0,
		"color": Color(1.0, 0.5, 0.14),
		"color_variation": 0.35,
		"additive": true,
		"z_index": 95,
		"spawn_radius": 55.0,
		"bounds_half": Vector2(85, 95),
		"max_speed": 160.0,
		"min_speed": 20.0,
		"max_force": 480.0,
		"perception": 60.0,
		"sep_radius": 18.0,
		"separation": 1.0,
		"alignment": 0.6,
		"cohesion": 0.6,
		"wander": 1.0,
		"target_weight": 1.5,
		"bounds_weight": 1.4,
		"home_weight": 0.6,
		"damping": 0.98,
		"swirl": 0.7,                   # rising-flame curl
	},
	"spirit_wisps": {
		"count": 55,
		"render_mode": "mote",
		"mote_size": 16.0,
		"color": Color(0.7, 0.85, 1.0),
		"color_variation": 0.28,
		"additive": true,
		"z_index": 95,
		"spawn_radius": 70.0,
		"bounds_half": Vector2(160, 140),
		"max_speed": 80.0,              # slow, drifting
		"min_speed": 0.0,
		"max_force": 260.0,
		"perception": 90.0,
		"sep_radius": 22.0,
		"separation": 0.9,
		"alignment": 0.9,
		"cohesion": 0.8,
		"wander": 0.6,
		"target_weight": 1.2,
		"bounds_weight": 1.2,
		"home_weight": 0.45,
		"damping": 0.99,
		"swirl": 0.6,                   # slow ghostly drift-orbit
	},
}

# Returns a fully-populated config: DEFAULTS <- preset <- overrides.
static func get_config(preset_name: String, overrides: Dictionary = {}) -> Dictionary:
	var cfg := DEFAULTS.duplicate(true)
	if PRESETS.has(preset_name):
		for k in PRESETS[preset_name]:
			cfg[k] = PRESETS[preset_name][k]
	else:
		push_warning("BoidPresets: unknown preset '%s', using defaults." % preset_name)
	for k in overrides:
		cfg[k] = overrides[k]
	return cfg

static func preset_names() -> Array:
	return PRESETS.keys()
