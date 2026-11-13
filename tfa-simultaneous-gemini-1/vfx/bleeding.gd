extends Node2D

# Bleeding VFX, two uses of one scene:
#  - play(): the persistent drip while the "bleeding" condition is active
#    (ProceduralCharacter._spawn_condition_vfx; stop() + free on removal).
#  - burst(): a one-shot spatter on a cutting/piercing hit or a severed limb
#    (ProceduralCharacter._spawn_bleed_burst). A burst-only instance frees
#    itself when its droplets have landed.
# Both particle nodes ship with emitting = false: they used to default to
# emitting, so every hit's burst node left a permanent dripping emitter on the
# character -- alive or dead -- that nothing ever freed.
# Particles are drawn with a soft 16px dot (bleeding.tscn): untextured
# GPUParticles2D draw 1px squares scaled up, which read as red squares.

@onready var drip_particles: GPUParticles2D = $DripParticles
@onready var mist_particles: GPUParticles2D = $MistParticles

var _persistent := false
var _bursts_live := 0

func play(size_scale: float = 1.0) -> void:
	_persistent = true
	_scale_particles(drip_particles, size_scale)
	_scale_particles(mist_particles, size_scale)
	drip_particles.emitting = true
	mist_particles.emitting = true

func stop() -> void:
	_persistent = false
	drip_particles.emitting = false
	mist_particles.emitting = false

func _scale_particles(p: GPUParticles2D, size_scale: float) -> void:
	if not p:
		return
	var mat = p.process_material.duplicate() as ParticleProcessMaterial
	p.process_material = mat
	mat.scale_min *= size_scale
	mat.scale_max *= size_scale
	mat.initial_velocity_min *= size_scale
	mat.initial_velocity_max *= size_scale
	p.amount = max(1, int(p.amount * size_scale))

# A short, one-shot spatter of droplets thrown outward from the wound.
func burst(amount_multiplier: float = 1.0) -> void:
	if not drip_particles:
		return
	var one_shot: GPUParticles2D = drip_particles.duplicate() as GPUParticles2D
	var mat := (drip_particles.process_material as ParticleProcessMaterial).duplicate() as ParticleProcessMaterial
	mat.spread = 180.0
	mat.initial_velocity_min = 25.0
	mat.initial_velocity_max = 85.0
	mat.gravity = Vector3(0, 40, 0)
	mat.damping_min = 6.0
	mat.damping_max = 10.0
	one_shot.process_material = mat
	one_shot.one_shot = true
	one_shot.explosiveness = 0.9
	one_shot.lifetime = 0.7
	one_shot.amount = clampi(int(10.0 * amount_multiplier), 4, 40)
	add_child(one_shot)
	one_shot.emitting = true
	_bursts_live += 1
	one_shot.finished.connect(_on_burst_finished.bind(one_shot), CONNECT_ONE_SHOT)

func _on_burst_finished(one_shot: GPUParticles2D) -> void:
	if is_instance_valid(one_shot):
		one_shot.queue_free()
	_bursts_live -= 1
	if not _persistent and _bursts_live <= 0:
		queue_free()
