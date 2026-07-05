# SwarmVisualController.gd
#
# Makes a normal combatant render as a BoidField swarm instead of its procedural
# body. Lives under the SCENE ROOT (the BoidField simulates in world space and
# pins its own position to the origin, so it must NOT be a child of the moving
# actor). Each physics frame it re-centres the swarm on the actor; it hides the
# actor's procedural geometry and despawns the swarm when the actor dies or
# leaves the tree.
#
# Attached automatically by AbilityEffect._attach_swarm_visual() for any summoned
# character whose template has "swarm_visual": "<preset>".
class_name SwarmVisualController
extends Node2D

# Keep the swarm clustered tight around the unit (a single combatant), rather
# than letting it roam the preset's full free-swarm bounds.
const UNIT_BOUNDS_HALF := Vector2(60, 60)
const UNIT_SPAWN_RADIUS := 36.0

var _actor: Node = null
var _field: BoidField = null

func setup(actor: Node, preset: String) -> void:
	_actor = actor
	if not is_instance_valid(_actor):
		queue_free()
		return

	# No GPU compute -> leave the normal procedural body visible, do nothing.
	if not is_instance_valid(BoidServer) or not BoidServer.is_available():
		queue_free()
		return

	# Hide the procedural body; HP bar / selection / collision stay intact.
	if _actor.has_method("_set_procedural_geometry_visible"):
		_actor._set_procedural_geometry_visible(false)

	var start_pos: Vector2 = _actor.global_position
	# Tight containment + a firm home pull keeps the swarm reading as one unit
	# that tracks the actor, while separation/wander keep it from collapsing to a
	# point (we deliberately do NOT seek the exact centre — see _physics_process).
	_field = BoidField.spawn(self, preset, start_pos, {
		"bounds_half": UNIT_BOUNDS_HALF,
		"spawn_radius": UNIT_SPAWN_RADIUS,
		"home_weight": 1.3,
	})

	if _actor.has_signal("character_died"):
		_actor.character_died.connect(_on_actor_gone)
	_actor.tree_exiting.connect(_on_actor_gone)

func _physics_process(_delta: float) -> void:
	if not is_instance_valid(_actor) or not is_instance_valid(_field):
		return
	# Re-centre the swarm on the unit; the home pull (not a hard target) keeps it
	# clustered while it scurries, so it stays a loose cloud rather than a knot.
	_field.set_anchor(_actor.global_position)

func _on_actor_gone() -> void:
	# Death does not free the character (it becomes a corpse), so react to the
	# signal rather than relying on our own _exit_tree.
	set_physics_process(false)
	if is_instance_valid(_field):
		_field.despawn(0.6)
		_field = null
	queue_free()
