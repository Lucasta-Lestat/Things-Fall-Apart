extends Node
## Regression harness for the character rigs (the repo's first): sweeps every
## RigCharacters/<race>/CharacterMesh.tscn x every clip and asserts the
## foreshortening invariants hold. Headless-safe (no rendering assertions).
##
##  1. arm bone scale/skew stay in sane bounds (bad exporter output)
##  2. the grip world frame stays an unsheared, uniform similarity -- weapons
##     ride grip.global_rotation, so shear = wrong blade angles
##  3. melee reach: swing_*/thrust lose <8% reach vs foreshorten_strength = 0
##     (the silent range nerf foreshortened strike frames would cause)
##  4. IK ring: set_arm_ik lands the wrist on target (live calibration)
##  5. after death (HOLD action) the pose stays put
##
## Run:  godot --headless --path <proj> res://EditorScripts/RigProbe.tscn
## Prints RIGPROBE: lines; exit code 1 on any failure.

const PHASES := 24
const GRIP_TOL := 0.006          # rad skew / relative sx-sy mismatch
const SCALE_LO := 0.14
const SCALE_HI := 4.0
const REACH_KEEP := 0.92
const IK_TOL := 1.0              # px at rig scale 1

var fails := 0
var races := 0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	for d in DirAccess.get_directories_at("res://RigCharacters"):
		var p := "res://RigCharacters/%s/CharacterMesh.tscn" % d
		if ResourceLoader.exists(p):
			_check_race(d, p)
			races += 1
			await get_tree().process_frame
	var dt := (Time.get_ticks_msec() - t0) / 1000.0
	print("RIGPROBE: %d races in %.1fs -> %s" % [
		races, dt, "PASS" if fails == 0 else "FAIL (%d)" % fails])
	get_tree().quit(0 if fails == 0 else 1)


func _fail(race: String, msg: String) -> void:
	fails += 1
	print("RIGPROBE: FAIL %s: %s" % [race, msg])


func _bones(rig: Node2D) -> Array:
	var out := []
	for side: String in ["l", "r"]:
		var base := "Rig/Skeleton2D/root/upperarm_" + side
		for rel in [base, base + "/forearm_" + side,
				base + "/forearm_" + side + "/hand_" + side]:
			var n := rig.get_node_or_null(rel) as Node2D
			if n:
				out.append(n)
	return out


func _check_race(race: String, path: String) -> void:
	var scn: PackedScene = load(path)
	if scn == null:
		_fail(race, "scene failed to load")
		return
	var rig: Node2D = scn.instantiate()
	add_child(rig)
	rig.set_process(false)         # driven manually for determinism
	var ap := rig.get_node_or_null("AnimationPlayer") as AnimationPlayer
	if ap == null:
		_fail(race, "no AnimationPlayer")
		rig.queue_free()
		return
	var bones := _bones(rig)
	if bones.size() != 6:
		_fail(race, "expected 6 arm bones, found %d" % bones.size())
		rig.queue_free()
		return

	for clip in ap.get_animation_list():
		_sweep_clip(race, rig, ap, String(clip), bones)
	_ik_ring(race, rig)
	_death_hold(race, rig, ap, bones)
	rig.queue_free()


func _pose_at(rig: Node2D, ap: AnimationPlayer, clip: String, t: float) -> void:
	if ap.assigned_animation != clip:
		ap.play(clip)
	ap.seek(t, true)
	rig._fix_bone_tracks(10.0)     # big delta -> the clip-change blend is done


func _sweep_clip(race: String, rig: Node2D, ap: AnimationPlayer, clip: String, bones: Array) -> void:
	var anim := ap.get_animation(clip)
	if anim == null:
		return
	var reach_clip := clip.begins_with("swing") or clip == "thrust"
	var side := "l" if clip == "swing_left" else "r"
	for i in PHASES:
		var t := anim.length * float(i) / float(PHASES)
		# bounds + grip frame at full strength
		CharacterRig.foreshorten_strength = 1.0
		_pose_at(rig, ap, clip, t)
		for b in bones:
			var n: Node2D = b
			if n.scale.x < SCALE_LO or n.scale.x > SCALE_HI \
					or n.scale.y < SCALE_LO or n.scale.y > SCALE_HI:
				_fail(race, "%s@%.2f %s scale out of bounds %s" % [clip, t, n.name, n.scale])
				return
		for s: String in ["l", "r"]:
			var g := rig.get_node_or_null(
				"Rig/Skeleton2D/root/upperarm_%s/forearm_%s/hand_%s/grip_%s" % [s, s, s, s]) as Node2D
			if g == null:
				continue
			var gt := g.global_transform
			var sk := absf(gt.get_skew())
			var sc := gt.get_scale()
			var uni := absf(sc.x - sc.y) / maxf(absf(sc.x), 0.001)
			if sk > GRIP_TOL or uni > GRIP_TOL:
				_fail(race, "%s@%.2f grip_%s frame dirty: skew=%.4f sx-sy=%.4f" % [clip, t, s, sk, uni])
				return
		# melee reach vs strength 0
		if reach_clip:
			var r1: float = rig.chain_reach(side)
			CharacterRig.foreshorten_strength = 0.0
			rig._fix_bone_tracks(0.0)
			var r0: float = rig.chain_reach(side)
			CharacterRig.foreshorten_strength = 1.0
			if r0 > 0.0 and r1 < REACH_KEEP * r0:
				_fail(race, "%s@%.2f reach nerf: %.1f -> %.1f (%.0f%%)" % [clip, t, r0, r1, 100.0 * r1 / r0])
				return


func _ik_ring(race: String, rig: Node2D) -> void:
	var up := rig.get_node_or_null("Rig/Skeleton2D/root/upperarm_r") as Node2D
	var fo := rig.get_node_or_null("Rig/Skeleton2D/root/upperarm_r/forearm_r") as Node2D
	var ha := rig.get_node_or_null("Rig/Skeleton2D/root/upperarm_r/forearm_r/hand_r") as Node2D
	if up == null or fo == null or ha == null:
		return
	var radius := (fo.position.length() + ha.position.length()) * 0.75
	var worst := 0.0
	for i in 16:
		var ang := TAU * float(i) / 16.0
		var target := up.global_position + Vector2.from_angle(ang) * radius
		rig.set_arm_ik("r", target)
		rig._apply_ik(10.0)        # engage ramp completes in one big-delta call
		rig._apply_ik(10.0)
		worst = maxf(worst, ha.global_position.distance_to(target))
	rig.clear_arm_ik()
	if worst > IK_TOL:
		_fail(race, "IK ring worst error %.2f px" % worst)


func _death_hold(race: String, rig: Node2D, ap: AnimationPlayer, bones: Array) -> void:
	if not ap.has_animation("death"):
		return
	var anim := ap.get_animation("death")
	_pose_at(rig, ap, "death", anim.length)
	var snap := []
	for b in bones:
		var n: Node2D = b
		snap.append([n.rotation, n.scale, n.skew])
	for i in 60:
		rig._fix_bone_tracks(1.0 / 60.0)
	for i in bones.size():
		var n: Node2D = bones[i]
		var s: Array = snap[i]
		if absf(n.rotation - s[0]) > 1e-4 or not n.scale.is_equal_approx(s[1]) \
				or absf(n.skew - s[2]) > 1e-4:
			_fail(race, "death pose drifted on %s" % n.name)
			return
