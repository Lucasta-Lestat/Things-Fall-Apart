# skeletal_body_rig.gd
# Manifest-driven body rig for characters sliced from a single contiguous drawing.
#
# WHY THIS EXISTS (vs body_part_sprites.gd):
#   The legacy BodyPartSprites scaled each part to a different per-axis race
#   dimension (head_width, body_height, arm-segment lengths...), which distorted
#   the relative proportions of art authored as one coherent figure, and
#   positioned parts in a different coordinate space than the one they were sized
#   in — producing gaps. This rig instead consumes a JOINT MANIFEST emitted at
#   slice time (scripts/extract_male_elf_body_parts.py -> body_manifest.json):
#     * every part keeps the source art's exact proportions (ONE uniform scale)
#     * parts are chained by shared joints (elbow<->elbow, shoulder<->shoulder,
#       neck<->neck), so the figure reassembles GAP-FREE by construction
#     * each part is oriented from its own manifest joints to a body axis, then
#       animated by rotating about its proximal joint (its pivot)
#
# The rig drives head + torso + both arms. Legs stay procedural (a true top-down
# pose foreshortens legs to feet) — leg.png is swung by the walk cycle at the SAME
# uniform scale so it matches the manifest parts.
#
# COORDINATE SPACE: the rig is a child of the character at local origin, so
# rig-local == character-local. Character faces -Y (FRONT); legs/back are +Y.
#
# Single knob: render_scale (source px -> game units), from body_scale or derived
# so the art's shoulder span equals body_width. All joint geometry is data in the
# manifest — calibration is a JSON edit + re-run, never a code change.
extends Node2D
class_name SkeletalBodyRig

const FRONT := Vector2(0, -1)   # character forward (head)
const BACK := Vector2(0, 1)     # character backward (hips/legs)

var manifest: Dictionary = {}
var _parts: Dictionary = {}
var _attach: Array = []
var _base_dir: String = ""
var _unit_px: float = 1.0

# Hand-tunable calibration from manifest["tuning"] (see the extractor).
var _head_overlap_px: float = 0.0          # sink head onto torso along body axis
var _rot_offset: Dictionary = {}           # base-part -> extra rotation (radians)
var _leg_reverse: bool = false             # legacy procedural-leg flip (schema 1 only)
var _manifest_path: String = ""            # remembered for live reload

var _sprites: Dictionary = {}    # logical key -> Sprite2D

var render_scale: float = 0.065
var shoulder_y: float = 0.0      # character-local y of the shoulder line

var _leg_tex: Texture2D = null

const Z_HEAD := 1
const Z_TORSO := -1
const Z_ARM := -2
const Z_LEG := -3


static func manifest_path_for(head_sprite_path: String) -> String:
	return head_sprite_path.get_base_dir() + "/body_manifest.json"


static func has_manifest(head_sprite_path: String) -> bool:
	if head_sprite_path == "":
		return false
	return ResourceLoader.exists(manifest_path_for(head_sprite_path)) \
		or FileAccess.file_exists(manifest_path_for(head_sprite_path))


func load_manifest(path: String) -> bool:
	var txt := ""
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f:
			txt = f.get_as_text()
			f.close()
	if txt == "":
		push_warning("[SkeletalBodyRig] manifest not found/empty: " + path)
		return false
	var parsed = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[SkeletalBodyRig] manifest not a JSON object: " + path)
		return false
	manifest = parsed
	_manifest_path = path
	_base_dir = path.get_base_dir()
	_parts = manifest.get("parts", {})
	_attach = manifest.get("attach", [])
	var up = manifest.get("unit_px", 1.0)
	_unit_px = float(up) if up != null else 1.0
	_apply_tuning(manifest.get("tuning", {}))
	return true


func _apply_tuning(tuning: Dictionary) -> void:
	var ho = tuning.get("head_overlap_px", 0.0)
	_head_overlap_px = float(ho) if ho != null else 0.0
	_rot_offset.clear()
	var ro: Dictionary = tuning.get("rot_offset_deg", {})
	for k in ro:
		_rot_offset[k] = deg_to_rad(float(ro[k]))
	var lr = tuning.get("leg_reverse", false)
	_leg_reverse = bool(lr) if lr != null else false


## Live-tuning helper: re-read the manifest JSON from disk and re-apply the tuning
## block (rotations / overlap / flips) without rebuilding sprites. Returns the
## fresh tuning dict so the caller can print it. Used by the in-game reload key.
func reload_tuning() -> Dictionary:
	if _manifest_path == "" or not FileAccess.file_exists(_manifest_path):
		return {}
	var f := FileAccess.open(_manifest_path, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return {}
	var tuning: Dictionary = parsed.get("tuning", {})
	_apply_tuning(tuning)
	return tuning


func _offset_for(key: String) -> float:
	return float(_rot_offset.get(_base_key(key), 0.0))


func get_unit_px() -> float:
	return _unit_px


# ===== build =====

func build(leg_sprite_path: String = "") -> void:
	_clear()
	# Every part is native art keyed directly in the manifest — no flip_h.
	_make_sprite("head", _file_for("head"), Z_HEAD)
	_make_sprite("torso", _file_for("torso"), Z_TORSO)
	for arm_key in ["upper_arm_l", "forearm_l", "upper_arm_r", "forearm_r"]:
		_make_sprite(arm_key, _file_for(arm_key), Z_ARM)

	# Feet: prefer per-side leg_l/leg_r manifest parts (schema 2, art-driven,
	# pivot-anchored at the ankle). Fall back to a single procedural leg sprite
	# (schema 1 / legacy) if the manifest has no feet but a leg path was passed.
	if _parts.has("leg_l") and _parts.has("leg_r"):
		_make_sprite("leg_l", _file_for("leg_l"), Z_LEG)
		_make_sprite("leg_r", _file_for("leg_r"), Z_LEG)
	elif leg_sprite_path != "" and ResourceLoader.exists(leg_sprite_path):
		_leg_tex = load(leg_sprite_path)
		_make_proc_leg("leg_l")
		_make_proc_leg("leg_r")

	_apply_static_offsets()


func _file_for(key: String) -> String:
	return _base_dir + "/" + str(_resolve_part(key).get("file", key + ".png"))


func _make_sprite(key: String, path: String, z: int) -> void:
	var s := Sprite2D.new()
	s.name = key.capitalize().replace("_", "")
	s.centered = false       # offset places the pivot exactly at the node origin
	s.z_index = z
	if ResourceLoader.exists(path):
		s.texture = load(path)
	add_child(s)
	_sprites[key] = s


func _make_proc_leg(key: String) -> void:
	# Legacy/schema-1 procedural leg (centered, swung by update_legs).
	var s := Sprite2D.new()
	s.name = key.capitalize().replace("_", "")
	s.centered = true
	s.z_index = Z_LEG
	s.texture = _leg_tex
	s.scale = Vector2(render_scale, render_scale)
	add_child(s)
	_sprites[key] = s


# ===== manifest geometry helpers =====
# schema 2: every logical key (head, torso, upper_arm_l, forearm_r, leg_l, ...)
# maps DIRECTLY to its own manifest part. Arms are cut natively per side, so no
# flip_h is ever applied — _oriented is now an identity pass kept for call-site
# stability. A schema-1 manifest (shared upper_arm/forearm) still resolves via the
# _resolve_part fallback below so old single-arm races don't break.

func _resolve_part(logical: String) -> Dictionary:
	if _parts.has(logical):
		return _parts[logical]
	# schema-1 fallback: strip the _l/_r suffix to the shared base part.
	if logical.begins_with("upper_arm"):
		return _parts.get("upper_arm", {})
	if logical.begins_with("forearm"):
		return _parts.get("forearm", {})
	if logical.begins_with("leg"):
		return _parts.get("leg", {})
	return {}


func _base_key(logical: String) -> String:
	# Rotation-offset key: per-side (upper_arm_l) falls back to the base (upper_arm).
	if _rot_offset.has(logical):
		return logical
	if logical.begins_with("upper_arm"):
		return "upper_arm"
	if logical.begins_with("forearm"):
		return "forearm"
	if logical.begins_with("leg"):
		return "leg"
	return logical


func _raw_pivot(logical: String) -> Vector2:
	var v = _resolve_part(logical).get("pivot", [0, 0])
	return Vector2(float(v[0]), float(v[1]))


func _raw_joint(logical: String, joint: String) -> Vector2:
	var j = _resolve_part(logical).get("joints", {}).get(joint, null)
	if j == null:
		return _raw_pivot(logical)
	return Vector2(float(j[0]), float(j[1]))


# Identity now (native per-side art, no mirroring). Kept so call sites are stable.
func _oriented(_s: Sprite2D, p: Vector2) -> Vector2:
	return p


func _apply_static_offsets() -> void:
	for key in _sprites:
		var s: Sprite2D = _sprites[key]
		# Legacy procedural legs are centered with no manifest part; skip them.
		if key.begins_with("leg") and not _parts.has(key):
			continue
		s.offset = -_raw_pivot(key)                 # pivot pixel -> node origin
		s.scale = Vector2(render_scale, render_scale)


# World (rig-local) position of a joint on an already-placed sprite.
func _joint_world(key: String, joint: String) -> Vector2:
	var s: Sprite2D = _sprites.get(key)
	if s == null:
		return Vector2.ZERO
	var local := (_raw_joint(key, joint) - _raw_pivot(key)) * render_scale
	return s.position + local.rotated(s.rotation)


# Rotation aligning a part's local proximal->aim axis to a world direction.
func _align_rotation(key: String, aim_local: Vector2, prox_local: Vector2, world_dir: Vector2, extra: float) -> float:
	var local := aim_local - prox_local
	if local.length() < 0.001 or world_dir.length() < 0.001:
		return extra
	return world_dir.angle() - local.angle() + extra


# ===== per-frame pose =====

func update_pose(body_rotation: float, left_ik: Array, right_ik: Array) -> void:
	var torso: Sprite2D = _sprites.get("torso")
	if torso == null:
		return

	# --- Torso: orient neck->hip-midpoint toward BACK (+Y), anchor shoulders. ---
	var t_neck := _oriented(torso, _raw_pivot("torso"))
	var hipmid := (_oriented(torso, _raw_joint("torso", "hip_l")) \
		+ _oriented(torso, _raw_joint("torso", "hip_r"))) * 0.5
	var torso_rot := _align_rotation("torso", hipmid, t_neck, BACK, body_rotation + _offset_for("torso"))
	torso.rotation = torso_rot
	# Place so the shoulder-midpoint lands on (0, shoulder_y).
	var smid := (_oriented(torso, _raw_joint("torso", "shoulder_l")) \
		+ _oriented(torso, _raw_joint("torso", "shoulder_r"))) * 0.5
	var smid_off := ((smid - t_neck) * render_scale).rotated(torso_rot)
	torso.position = Vector2(0.0, shoulder_y) - smid_off

	# --- Head: pin neck onto torso neck, then sink it toward BACK by the tuned
	#     overlap so it seats on the torso instead of floating. Orient neck->crown
	#     toward FRONT (-Y). ---
	var head: Sprite2D = _sprites.get("head")
	if head:
		# torso pivot is the neck, so torso.position is the neck in world space.
		var back_world := BACK.rotated(torso_rot)
		head.position = torso.position + back_world * (_head_overlap_px * render_scale)
		var h_neck := _oriented(head, _raw_pivot("head"))
		var h_crown := _oriented(head, _raw_joint("head", "crown"))
		head.rotation = _align_rotation("head", h_crown, h_neck, FRONT, body_rotation + _offset_for("head"))

	# --- Arms: anchored at torso shoulder joints, angled by the IK chain. ---
	_update_arm("l", left_ik, body_rotation)
	_update_arm("r", right_ik, body_rotation)


func _update_arm(side: String, ik: Array, body_rotation: float) -> void:
	var ua: Sprite2D = _sprites.get("upper_arm_" + side)
	var fa: Sprite2D = _sprites.get("forearm_" + side)
	if ua == null or fa == null:
		return

	# Each arm is native per-side art (no flip). Upper arm sits at the torso's
	# shoulder joint; its angle comes from the IK shoulder->elbow direction.
	ua.position = _joint_world("torso", "shoulder_" + side)
	var ua_dir: Vector2 = BACK if ik.size() < 2 else (ik[1] - ik[0])
	var ua_prox := _raw_joint("upper_arm_" + side, "shoulder")
	var ua_aim := _raw_joint("upper_arm_" + side, "elbow")
	ua.rotation = _align_rotation("upper_arm_" + side, ua_aim, ua_prox, ua_dir, _offset_for("upper_arm_" + side))

	# Forearm at the upper arm's elbow joint; angle from IK elbow->hand.
	fa.position = _joint_world("upper_arm_" + side, "elbow")
	var fa_dir: Vector2 = ua_dir
	if ik.size() >= 4:
		fa_dir = ik[3] - ik[1]
	elif ik.size() >= 3:
		fa_dir = ik[2] - ik[1]
	var fa_prox := _raw_joint("forearm_" + side, "elbow")
	var fa_aim := _raw_joint("forearm_" + side, "wrist")
	fa.rotation = _align_rotation("forearm_" + side, fa_aim, fa_prox, fa_dir, _offset_for("forearm_" + side))


# ===== legs / feet =====
# schema 2: leg_l/leg_r are pivot-anchored foot sprites (ankle pivot). We place
# the ankle at the hip and orient ankle->toe along the leg direction.
# schema 1 (legacy): centered leg sprites swung about their midpoint.

func update_legs(left_hip: Vector2, left_foot: Vector2, right_hip: Vector2, right_foot: Vector2) -> void:
	_place_leg("leg_l", left_hip, left_foot)
	_place_leg("leg_r", right_hip, right_foot)


func _place_leg(key: String, hip: Vector2, foot: Vector2) -> void:
	var s: Sprite2D = _sprites.get(key)
	if s == null:
		return
	var dir := foot - hip
	if _parts.has(key):
		# Art-driven foot: ankle pivot pinned at the hip, ankle->toe aligned to dir.
		s.position = hip
		if dir.length() > 0.001:
			var prox := _raw_joint(key, "ankle")
			var aim := _raw_joint(key, "toe")
			s.rotation = _align_rotation(key, aim, prox, dir, _offset_for("leg_" + key.substr(4)))
	else:
		# Legacy centered leg.
		s.position = (hip + foot) * 0.5
		if dir.length() > 0.001:
			var base := PI / 2.0 if _leg_reverse else -PI / 2.0
			s.rotation = dir.angle() + base


# ===== color / visibility =====

func set_skin_color(color: Color) -> void:
	for key in _sprites:
		_sprites[key].modulate = color


func set_all_visible(v: bool) -> void:
	for key in _sprites:
		_sprites[key].visible = v


func _clear() -> void:
	for c in get_children():
		c.queue_free()
	_sprites.clear()
