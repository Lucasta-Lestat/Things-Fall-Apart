# Boid swarm system

GPU compute-shader flocking, rendered through `MultiMeshInstance2D`. One system,
two faces: **spell effects** (swirling motes) and **creature swarms** (rats,
insects, …). Everything runs on the GPU; results are read back once per physics
frame and pushed into a multimesh.

## Pieces

| File | Role |
|------|------|
| `vfx/shaders/boids.glsl` | Compute shader. Reynolds separation/alignment/cohesion + seek/flee, wander, home, bounds, and a tangential **swirl** (vortex) term. One invocation per agent, brute-force O(n²) neighbours. |
| `Global/BoidServer.gd` (autoload) | Owns one `RenderingDevice` + pipeline. Steps every registered field in a single dispatch/sync each `_physics_process`. Falls back gracefully (swarms inert) if the renderer has no compute support. |
| `vfx/swarm/BoidField.gd` (`class_name BoidField`) | One swarm: its agent buffer + a `MultiMeshInstance2D`. Sprite mode (rotated textures) or mote mode (additive/alpha glow). Public API below. |
| `vfx/swarm/BoidPresets.gd` (`class_name BoidPresets`) | Named configs: `rat_swarm`, `insect_swarm`, `arcane_motes`, `fire_swarm`, `spirit_wisps`. |
| `vfx/shaders/boid_sprite.gdshader` | Per-instance scurry squash/stretch for sprite swarms (driven by the gait phase the compute shader writes). |
| `vfx/swarm/BoidsDemo.tscn` | Playground. Run it directly; click to gather, right-click to scatter, number keys to spawn. |

## Spawning a swarm

**For spells** (one-liner, via the existing VFX autoload):

```gdscript
# Swirl of arcane motes at a cast point, auto-despawning after 4s
VfxSystem.create_boids(cast_pos, "arcane_motes", {"duration": 4.0})

# A directed swarm that seeks a victim, recoloured green, denser
VfxSystem.create_boids(cast_pos, "insect_swarm", {
    "target": victim.global_position,
    "color": Color(0.4, 0.7, 0.2),
    "count": 400,
})
```

**For creatures** (keep the handle so you can steer it):

```gdscript
var rats := BoidField.spawn(get_tree().current_scene, "rat_swarm", spawn_pos)
rats.set_target(player.global_position)   # chase
rats.set_anchor(nest_pos)                  # roam around a point (steers, no teleport)
rats.scatter(explosion_pos, 1.5)           # flee a point for 1.5s
rats.gather()                              # pull tightly back to the anchor
rats.despawn()                             # fade out and free
```

`params` / `overrides` accept **any** preset key (see `BoidPresets.DEFAULTS`),
plus `duration` and `target` for `create_boids`.

## Coordinates

Sim runs in **world/scene space**: the field node stays at the origin and agents
carry absolute positions. `anchor` is the home / bounds centre; moving it makes
the swarm *steer* to follow rather than teleport. Bounds = `anchor ± bounds_half`.

## Adding a preset

Add a dict to `BoidPresets.PRESETS`. Only override what differs from `DEFAULTS`.
Knobs that matter most:

- `render_mode`: `"sprite"` (needs `texture`, `sprite_size`, optional `gait`) or
  `"mote"` (needs `mote_size`, `additive`).
- `separation` / `alignment` / `cohesion`: the classic flocking weights.
- `swirl`: tangential orbit force — the difference between a clump and a vortex.
  Essential for magical swirls; keep `cohesion`/`home_weight` low when using it
  or the swarm collapses to a point (additive motes then blow out to white).
- `bounds_half` + `spawn_radius`: how big an area the swarm occupies.
- `max_speed` / `min_speed`: `min_speed > 0` keeps things perpetually moving
  (rats scurry, motes orbit).

## Performance

Neighbour search is O(n²) per frame on the GPU — fine for the tens-to-low-thousands
this game uses. Many small swarms are cheap (all share one device, one dispatch
cycle). If you ever need 10k+ agents in one field, add a spatial-hash grid in
`boids.glsl`. To avoid the per-frame CPU readback entirely at extreme scale, the
agent buffer could be written straight into the multimesh buffer via
`RenderingServer.multimesh_get_buffer_rd_rid()` on the main device.

`BoidServer` runs with `PROCESS_MODE_ALWAYS` so swarms keep moving while the
tactical layer is paused (matching the TIME-driven VFX). Flip it to
`PROCESS_MODE_PAUSABLE` in `BoidServer._ready()` if you'd rather they freeze.
