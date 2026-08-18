extends Node2D

## In-hand frost effect: a slowly turning ring of ice shards with a cold core
## and a fine drift of frost motes. Reads as "gathering ice" at hand scale,
## where a shrunken storm cloud just reads as fog.

@export var ring_spin_speed: float = 0.9
@export var core_pulse_speed: float = 3.0

@onready var shard_ring: Node2D = $ShardRing
@onready var core: Sprite2D = $Core
@onready var motes: GPUParticles2D = $Motes
@onready var light: PointLight2D = $PointLight2D

var _time: float = 0.0

func play(size_scale: float = 1.0):
	scale = Vector2(size_scale, size_scale)
	if motes:
		motes.emitting = true

func stop() -> void:
	if motes:
		motes.emitting = false

func _process(delta: float) -> void:
	_time += delta
	if shard_ring:
		shard_ring.rotation += ring_spin_speed * delta
		# Shards breathe in and out of the ring
		var breathe: float = 1.0 + 0.12 * sin(_time * 2.1)
		shard_ring.scale = Vector2(breathe, breathe)
	if core:
		var pulse: float = 0.85 + 0.15 * sin(_time * core_pulse_speed)
		core.scale = Vector2(pulse, pulse)
	if light:
		light.energy = 0.28 + 0.08 * sin(_time * core_pulse_speed * 0.7)
