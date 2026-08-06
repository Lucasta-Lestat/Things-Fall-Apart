## DaroDice
## DARO — "Doubles Add and Roll Over". A die whose result is a *repdigit*
## (both digits the same: 11, 22, 33 on a d33; 11, 22, 33, 44, 55, 66 on a d66)
## adds itself to a running total and is rolled again; the chain ends on the
## first non-repdigit, which is also added.
##
## Character-creation stats are 1d33 + 1d66 DARO — each die explodes on its own
## repdigits and the two totals are summed. Mean ≈ 55.6, and a stat can in
## principle run away well past 100.
##
## Pure static helpers, no autoload. Every entry point takes an optional
## RandomNumberGenerator so tests can seed a deterministic stream; pass null
## (the default) to use the global RNG.
class_name DaroDice
extends RefCounted

## Stat dice, in the order the sum is taken. Data-shaped so the roller reads
## the same as the design note it implements.
const STAT_DICE: Array[int] = [33, 66]

## The stat block is rerolled wholesale until its best stat clears this.
const DEFAULT_MIN_PEAK: int = 80

## A DARO chain is unbounded in theory. In practice a d66 chain of 64 doubles
## has probability (1/11)^64; the cap only exists so a corrupt `sides` value
## can't hang the game.
const MAX_EXPLOSIONS: int = 64

## Likewise for the reroll-the-whole-block rule. ~62% of blocks clear the peak
## on the first try, so exhausting 256 attempts means the data is wrong, not
## that the player was unlucky.
const MAX_BLOCK_ATTEMPTS: int = 256

# ---------------------------------------------------------------------------
# Primitives
# ---------------------------------------------------------------------------

## The repdigit ("doubles") faces of a die with `sides` faces: every dd ≤ sides.
## d33 -> [11, 22, 33]; d66 -> [11, 22, 33, 44, 55, 66].
static func repdigits_for(sides: int) -> Array[int]:
	var out: Array[int] = []
	for d in range(1, 10):
		var face: int = d * 11
		if face <= sides:
			out.append(face)
	return out

## One uniform face, 1..sides.
static func roll_flat(sides: int, rng: RandomNumberGenerator = null) -> int:
	if sides < 1:
		push_error("DaroDice.roll_flat: bad die size %d" % sides)
		return 0
	if rng != null:
		return rng.randi_range(1, sides)
	return randi_range(1, sides)

## `count`d`sides`, no explosion. Used for the body-metric rolls.
static func roll_pool(count: int, sides: int, rng: RandomNumberGenerator = null) -> int:
	var total: int = 0
	for _i in range(maxi(count, 0)):
		total += roll_flat(sides, rng)
	return total

## One DARO die: keep adding and rerolling while the face is a repdigit.
static func roll_daro(sides: int, rng: RandomNumberGenerator = null) -> int:
	var doubles: Array[int] = repdigits_for(sides)
	var total: int = 0
	for _i in range(MAX_EXPLOSIONS):
		var face: int = roll_flat(sides, rng)
		total += face
		if not doubles.has(face):
			return total
	push_warning("DaroDice: d%d exploded %d times; capping the chain." % [sides, MAX_EXPLOSIONS])
	return total

# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

## One stat: 1d33 + 1d66, each rolled DARO.
static func roll_stat(rng: RandomNumberGenerator = null) -> int:
	var total: int = 0
	for sides in STAT_DICE:
		total += roll_daro(sides, rng)
	return total

## A full stat block, rerolled from scratch until at least one stat reaches
## `min_peak`. Returns {stat_name: value} in the order `stat_names` was given.
##
## If the peak rule somehow can't be met the best block seen is returned rather
## than a half-rolled one — a character with slightly weak stats beats a
## character with none.
static func roll_stat_block(
		stat_names: Array,
		min_peak: int = DEFAULT_MIN_PEAK,
		rng: RandomNumberGenerator = null) -> Dictionary:
	var best: Dictionary = {}
	var best_peak: int = -1
	for _attempt in range(MAX_BLOCK_ATTEMPTS):
		var block: Dictionary = {}
		var peak: int = 0
		for stat_name in stat_names:
			var value: int = roll_stat(rng)
			block[String(stat_name)] = value
			peak = maxi(peak, value)
		if peak >= min_peak:
			return block
		if peak > best_peak:
			best_peak = peak
			best = block
	push_warning("DaroDice: no block reached a %d peak in %d attempts; keeping the best (%d)."
			% [min_peak, MAX_BLOCK_ATTEMPTS, best_peak])
	return best
