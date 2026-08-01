extends Node
## Owns the game's default mouse cursor.
##
## Godot has no "project default custom cursor" that survives a hover swap:
## `Input.set_custom_mouse_cursor(null)` reverts to the OS arrow, not to ours.
## So every place that used to reset with null now calls `CursorManager.reset()`
## instead, and the default is applied once here at startup.
##
## Callers that set a hover cursor should still go through
## `Input.set_custom_mouse_cursor` directly — only the reset path needs routing
## through here.

const DEFAULT_CURSOR_PATH := "res://UI/default-cursor.png"
## The arrow's point sits in the top-left pixel of the image, so the click
## position and the drawn tip coincide with a zero hotspot.
const DEFAULT_HOTSPOT := Vector2.ZERO

var _default_cursor: Texture2D = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if ResourceLoader.exists(DEFAULT_CURSOR_PATH):
		var res = load(DEFAULT_CURSOR_PATH)
		if res is Texture2D:
			_default_cursor = res
	if _default_cursor == null:
		push_warning("CursorManager: missing %s; using the system cursor" % DEFAULT_CURSOR_PATH)
	reset()


## Restore the default cursor. Safe to call when no custom cursor is active.
func reset() -> void:
	if _default_cursor == null:
		Input.set_custom_mouse_cursor(null)
		return
	Input.set_custom_mouse_cursor(_default_cursor, Input.CURSOR_ARROW, DEFAULT_HOTSPOT)


## The default cursor texture, or null when the art is missing.
func default_texture() -> Texture2D:
	return _default_cursor
