# Round 5: DoT tuning, Toxic Shock, Invisible NPCs

This round implements your answers to round 4's decisions. Testing:
- Every existing harness is equal to or better than before.
- 3 new harnesses pass: dot_tune_r5_test 185, invisible_npc_r5_test 126 and integration_r5_test 38.
- unarmed_strike_check's flaky claw.bleeds is now deterministic.
- Everything ran headless. Nothing was played in a window.

## DoT

**Burning** now caps at 4 stacks (4 fire a second).

**Stacks per hit.** A hit now adds 1 stack per 5 damage of that type it deals, after armour and at least 1, for all four conditions. It is still set per condition (`damage_per_stack` in ConditionDatabase), so you can retune one later.

The old values were each picked for what feeds the condition:
- **Burning (6) and Poisoned (5):** one stack dealt about as much over time as the hit that caused it.
- **Chilled (12):** it deals no damage and freezes at 3 stacks, so only heavy cold froze in one hit.
- **Bleeding (20):** every slashing or piercing hit causes it, so an ordinary cut bled 1 stack.

There was no other reason. What 5 changes:

| Hit | Before | Now |
|---|---|---|
| Fire 1–5 / 6–10 / 11–15 / 16+ | 1 / 2 / 2–3 / 3 stacks | 1 / 2 / 3 / 4 stacks |
| Poison 16+ (Poison Vial) | 4 stacks | Toxic Shock at once |
| Cold 11+ (Iciclet, 15) | Chilled x2 | Frozen in one hit |
| Frost Axe, Winter's Grip | 3 hits to freeze | 3 hits to freeze (unchanged) |
| A 15 slashing cut | 1 Bleeding (4 extra damage) | 3 Bleeding (12 extra) |
| Greatsword (30) | 2 Bleeding (8 extra) | 5 Bleeding (20 extra) |

Bleeding is the big knock-on. After the CON save, a 15 cut goes from about 2 to about 10 extra damage. Every slashing or piercing hit now adds roughly 60–85% of its damage again as bleed.

**DoT ignores armour.** A condition's tick, including the first tick when it lands, skips worn armour and shields entirely, weaknesses included. The hover figure ("Burning x4: 4 fire every 1 s") is now exactly what lands. What still applies to ticks:
- Immunities and wards, which stop a DoT landing at all: Shielded blocks fire and cold debuffs, Frozen blocks Chilled, standing in water stops Burning.
- The "dr" stat from Shielded, Physically Resistant and Stalwart. It only covers physical damage, so the only DoT it reduces is Suffocating.
- Deny Ending holding HP at 1.

Hits are unchanged: armour still reduces them, and the stack count still uses the hit's damage after armour. Acid Rain stays at 61 over 60 s, armoured or not.

**The ×1.2.** Every character carried a built-in duration table that applied to everyone: fire ×1.2, ice ×1.5, aoe ×1.3, magical ×1.1. A condition with one of those traits lasted that much longer on any bearer, and the caster's table stretched spell impact effects. No data ever set it.
- The table is now empty. A character's data can still set its own entries, e.g. `"modify_duration_by_trait": {"fire": 1.5}` for a creature that burns longer.
- It's no longer saved, so old saves can't bring the old values back.
- Durations that change in play:
  - Burning 6 → 5 s, so one stack deals exactly 5.
  - Stuck in Fire 2.4 → 2 s: Fire Spin deals 16 instead of 18 over a full spin.
  - Hasted from Zip Smoke 33 → 30 s.
  - Animal Magnetism 33 → 30 s.
- Spell impact effects now show for 1.5 s instead of up to 2.6 s. This is visual only; fogs, surfaces and fields keep their own durations.

**Poisoned → Toxic Shock at 4 stacks.** `toxic_shock` was referenced but never defined, so the old transform at 10 was silently skipped. I defined it:
- **Effect:** 4 poison every 2 s (what 4 Poisoned stacks would deal) and 30% slower movement, for 10 s.
- **Restart:** reaching 4 stacks again restarts it.
- **Cure:** Heal cures it, as it cures Poisoned.
- **Feedback:** the float "Toxic Shock!" and the log "Ada's Poisoned reaches 4 stacks: Toxic Shock." Frozen's line now reads the same way: "Ada's Chilled reaches 3 stacks: Frozen."

| Condition | Per stack | Max | At max | 30 HP lasts |
|---|---|---|---|---|
| Burning | 5 | 4 | 4/s | 7 s |
| Poisoned | 5 | turns at 4 | 1.5/s, then Toxic Shock 2/s | 11 s |
| Bleeding | 4 | 5 | 2.5/s | 10 s |
| Corroding | 4 | 3 | 3/s | 9 s |
| Shocked | 2 | 3 | 3/s | 9 s |

## Invisible NPCs

An Invisible NPC is now not drawn at all unless the party is aware of it. When aware, it's see-through at the same 0.35 as your own invisible characters.

**What makes the party aware.** Each cue gives 5 s of game time, which doesn't run while paused, and every new cue restarts it:
- the party saw it turn invisible, or saw a cloak's Invisible return after its reveal;
- it hit a party member, a party member hit it (any blow or AoE that lands), or one put a condition on the other;
- a party member heard it within 2 tiles. Farther noise only gives the usual brief flash.

For as long as they apply:
- a party member with true sight has it in view;
- it's a party member's summon.

The NPC must also be where the party could otherwise see it: range, cone, walls and fog.

**Not aware: it's treated like an NPC out of sight.** Nothing gives it away:
- no hover, cursor change, click, talk or right-click menu;
- no threat arrow and no service discovery;
- aiming previews ignore it: a fireball's circle doesn't snap to it and knockback draws no arrow. The real spell still hits it.

**Feedback:**
- "Bandit turns invisible." when you see it happen.
- The hover shows why it's visible: "Invisible — you saw it vanish (4s)", "located by a hit", "heard close by", "seen by Djargo's true sight", "summoned by Djargo".
- When awareness runs out it fades over about 0.6 s, and a hostile logs "You lose track of Bandit (invisible)." once.
- An unseen attacker shows as "Djargo is hit by something invisible." Once you've seen it on this map, it's named instead: "Bandit (invisible)".
- Your own unseen hits show "Djargo hits something invisible." Before, they showed nothing.
- Deaths in view are announced: before, the corpse just appeared with no log line.

**Plans.** A planned attack or spell on an NPC that becomes hidden this way pauses just before that step. It shows "Paused: Target lost" and logs "Target lost: Bandit is invisible. Aldric's plan is paused." It resumes with "Aldric can see Bandit again: plan resumes." If the target dies meanwhile, the plan is dropped.

Tunable values:

| Setting | Value | Where |
|---|---|---|
| `INVISIBLE_AWARE_SECONDS` | 5 | `Game.gd` |
| `INVISIBLE_HEARD_TILES` | 2 | `Game.gd` |
| `INVISIBLE_ALPHA` | 0.35, shared by party and NPCs | `ProceduralCharacter.gd` |

## Try it in game

1. **Burning:** stand in burning ground or keep hitting with the Flaming Sword. The hover should read "Burning x4: 4 fire every 1 s", and it should go out 5 s after the last fire.
2. **Armour:** put Leather Armour on someone burning at x3. They should take 3 a second, not 1.
3. **Toxic Shock:**
   - Throw a Poison Vial at an enemy. Expect "Toxic Shock!" and slower movement.
   - Cast Heal on them. Both Toxic Shock and Poisoned should clear.
4. **Freezing:** an Iciclet freezes in one hit; the Frost Axe still takes 3.
5. **Load an old save** and set someone on fire. Burning should last 5 s, not 6.
6. **Invisible NPC in view:** make an enemy invisible while you watch.
   - You should see "turns invisible", a see-through body, and the hover countdown.
   - About 5 s later it fades out, with "You lose track of…".
7. **Invisible NPC unseen:** do the same while no one is looking, then face it. Nothing should be drawn, and the cursor should not change over it.
8. **Plan pause:**
   - Plan a walk of more than 5 s, then an attack on an enemy, and have it turn invisible as the walk starts.
   - When the attack step comes up, the plan should pause with "Target lost".
   - Waiting while paused doesn't count, because awareness runs on game time.

## Open decisions

1. **Toxic Shock** is my design: 4 poison / 2 s, 30% slower, 10 s, cured by Heal. Keep it? It reuses Poisoned's icon and effect; if you keep it, I can generate a dedicated icon.
2. **Bleeding at 5 per stack** is about 4–5 times heavier after the CON save. Keep it, or give Bleeding its own `damage_per_stack`?
3. **Chilled at 5 per stack:** any 11+ cold hit now freezes at once. Today that is only the Iciclet. Intended?
4. **Ordinary out-of-sight NPCs** (behind a wall, in the dark) can still be clicked, and the cursor changes over them, which gives their position away. Only invisible ones are filtered now. Filter all of them?
5. **Planned attacks** still follow a target that simply walks out of sight. Only Invisible pauses the plan. Should leaving sight pause it too?
6. **Combat music and the Surrender button** react to any nearby hostile without a sight check, so a hidden invisible enemy nearby starts the combat music. Keep that as a sense of danger?
7. **Tells from hidden invisible NPCs:** a bleeding one still drops blood puddles, and a burning one's fire sound plays from where it is. Its flames, light and icons stay hidden. Keep these as tells to read, or should burning or bleeding reveal it?

Two small existing leaks are left alone because tests assert their wording:
- "Burning is put out (cold: Bandit's hit)" names an attacker the party can't see.
- A few test-ability conditions (sickness spreading, vomiting, summon appearing) log NPC names without a sight check.

Still open from round 3 (docs/round_3.md):
- canceled_by_trait names that nothing carries yet;
- Federica;
- plan details;
- rations;
- the log ticker;
- Q9: indoor maps, and Acid Rain reporting an assault for every NPC it hits.
