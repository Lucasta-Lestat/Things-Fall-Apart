class_name FogData
extends Resource

@export var color: Color = Color(0.8, 0.8, 0.8, 0.5)
@export var size: Vector2 = Vector2(1920, 1080)
@export var density: float = 0.5
@export var scale: float = 4.0
@export var speed: Vector2 = Vector2(0.02, 0.01)
# Silhouette shaping (see fog.gdshader). falloff_radius is relative to the rect's
# inscribed circle, so 1.0 means "fade out exactly at the middle of each edge" --
# leave it at or below 1.0 or the rect clips the cloud into a rectangle again.
@export var falloff_radius: float = 1.0
@export var falloff_softness: float = 0.5
@export var edge_wobble: float = 0.35
