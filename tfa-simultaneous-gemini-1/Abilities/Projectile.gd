class_name Projectile
extends CharacterBody2D

## Unified physics-based projectile.
##
## Per-frame swept movement via move_and_collide. On first contact with anything
## on PROJECTILE_HIT_MASK (structures + characters), emits `hit(collision)` and
## frees itself. If the projectile travels `max_range` or lives for
## `max_lifetime`, it emits `expired(final_position)` and frees itself.
##
## The visual is the caller's responsibility — instantiate this script (no scene
## file needed), add your sprite as a child, then call `launch()`. The script
## adds its own CollisionShape2D in _ready unless one is already present, so
## callers that want a custom shape (e.g. a capsule for arrows) can add it
## before the node enters the tree.
##
## Pause integrity: physics step is gated on PauseManager.is_paused so a paused
## game does not advance the projectile.

signal hit(collision: KinematicCollision2D)
signal expired(final_position: Vector2)

@export var speed: float = 1200.0
@export var max_range: float = 900.0
@export var max_lifetime: float = 5.0
@export var collision_radius: float = 4.0

var direction: Vector2 = Vector2.RIGHT
var distance_traveled: float = 0.0
var elapsed: float = 0.0
var _launched: bool = false


func _ready() -> void:
	collision_layer = CollisionLayers.PROJECTILES
	collision_mask = CollisionLayers.PROJECTILE_HIT_MASK
	if not _has_collision_shape():
		var cs := CollisionShape2D.new()
		var circle := CircleShape2D.new()
		circle.radius = collision_radius
		cs.shape = circle
		add_child(cs)


## Position the projectile and start moving in `dir`. `shooter` is added as a
## collision exception so the projectile does not impact the firer's own body
## on its first step. Call after the projectile is in the scene tree.
func launch(from_pos: Vector2, dir: Vector2, shooter: CollisionObject2D = null) -> void:
	global_position = from_pos
	direction = dir.normalized()
	rotation = direction.angle()
	if shooter != null:
		add_collision_exception_with(shooter)
	_launched = true


func _physics_process(delta: float) -> void:
	if PauseManager.is_paused or not _launched:
		return
	elapsed += delta
	if elapsed >= max_lifetime:
		_expire()
		return
	var step := direction * speed * delta
	var collision := move_and_collide(step)
	if collision != null:
		hit.emit(collision)
		queue_free()
		return
	distance_traveled += step.length()
	if distance_traveled >= max_range:
		_expire()


func _expire() -> void:
	expired.emit(global_position)
	queue_free()


func _has_collision_shape() -> bool:
	for child in get_children():
		if child is CollisionShape2D:
			return true
	return false
