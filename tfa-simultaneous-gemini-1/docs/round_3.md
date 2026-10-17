# Round 3: your answers to the port questions

This round implements your answers to the 17 open questions in `docs/onedrive_port.md`, plus your UI notes. Six lanes built the work in parallel: conditions, casting and plans, travel and items, dialogue, UI, and icons. Each lane had its own reviewer. The lanes were then merged and reviewed together.

Testing:
- Every existing test harness is equal to or better than before, and 7 new harnesses pass (609 checks).
- Pre-existing failures are unchanged: template_data_check (33), quest_proof_test (the Item.gd:232 error), and the 3 known compile failures.
- Everything was checked headless only. Nothing was played in a window, apart from two layout screenshots.

## What changed, by question

**1. canceled_by_trait: on.** Anything carrying trait X now ends conditions that list X.
- The sources are:
  - an ability landing on you;
  - damage of that type actually dealt;
  - a condition arriving (Chilled puts out Burning, and Burning thaws Chilled and Frozen);
  - the fluid you stand in;
  - a consumable you take.
- While you stand in water, what water cancels can't land at all. Without this, a Fire Spin over a puddle would re-apply every half second and deal triple damage.
- Conditions from worn gear are suppressed for 10 s instead of removed, and the gear brings them back.
- Every cancellation floats over the bearer ("Burning put out") and logs the condition, trait and cause.
- Examples from your data:
  - Ice Storm puts out Burning.
  - Fireball, or any fire hit, thaws Chilled and Frozen. Even Match Striker's 1 fire point breaks a freeze.
  - Heal and a Potion of Healing stop Bleeding.
  - A puddle puts out Burning and washes off Corroding.
  - Courageous ends Frightened and Panicked.
  - Zip Smoke's Hasted ends Slowed.
  - Vortex clears smoke Suffocating, but only for a moment.
  - Fire on a Winter's Grip wielder suppresses the blade's frost and ends Freezing Fingers.
- **Dead entries.** No source carries these traits yet:
  - restoration, antidote, purify, clarity, bandage, heat, haste, weak, slow, decay/anti-heal, shatter, revealing, darkness, remove_curse, pardon.
  - For example, nothing is "antidote", so Poisoned can only be cured by an explicit cure.
  - These need sources, or deleting.

**2. World-map timers: hours.**
- Force-marching lasts 12 h, Exhausted 24 h, Hungover 12 h and Blessed 24 h. Meditation's Focused lasts 24 h, but it never shortens a permanent Focused virtue.
- Ability effects also accept `duration_hours`.
- Countdowns read like "Force-marching (11h 42m)". The downtime portraits show them too.
- On the world map, a party member's condition running out floats and logs "Ada is no longer Force-marching."
- Companions folded into the travel banner now expire their conditions during the journey, instead of all at once on arrival.

**3. DoT.** See "How DoT works" below. Three bugs are fixed:
- A killing tick let the rest of that frame run on the corpse.
- A tick that removed its own condition skipped the other conditions that frame.
- Bleeding's description was wrong.

The balance is unchanged; that is your decision.

**4. Winter's Grip.** Left as is. See the answer below.

**5. Concentration: spend and hold.**
- The cast pays its focus cost. It then holds up to the same amount again of what's left (the lavender pips). The held part comes back when the spell ends; the spent part doesn't.
- Recasting your own held spell costs focus again.
- Log line: "Ilse concentrates on Cloud Kill (2 focus spent, 2 held)." The ability tooltip says the same.
- New rule: a spell holding 0 focus breaks on the next hit. Otherwise casting with exactly the cost would make it unbreakable.

**6. Plans pause during stuns.**
- Stunned, Frozen and Apathetic pause the plan. The route dims, with a "Paused: Stunned" badge, and you can still edit or clear it.
- When the character recovers, the plan resumes from where they stood. Log lines: "Aldric is Stunned: plan paused." and "Aldric recovers: plan resumes."
- The plan is dropped, with the reason, only if it can't go on: the target died or left, or a leg of the route is newly blocked.
- Unconscious and fear/compulsion still drop the plan, as before.

**7. Djargo's Dark Hood.** Kept. See "Party visibility" below.

**8. Icons.**
- New `cond_shrouded.png` (a white hood with a shadowed face) and `cond_inspired.png` (a crown with rays). Both were made with your Gemini pipeline (gemini-3-pro-image, 14 calls, about $2) and finished to the set's exact disc colour, size and glyph scale.
- The generator is `tools/generate_condition_icons_gemini.py`. Run `--rework-only` to redo the finishing pass with no API call, or `--pick` to swap in a different candidate.
- Until the editor imports the two PNGs, the old borrowed icons show (`icon_fallback`).

**9. Indoor maps / Acid Rain assault reports.** You left this blank, so it's untouched.

**10. Downtime cooldowns.** Explained below. No change.

**11. Rations: food is the ration.**
- The 10 solid foods carry a new `Ration` trait. Alcohol and the Waterskin don't, so you can't burn a drink.
- Burn a Ration burns the cheapest food ("-1 Apple"). With none, it is refused with "No food to burn".
- Feasting gives a Bread Loaf.
- The cards and the confirm dialog show each character's food count, and food tooltips gain a "Ration:" line.

**12. Dialogue action API.** Dialogue can now act on characters, items, factions, the law, quests and flags. There are 39 action types and 17 check types. The full reference is in `docs/dialogue_actions.md`.
- Choices can be greyed out with a reason ("[Needs 20 gold]") or hidden.
- Mistakes in Dialogues.json are reported at startup and never end a conversation.
- Hostility goes through your oracle: a character who turns on someone moves into a runtime faction, which is saved.
- Federica's stripped actions are restored as data:
  - she fights you;
  - you can shout for the patrol;
  - the interrogation guards;
  - she bags the trophies;
  - you gain the Subtle trait for slipping away.

**13 and 14.** No change, as you answered.

**15. Shadow Cloak.**
- Attacking, throwing or casting breaks Invisible on exactly the actions that reveal Shrouded.
- The worn cloak restores it 3 s after the last swing.
- A timed Invisible (from a spell or potion) simply ends.
- Feedback: an "Invisibility broken" float and log line. The character is drawn solid and the icon dims while it is suppressed. "Invisible returns (Shadow Cloak)" when it comes back.
- Invisible's description now states the rule.

**16. Right-click Attack.**
- Right-clicking a living, non-hostile NPC now offers "Attack". Left-click still talks.
- If attacking them is a crime, the entry is labelled with it, e.g. "Attack (Assault)". The tooltip names the law, and warns when killing would be Murder.
- Crimes at or above your `confirm_above_severity` (50) use the cast-again confirmation. Your code had no other law confirmation.

**17. Starter weapons.** Fixed at the source.
- A starting weapon is now only its WeaponShape, so there is no hidden copy.
- Old saves drop those copies on load. Real weapons that the AI had picked up as dicts are stowed properly.
- The cap exemption and `drop_hand_ghost` are gone.

**UI notes**
- The banner reads "PAUSED · Space to resume".
- The Town Services panel stays hidden until you've seen a service in that town. Each new one floats "New service: Smith" and logs.
- The log is closed by default. Open it with the gold-framed "Log" button at the bottom right, or press L.
  - A badge counts unread entries.
  - The panel uses the same dark gold-bordered frame as Town Services and Camp, now shared from `UI/GoldFrame.gd`.
  - Tab hides it along with the rest of the HUD.
- The wind readout now sits right of the moon (downtime) button and date, in the same font.

**Because the log is now hidden**, the integration review went through everything that only reached the log and gave it a float as well:
- refusals ("Too far", "Blocked", "Select someone first");
- crimes ("Crime: Theft");
- quest news;
- dialogue check results ("Charisma passed");
- downtime results;
- faction changes;
- disarms.

Lines left log-only are listed under Open decisions.

## Answers

### How DoT works
- Each damage-over-time condition ticks `value × stacks` every interval. The first tick lands at once.
- A tick is real damage: torso armour of that type applies, but you get no "blocked" text.
- Every damaging fire, poison or cold hit adds one stack, whatever its size. Slashing and piercing add Bleeding.
- Stacks cap at the condition's max tier and do NOT refresh the duration. Burning ends 18 s after its first stack, however many hits follow.
- Fire conditions last ×1.2, because of the default `MODIFY_DURATION_BY_TRAIT` table.

Totals:
- Burning: 72 per stack (288 at tier 4).
- Poisoned: 50 per stack.
- Bleeding: about 16 per stack, less after saves.
- Shocked: 6 per stack.

A typical character has about 30 HP. Hits do 10–30 damage, Fireball 24. So a rider deals 2–8× the hit that caused it:
- Match Striker: a 9 + 1 hit, plus 72 Burning.
- Fireball: 24, plus 144 Burning.

The engine does what its code says. The scale is what's off: per-stack damage ignores the size of the hit, durations are long, and HP is low.

Options:
1. **Potency from the hit.** A rider ticks at most the elemental damage that was actually dealt, and spells keep their full values. Match Striker 72 → 12, Flaming Sword 72 → 60, Stiletto 50 → 20. Fireball, Ice Storm and surfaces are unchanged.
2. **Refresh and delay.** New stacks refresh the duration, and the first tick waits one interval. Sustained fire keeps a fire going, but this doesn't fix the 1-point rider.
3. **Shorter durations**, data only. Burning at 5 s of data (6 s after the ×1.2) gives 24 per stack. Big and small riders stay equal.

**Recommended:** option 1, plus the refresh half of option 2. Also decide whether the ×1.2 fire duration is intended.

### Winter's Grip and enemy sight
Yes, enemies' sight of the wielder is cut too. Sight between two characters uses the worse fog of the two spots, the viewer's and the target's. Fog in between doesn't count.

The details:
- A puff is about ×0.66 at its core. A sight of 22.5 tiles drops to about 15.
- Puffs last 3 s, spawn every 2 s, and don't drift. So a walking wielder is fogged only about 0.4 s in every 2 s. A standing one stays fogged.
- Close quarters (2 tiles) ignores range.
- An enemy already targeting the wielder keeps them out to 1.5× its own range.

### Party visibility under Shrouded and Invisible
What you see for your own party:
- **Invisible:** the whole character is drawn at 35% opacity, icons included. It is still clickable. New this round: it is drawn solid while an attack has the cloak suppressed.
- **Shrouded:** no sprite change, only the condition icon, which now has its own art instead of Invisible's. The 3 s reveal after attacking has no notice of any kind.
- **Sneaking:** the STEALTH badge, noise rings, and an eye over anyone an onlooker can see.

What enemies perceive:
- **Invisible:** the AI never picks an Invisible target.
- **Shrouded:** enemies acquire you only within half their sight (about 11 tiles), and attacking or casting resets that to full sight for 3 s.

Oddities found (decisions below):
- An enemy that acquired you while the cloak was suppressed keeps you after Invisible returns. Only new enemies are fooled.
- An invisible party member sneaking past a resting NPC still wakes it to "?". The stealth eye doesn't warn about this.
- Crime witnesses ignore both conditions for non-attack crimes such as theft or lockpicking.
- Invisible NPCs are drawn fully opaque to you. Only their icon shows it.

### Downtime cooldowns
- What goes on cooldown is a (character, activity, outcome) triple. Once picked, that outcome can't come up again for 7 days.
- The roll only chooses among outcomes that are off cooldown.
- If the only eligible outcomes are cooling, the activity still runs and its default effects still apply, e.g. Carousing's stress relief or Burn a Ration's food. The result says "nothing of note came of it. They have done this too often lately (outcomes refresh after 7 days)."
- Nothing warns you before you confirm.
- Training has no cooldown, so its 4 outcomes can repeat on consecutive days of a booked course. That is still limited to one session a day.

Worked example, Drinking (3 outcomes):
- Day 1: Hangover.
- Day 2: Belligerent.
- Day 3: on a failed check, nothing of note. On a passed check, good gossip.
- Day 8: Hangover can come up again.

Quirk: the day count is `year*372 + month*36 + day`, not the game's own day counter. Two consequences:
- Anything used in the last 6 days of a year frees up on New Year's Day.
- In a leap year, the Yearturn days block every recent entry.

Fixing it needs a save migration as well as the one-line change.

## Open decisions

Most important first:

1. **DoT scale:** option 1, 2, 3, or the recommended 1 + refresh? Is the ×1.2 fire duration intended? Should a 1-point fire rider thaw a freeze?
2. **Invisible and the AI:**
   - Should enemies lose a target when its Invisible returns?
   - Should sneaking while Invisible stop waking resting NPCs? That looks like a bug to me.
   - Should crime witnesses respect Invisible and Shrouded?
3. **Shrouded feedback:** add a small "Revealed" notice and a visual for Shrouded party members? This is a real feedback gap, and an easy fix.
4. **Dead canceled_by_trait entries** (listed above): give them sources (an antidote item, a bandage, `revealing` on Illuminated…) or delete them? Should outdoor rain itself put out Burning? Today only its puddles do. Is 10 s the right suppression window for gear conditions?
5. **Attack confirmation:** only crimes of severity 50 or more ask first. No shipped town is under martial law, so in practice the menu Attack never asks. Should a deliberate menu attack ask before any crime?
6. **Federica:**
   - In the interrogation branch, her band fights the guards but stays protected by Liziti law, so killing her there is Murder. A `set_relation` with liziti would fix that, if you want it.
   - The guards' melee hits companions standing beside her; there is no friendly-fire filter.
   - Add a "desecration" statute?
   - Should start_combat keep pausing the game when the conversation closes?
   - Do you want a template for Verhoeven?
7. **Plans:**
   - When an attack target dies, drop the whole plan or just that step?
   - Should fear pause the plan instead of dropping it?
   - Should Apathetic keep movement running?
   - Should a re-stun within about 1.5 s stay quiet?
8. **Concentration:** keep "0 held breaks on the next hit"?
9. **Travel and downtime:**
   - Should travel-scale stacks (Exhausted, Fatigued) restart their clock on each new tier?
   - Should Burn a Ration be refused, or warn, when all its outcomes are cooling? It currently still eats the food.
   - Fix the day-count quirk?
   - Add food upkeep anywhere?
10. **Log-only lines left:** weather changes, "A new day", Concentration start/end, condition tier changes, "Added to your notes", faction tier changes, and companions leaving to train. Add a one-line "latest entry" ticker beside the Log button while the log is closed?
11. **Small ones:**
    - Should the wind readout hide with Tab?
    - Inspired: the white crown with rays, a gold crown, or a crown with a star? See the candidates sheet.
12. **Question 9** (indoor maps, and Acid Rain reporting an assault per NPC hit) is still unanswered.

## In the editor

1. The editor was open during the merge. If Godot asks about files changed on disk, choose **Reload**.
2. The editor has already imported the two new icons and written `.uid` files for the new scripts and tests (13 small files). They are committed.
3. Things to try:
   - Pause: the banner has no "planning".
   - Press L: the log opens in the gold frame. The badge counts while it's closed.
   - Enter a town: no services panel until you spot a merchant ("New service: …").
   - Right-click a townsperson → Attack.
   - Shadow Cloak: attack, then watch for "Invisibility broken" and "Invisible returns".
   - Dark Hood and Golden Crown Helm show the new icons.
   - Ice Storm a burning character; walk a burning character into a puddle.
   - Cast Cloud Kill twice: focus is spent each time.
   - Stun someone mid-route: the plan is paused, then resumes.
   - World map: Force March counts down "12h 00m" over about 6 real seconds.
   - Burn a Ration with and without food.
   - Talk to Federica in the Old Cemetery after 20:00 and try each branch.
   - Load an old save: starting weapons are still held, with no extra copies.
