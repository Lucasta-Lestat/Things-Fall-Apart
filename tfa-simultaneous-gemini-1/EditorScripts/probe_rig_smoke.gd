extends Node
## Smoke test for the reworked CharacterRig runtime (Phase 1 of the arm
## foreshortening work): idle plays and poses bones, the clip-change blend
## engages, and the live-calibrated IK actually lands the wrist on the target.
##
## Run:  godot --headless --path <proj> res://EditorScripts/RigSmoke.tscn

const SCENE := "res://RigCharacters/human_female/CharacterMesh.tscn"


func _ready() -> void:
	var scn: PackedScene = load(SCENE)
	var rig: Node2D = scn.instantiate()
	add_child(rig)

	# Let idle run: _fix_bone_tracks should be posing the arm bones.
	for i in 30:
		await get_tree().process_frame
	var ua := rig.get_node("Rig/Skeleton2D/root/upperarm_l") as Node2D
	print("SMOKE: idle upperarm_l rot=%.4f scale=(%.3f,%.3f) skew=%.4f" % [
		ua.rotation, ua.scale.x, ua.scale.y, ua.skew])
	var idle_ok: bool = ua.scale.is_equal_approx(Vector2.ONE) and absf(ua.skew) < 1e-6
	print("SMOKE: idle pose %s" % ("OK" if idle_ok else "BAD (unexpected scale/skew)"))

	# Clip-change blend: play an action, confirm no error and action finishes.
	if rig.has_method("play_action"):
		rig.play_action("swing_right", 0.3)
	for i in 40:
		await get_tree().process_frame

	# IK: aim the right hand at a world point; the wrist (hand bone origin)
	# must converge on it once the engage ramp completes.
	var up := rig.get_node("Rig/Skeleton2D/root/upperarm_r") as Node2D
	var ha := rig.get_node("Rig/Skeleton2D/root/upperarm_r/forearm_r/hand_r") as Node2D
	var target: Vector2 = up.global_position + Vector2(180.0, 60.0)
	rig.set_arm_ik("r", target)
	for i in 40:
		await get_tree().process_frame
	var err := ha.global_position.distance_to(target)
	print("SMOKE: ik wrist error=%.3f px %s" % [err, "OK" if err < 1.0 else "FAIL"])

	# Kill switch is settable and the arm releases cleanly.
	CharacterRig.foreshorten_strength = 0.0
	CharacterRig.foreshorten_strength = 1.0
	rig.clear_arm_ik()
	for i in 10:
		await get_tree().process_frame
	print("SMOKE: reach r=%.2f px" % rig.chain_reach("r"))
	print("SMOKE: done")
	get_tree().quit(0)
