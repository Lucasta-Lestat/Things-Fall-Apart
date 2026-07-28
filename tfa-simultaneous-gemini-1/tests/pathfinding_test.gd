# res://tests/pathfinding_test.gd
# Headless assertion harness for the A* rewrite (heap open set + unreachable
# early-out) and for GridManager.reachable_within.
# Run:  godot --headless --path . res://tests/pathfinding_test.gd.tscn
#
# The load-bearing test here is DIFFERENTIAL: _reference_astar below is a
# verbatim copy of the linear-scan search that shipped before the heap, and
# every randomized query is run through both. The optimisation is only allowed
# to be faster, never to change an answer.
extends Node2D

var failures := 0

func _check(check_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		print("PASS %s" % check_name)
	else:
		failures += 1
		print("FAIL %s: %s" % [check_name, detail])

func _ready() -> void:
	_scenario_heap_ordering()
	_scenario_differential_vs_reference()
	_scenario_early_out()
	_scenario_reachable_within()
	_scenario_reachable_matches_find_path()
	_scenario_sealed_pocket()
	print("\n%s (%d failure(s))" % ["ALL PASS" if failures == 0 else "FAILURES", failures])
	get_tree().quit(1 if failures > 0 else 0)

# --- the pre-heap implementation, kept as an oracle -------------------------
# Verbatim from GridManager._find_path_walk before the heap landed, except that
# it calls into the live _get_neighbors/step_cost so the graph itself is shared
# and only the search loop differs.
func _reference_astar(start_pos: Vector2i, end_pos: Vector2i) -> Array:
	var open_set: Array = [start_pos]
	var came_from: Dictionary = {}
	var g_score: Dictionary = { start_pos: 0 }
	var f_score: Dictionary = { start_pos: GridManager._heuristic(start_pos, end_pos) }
	while not open_set.is_empty():
		var current = open_set[0]
		for pos in open_set:
			if f_score.get(pos, INF) < f_score.get(current, INF):
				current = pos
		if current == end_pos:
			var path: Array = [current]
			while current in came_from:
				current = came_from[current]
				path.push_front(current)
			path.pop_front()
			return path
		open_set.erase(current)
		for neighbor in GridManager._get_neighbors(current):
			var tentative = g_score.get(current, INF) + GridManager.step_cost(neighbor)
			if tentative < g_score.get(neighbor, INF):
				came_from[neighbor] = current
				g_score[neighbor] = tentative
				f_score[neighbor] = tentative + GridManager._heuristic(neighbor, end_pos)
				if not open_set.has(neighbor):
					open_set.append(neighbor)
	return []

func _path_cost(path: Array) -> float:
	var c := 0.0
	for t in path:
		c += GridManager.step_cost(t)
	return c

# Tiles are laid out so every step costs exactly 1.0, which makes step count and
# path cost the same number and lets reachable_within be compared against
# find_path directly.
func _build_grid(w: int, h: int, blocked: Array) -> void:
	GridManager.initialize(w * GridManager.TILE_SIZE, h * GridManager.TILE_SIZE)
	for t in blocked:
		GridManager.register_obstacle(t)

func _random_grid(w: int, h: int, fill: float, rng: RandomNumberGenerator) -> void:
	GridManager.initialize(w * GridManager.TILE_SIZE, h * GridManager.TILE_SIZE)
	for y in range(h):
		for x in range(w):
			if rng.randf() < fill:
				GridManager.register_obstacle(Vector2i(x, y))

# --- 1. the heap is actually a heap -----------------------------------------
func _scenario_heap_ordering() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260727
	var heap: Array = []
	var pushed: Array[float] = []
	for i in range(400):
		var f := rng.randf_range(-500.0, 500.0)
		pushed.append(f)
		GridManager._heap_push(heap, f, Vector2i(i, 0))
	pushed.sort()
	var popped: Array[float] = []
	while not heap.is_empty():
		popped.append(float(GridManager._heap_pop(heap)[0]))
	_check("heap.pops-in-sorted-order", popped == pushed,
		"first divergence out of %d" % popped.size())
	# duplicate keys must not lose entries
	var h2: Array = []
	for i in range(50):
		GridManager._heap_push(h2, 7.0, Vector2i(i, 1))
	var n := 0
	while not h2.is_empty():
		GridManager._heap_pop(h2)
		n += 1
	_check("heap.keeps-duplicate-keys", n == 50, "popped %d of 50" % n)

# --- 2. differential: new search vs the old one -----------------------------
func _scenario_differential_vs_reference() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var compared := 0
	var cost_mismatch := 0
	var reach_mismatch := 0
	var illegal := 0
	for trial in range(12):
		var w := 18
		var h := 18
		_random_grid(w, h, rng.randf_range(0.05, 0.35), rng)
		for q in range(25):
			var a := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
			var b := Vector2i(rng.randi_range(0, w - 1), rng.randi_range(0, h - 1))
			var mine: Array = GridManager.find_path(a, b)
			var theirs: Array = _reference_astar(a, b)
			compared += 1
			# Agreement on REACHABILITY is absolute.
			if mine.is_empty() != theirs.is_empty():
				reach_mismatch += 1
				continue
			if mine.is_empty():
				continue
			# Tie-breaking may pick a different equally-good route, so compare
			# cost rather than identity — but the cost must match exactly.
			if absf(_path_cost(mine) - _path_cost(theirs)) > 0.0001:
				cost_mismatch += 1
			# and the route must be a legal walk that ends where it was asked to
			if mine[mine.size() - 1] != b:
				illegal += 1
				continue
			var prev := a
			for t in mine:
				var d: Vector2i = t - prev
				if absi(d.x) + absi(d.y) != 1 or GridManager.step_cost(t) == INF:
					illegal += 1
					break
				prev = t
	_check("differential.compared-enough", compared == 300, "compared=%d" % compared)
	_check("differential.same-reachability", reach_mismatch == 0,
		"%d of %d queries disagreed on whether a path exists" % [reach_mismatch, compared])
	_check("differential.same-path-cost", cost_mismatch == 0,
		"%d of %d paths differed in cost" % [cost_mismatch, compared])
	_check("differential.paths-are-legal-walks", illegal == 0,
		"%d malformed paths" % illegal)

# --- 3. the unreachable-goal early-out --------------------------------------
func _scenario_early_out() -> void:
	# a big open grid with one walled tile in the middle
	_build_grid(60, 60, [Vector2i(30, 30)])
	_check("earlyout.goal-in-wall-empty",
		GridManager.find_path(Vector2i(1, 1), Vector2i(30, 30)).is_empty())
	_check("earlyout.goal-off-map-empty",
		GridManager.find_path(Vector2i(1, 1), Vector2i(500, 500)).is_empty())
	# The point of the early-out is that it does NOT drain the component first.
	# On a 3600-tile open grid the old code touched every tile for this query.
	var t0 := Time.get_ticks_usec()
	for i in range(50):
		GridManager.find_path(Vector2i(1, 1), Vector2i(30, 30))
	var per_query := float(Time.get_ticks_usec() - t0) / 50.0
	_check("earlyout.is-constant-time", per_query < 250.0,
		"%.1f us/query on a 3600-tile grid — expected O(1), looks like a drain" % per_query)
	# a reachable goal on the same grid must still work
	var ok := GridManager.find_path(Vector2i(1, 1), Vector2i(40, 40))
	_check("earlyout.reachable-goal-unaffected", not ok.is_empty() and ok[ok.size() - 1] == Vector2i(40, 40))
	# start standing inside a wall must still be able to path OUT (characters do
	# end up embedded after knockback/warps)
	_check("earlyout.start-in-wall-can-leave",
		not GridManager.find_path(Vector2i(30, 30), Vector2i(32, 30)).is_empty())
	# degenerate: start == end returns empty, exactly as it always did
	_check("earlyout.same-tile-empty",
		GridManager.find_path(Vector2i(5, 5), Vector2i(5, 5)).is_empty())

# --- 4. reachable_within ------------------------------------------------------
func _scenario_reachable_within() -> void:
	_build_grid(21, 21, [])
	var r := GridManager.reachable_within(Vector2i(10, 10), 3)
	_check("reach.excludes-origin", not r.has(Vector2i(10, 10)))
	# open ground: the reachable set within k steps is the Manhattan diamond
	var expected := 0
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			if absi(dx) + absi(dy) <= 3 and not (dx == 0 and dy == 0):
				expected += 1
	_check("reach.diamond-on-open-ground", r.size() == expected,
		"got %d, expected %d" % [r.size(), expected])
	_check("reach.records-step-distance",
		int(r.get(Vector2i(13, 10), -1)) == 3 and int(r.get(Vector2i(11, 11), -1)) == 2,
		"(13,10)=%s (11,11)=%s" % [r.get(Vector2i(13, 10)), r.get(Vector2i(11, 11))])
	_check("reach.respects-step-budget", not r.has(Vector2i(14, 10)))
	_check("reach.zero-budget-empty", GridManager.reachable_within(Vector2i(10, 10), 0).is_empty())

# --- 5. reachable_within agrees with find_path -------------------------------
# Same graph, same edges, so "in the k-step flood" and "find_path returns a
# route of <= k steps" must be the same statement for every tile.
func _scenario_reachable_matches_find_path() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var disagreements := 0
	var checked := 0
	for trial in range(4):
		var w := 14
		var h := 14
		_random_grid(w, h, 0.22, rng)
		var origin := Vector2i(7, 7)
		if GridManager.step_cost(origin) == INF:
			continue
		var budget := 5
		var flood := GridManager.reachable_within(origin, budget)
		for y in range(h):
			for x in range(w):
				var t := Vector2i(x, y)
				if t == origin:
					continue
				checked += 1
				var path: Array = GridManager.find_path(origin, t)
				var within_by_path: bool = not path.is_empty() and path.size() <= budget
				if within_by_path != flood.has(t):
					disagreements += 1
	_check("reach.matches-find-path", disagreements == 0,
		"%d of %d tiles disagreed" % [disagreements, checked])

# --- 6. the wander case that started all this --------------------------------
# A sealed room next to the asker: every tile inside is walkable in isolation
# but unreachable, which is precisely the shape that made the old wander sweep
# exhaust the component once per candidate.
func _scenario_sealed_pocket() -> void:
	var blocked: Array = []
	for x in range(10, 17):
		blocked.append(Vector2i(x, 10))
		blocked.append(Vector2i(x, 16))
	for y in range(10, 17):
		blocked.append(Vector2i(10, y))
		blocked.append(Vector2i(16, y))
	_build_grid(40, 40, blocked)
	var inside := Vector2i(13, 13)
	var outside := Vector2i(5, 5)
	_check("pocket.interior-is-walkable-in-isolation", GridManager.would_walk(inside))
	_check("pocket.but-unreachable", GridManager.find_path(outside, inside).is_empty())
	var flood := GridManager.reachable_within(outside, 40)
	_check("pocket.flood-excludes-interior", not flood.has(inside))
	_check("pocket.flood-includes-open-ground", flood.has(Vector2i(5, 12)))
	# the sealed interior is its own component and must not leak outward
	var inner := GridManager.reachable_within(inside, 40)
	_check("pocket.interior-flood-stays-inside", inner.size() == 24,
		"interior flood reached %d tiles, expected the 5x5 interior minus origin" % inner.size())
	_check("pocket.interior-cannot-reach-outside", not inner.has(outside))
