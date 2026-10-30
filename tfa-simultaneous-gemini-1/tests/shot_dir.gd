extends RefCounted
# Where a windowed QA shot writes its images (tests/*_shot.gd, the previews,
# the benches' optional screenshot). Never the project: a PNG there gets an
# .import on the next scan and can end up committed, and a render from a
# fallback driver (D3D12 when Vulkan is down) must never reach a TFA tree.
# An env path inside the project (or relative, or res://) is refused and the
# shot goes to user://shots instead; an unset one defaults there too. The
# resolved directory is printed, so the run log says where the images went.
#   const ShotDir := preload("res://tests/shot_dir.gd")
#   var out_dir := ShotDir.dir()                    # TFA_SHOT_DIR or user://shots
#   var path := ShotDir.file(OS.get_environment("TFA_SHOT"), "render_map.png")

const DEFAULT_DIR := "user://shots"


## The directory named by env_name, or user://shots when it is unset or inside
## the project. optional: "" when env_name is unset (the caller saves nothing).
static func dir(env_name: String = "TFA_SHOT_DIR", optional: bool = false) -> String:
	var want := OS.get_environment(env_name).strip_edges().replace("\\", "/").trim_suffix("/")
	if want == "" and optional:
		return ""
	var out := _outside_project(want, env_name)
	if out == "":
		out = ProjectSettings.globalize_path(DEFAULT_DIR)
	DirAccess.make_dir_recursive_absolute(out)
	print("shot dir: %s" % out)
	return out


## A shot file: path when it lies outside the project, else default_name (or
## path's own file name) under user://shots.
static func file(path: String, default_name: String) -> String:
	var want := path.strip_edges().replace("\\", "/")
	var fname := default_name
	var out_dir := ""
	if want != "":
		if want.get_file() != "":
			fname = want.get_file()
		var base := want.get_base_dir()
		out_dir = _outside_project(base if base != "" else ".", "shot path")
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path(DEFAULT_DIR)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var out := "%s/%s" % [out_dir, fname]
	print("shot file: %s" % out)
	return out


# want as an absolute directory outside the project, else "" (with a warning
# when want was set but refused). Any Godot project counts, not only this one:
# another checkout or worktree of TFA would import the images just the same.
static func _outside_project(want: String, what: String) -> String:
	if want == "":
		return ""
	var full := ProjectSettings.globalize_path(want).replace("\\", "/").simplify_path().trim_suffix("/")
	var project := ProjectSettings.globalize_path("res://").replace("\\", "/").trim_suffix("/")
	var low := full.to_lower()
	var proj_low := project.to_lower()
	if not full.is_absolute_path() or low == proj_low or low.begins_with(proj_low + "/") \
			or _in_godot_project(full):
		push_warning("%s (%s) is inside a Godot project or relative: shots go to %s instead" % [
			what, want, ProjectSettings.globalize_path(DEFAULT_DIR)])
		return ""
	return full


# True when dir or one of its ancestors holds a project.godot.
static func _in_godot_project(dir: String) -> bool:
	var d := dir
	while d != "":
		if FileAccess.file_exists(d.trim_suffix("/") + "/project.godot"):
			return true
		var parent := d.get_base_dir()
		if parent == d:
			break
		d = parent
	return false
