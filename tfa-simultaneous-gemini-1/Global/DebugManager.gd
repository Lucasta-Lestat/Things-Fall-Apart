# DebugManager.gd
# Single source of truth for whether debug visualizations and verbose
# logging are active. Toggle with F12 (handled in Game.gd).
# Other systems (CollisionVisualizer, WeaponShape, debug windows) should
# connect to enabled_changed and react.
extends Node

signal enabled_changed(value: bool)

var enabled: bool = false

func toggle() -> void:
	set_enabled(not enabled)

func set_enabled(v: bool) -> void:
	if v == enabled:
		return
	enabled = v
	emit_signal("enabled_changed", v)
