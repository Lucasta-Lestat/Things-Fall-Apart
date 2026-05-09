class_name AnimatedPortrait
extends Node

# Frame-cycling speaking-portrait controller.
#
# Drives a TextureRect target by swapping its `texture` between an array of
# Texture2D frames where index 0 is the rest pose (mouth closed) and indices
# 1..N are mouth-open variants. While speaking, cycles through frames 1..N at
# FRAME_INTERVAL; when stopped, snaps back to frame 0. With <2 frames it does
# nothing -- callers can leave a static texture on the TextureRect.

const FRAME_INTERVAL := 0.12

var _target: TextureRect = null
var _frames: Array[Texture2D] = []
var _rest: Texture2D = null
var _timer: Timer = null
var _index: int = 0

func _ready() -> void:
	_timer = Timer.new()
	_timer.wait_time = FRAME_INTERVAL
	_timer.one_shot = false
	_timer.timeout.connect(_on_tick)
	add_child(_timer)

func bind(target: TextureRect) -> void:
	_target = target

func set_frames(frames: Array, rest: Texture2D) -> void:
	# Filter nulls -- ResourceLoader.load can return null for missing paths.
	_frames.clear()
	for f in frames:
		if f is Texture2D:
			_frames.append(f)
	_rest = rest
	_index = 0
	stop_speaking()

func has_animation() -> bool:
	return _frames.size() >= 2

func start_speaking() -> void:
	if _target == null or not has_animation():
		return
	if _timer == null or _timer.is_stopped():
		_index = 1
		_target.texture = _frames[_index]
		if _timer != null:
			_timer.start()

func stop_speaking() -> void:
	if _timer != null and not _timer.is_stopped():
		_timer.stop()
	if _target == null:
		return
	if _rest != null:
		_target.texture = _rest
	elif _frames.size() > 0:
		_target.texture = _frames[0]

func _on_tick() -> void:
	if _target == null or _frames.size() < 2:
		stop_speaking()
		return
	# Cycle indices 1..N-1, skipping 0 so the closed-mouth rest doesn't flash
	# mid-speech.
	var open_count := _frames.size() - 1
	_index = 1 + (((_index - 1) + 1) % open_count)
	_target.texture = _frames[_index]
