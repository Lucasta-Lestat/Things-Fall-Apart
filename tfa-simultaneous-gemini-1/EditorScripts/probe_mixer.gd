extends Node
## Headless probe: does Godot's AnimationMixer mis-resolution of NESTED Bone2D
## tracks (known for :rotation -- forearm/hand collide onto one bone, summed;
## see CharacterRig._fix_bone_rotations) also hit :scale and :skew value tracks?
## And does a property with no track in the newly-played clip retain its value?
##
## Run:  godot --headless --path <proj> res://EditorScripts/MixerProbe.tscn
## Output lines are prefixed PROBE: for grep. Exit code 0 always (informational).

const SCENE := "res://RigCharacters/human_female/CharacterMesh.tscn"
const BONES := [
	"Rig/Skeleton2D/root/upperarm_l",
	"Rig/Skeleton2D/root/upperarm_l/forearm_l",
	"Rig/Skeleton2D/root/upperarm_l/forearm_l/hand_l",
	"Rig/Skeleton2D/root/upperarm_r",
	"Rig/Skeleton2D/root/upperarm_r/forearm_r",
	"Rig/Skeleton2D/root/upperarm_r/forearm_r/hand_r",
]

var rig: Node2D
var ap: AnimationPlayer


func _ready() -> void:
	var scn: PackedScene = load(SCENE)
	rig = scn.instantiate() as Node2D
	add_child(rig)
	# CharacterRig._ready has run (manual mixer mode, idle playing). Freeze its
	# _process so _fix_bone_rotations cannot repair anything -- we want the RAW
	# mixer behaviour.
	rig.set_process(false)
	ap = rig.get_node("AnimationPlayer")
	ap.stop()

	var lib := AnimationLibrary.new()
	lib.add_animation("t_rot", _make_anim("rotation", 0.10, 0.01))
	lib.add_animation("t_scale", _make_anim("scale", 0.90, 0.01))
	lib.add_animation("t_skew", _make_anim("skew", 0.10, 0.01))
	lib.add_animation("t_empty", _make_empty_anim())
	ap.add_animation_library("probe", lib)

	_run_case("t_rot", "rotation")
	_run_case("t_scale", "scale")
	_run_case("t_skew", "skew")
	_retention_case()

	print("PROBE: done")
	get_tree().quit(0)


func _make_anim(prop: String, base: float, step: float) -> Animation:
	# 6 constant tracks, one per arm bone, each with a DISTINCT value so any
	# collision (two tracks landing on one bone, possibly summed) is visible.
	var a := Animation.new()
	a.length = 1.0
	for i in BONES.size():
		var t := a.add_track(Animation.TYPE_VALUE)
		a.track_set_path(t, NodePath(BONES[i] + ":" + prop))
		a.value_track_set_update_mode(t, Animation.UPDATE_CONTINUOUS)
		var v = _value_for(prop, base + step * i)
		a.track_insert_key(t, 0.0, v)
		a.track_insert_key(t, 1.0, v)
	return a


func _make_empty_anim() -> Animation:
	# Drives something unrelated (Rig position) and NO bone properties.
	var a := Animation.new()
	a.length = 1.0
	var t := a.add_track(Animation.TYPE_VALUE)
	a.track_set_path(t, NodePath("Rig:position"))
	a.value_track_set_update_mode(t, Animation.UPDATE_CONTINUOUS)
	a.track_insert_key(t, 0.0, Vector2.ZERO)
	a.track_insert_key(t, 1.0, Vector2.ZERO)
	return a


func _value_for(prop: String, x: float):
	return Vector2(x, 1.0) if prop == "scale" else x


func _reset_bones() -> void:
	for p in BONES:
		var b := rig.get_node(p) as Node2D
		b.rotation = 0.0
		b.scale = Vector2.ONE
		b.skew = 0.0


func _read(prop: String, node: Node2D) -> float:
	var v = node.get(prop)
	return (v as Vector2).x if v is Vector2 else float(v)


func _run_case(anim: String, prop: String) -> void:
	_reset_bones()
	ap.play("probe/" + anim)
	ap.advance(0.5)
	var bad := 0
	for i in BONES.size():
		var node := rig.get_node(BONES[i]) as Node2D
		var expect := (0.90 if prop == "scale" else 0.10) + 0.01 * i
		var got := _read(prop, node)
		var ok := absf(got - expect) < 1e-4
		if not ok:
			bad += 1
		print("PROBE: %s %-10s expect=%.4f got=%.4f %s" % [
			prop, BONES[i].get_file(), expect, got, "OK" if ok else "MISMATCH"])
	print("PROBE: case %s -> %s" % [prop, "CLEAN" if bad == 0 else "%d MISMATCHES" % bad])


func _retention_case() -> void:
	# Play the scale clip, then a clip with no bone tracks: do scales persist?
	_reset_bones()
	ap.play("probe/t_scale")
	ap.advance(0.5)
	ap.play("probe/t_empty")
	ap.advance(0.5)
	var kept := 0
	for i in BONES.size():
		var node := rig.get_node(BONES[i]) as Node2D
		if absf(node.scale.x - (0.90 + 0.01 * i)) < 1e-4:
			kept += 1
	print("PROBE: retention -> %d/6 scales retained (%s)" % [
		kept, "RETAINED" if kept == 6 else "RESET OR CORRUPT"])
