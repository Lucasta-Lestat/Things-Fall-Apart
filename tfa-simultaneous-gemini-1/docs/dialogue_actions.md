# Dialogue actions and checks

What a conversation in `data/Dialogues.json` can **do** (spawn guards, start a fight, hand over an item, change standing, move a quest on) and what it can **check** (does the party have the item, is the quest active, is this person in the party).

The code is `Global/DialogueActions.gd`. `Global/Dialogue_Manager.gd` runs it. The test that exercises every entry on this page is `tests/dialogue_r3_test.tscn`.

---

## 1. Where actions and checks go

```json
"some_node": {
  "on_enter": [ ...actions... ],
  "narrator": "The guard looks you over.",
  "actions":  [ ...actions... ],
  "choices": [
    {
      "text": "Pay the toll.",
      "requires": [ ...checks... ],
      "show_if":  [ ...checks... ],
      "locked_text": "You can't afford it",
      "actions":  [ ...actions... ],
      "nextNode": "paid"
    }
  ],
  "branch": [
    { "if": [ ...checks... ], "next": "node_a" },
    { "next": "fallback_node" }
  ]
}
```

| Key | Belongs to | When it runs |
|---|---|---|
| `on_enter` | node | When the node opens, before its first line is shown. |
| `actions` | node | After the node's last line, before its choices, `next` or `branch`. A `branch` in the same node can test what these actions just changed. |
| `actions` | choice | When the player picks the choice, before the conversation moves on. |
| `requires` | choice | If any check fails, the option is still shown but greyed out, with the reason in brackets: `Pay the toll.   [Needs 20 gold]`. The reason is written for you from the check. Use `locked_text` to write your own. |
| `show_if` | choice | If any check fails, the option is not offered at all. Use it for secret options. |
| `branch` (list) | node or choice | Goes to the first entry whose `if` checks all pass. An entry without `if` always passes, so put the fallback last. |

The older forms still work: `branch` as `{"condition string": "node"}`, `prerequisites`, and plain strings in `actions` such as `"QuestManager.start_quest('bandit_bounty')"`.

A few things happen on their own:

- If every option on a node is greyed out, a **"Leave."** option is added, so the player is never stuck.
- If `show_if` hides every option, the node carries on to its `next` (or the conversation ends), and a warning is printed.
- A greyed-out option can't be clicked. If one is picked anyway (from code), nothing happens except the log line `Can't choose that: <reason>.`

### `"once": true`

Any action can carry `"once": true`. After it has worked once it is skipped on later visits to the same node or choice. This is saved with the game. Use it for rewards and trophies on a node the player can replay.

---

## 2. When something is wrong

Nothing in an action or check can crash or end a conversation.

- **At startup**, every action and check in `Dialogues.json` is checked. Each problem is printed as a warning in the Godot output, beginning `Dialogues.json:` and naming the dialogue, node and slot: an unknown type, a missing field, an unknown item, template, quest, faction, condition, statute or dialogue, a branch that points to a node that doesn't exist, or a dice roll used in `requires`.
- **While playing**, an action that can't run (nobody here by that name, the player can't afford it, the statute isn't law here) is skipped. A warning is printed, beginning `Dialogue action [dialogue/node slot]:`. The rest of the list still runs.
- When the player's side is affected, the player is told too, for example `Mira can't pay 50 gold (has 12).` If an action can fail this way, put a matching check in `requires`.
- A check that can't be evaluated counts as **not met**.

---

## 3. Naming characters (`who`, `to`, `from`, `attackers`...)

Wherever an action or check names a character, you can use:

| Write | Means |
|---|---|
| `"protagonist"` (or `"player"`, `"leader"`) | The party leader. |
| `"partner"` | The character the player opened this conversation with (whoever they clicked Talk on). Empty for conversations started by a trigger. |
| `"party"` | Every party member. For `take_item` / `take_gold` / `has_item` / `has_gold` the party's packs count as one pool. |
| `"companions"` | The party without its leader. |
| `"tag:night_patrol"` | Everyone a `spawn` or `tag` action marked with that tag. |
| a template id, `"surgeon_captain_federica"` | Characters made from that template. |
| a name, `"Surgeon Captain Federica"` | Characters with that name. Capitals, hyphens and underscores don't matter. |
| one word of a name, `"Federica"` | Used only when nothing matches exactly. |
| a list, `["Jacana", "Djargo"]` | All of them. |

Only living characters in the current map count. When several match, the one nearest the party leader is first, which matters for actions that take one character.

## 4. Naming places (`at`, `to`)

| Write | Means |
|---|---|
| `[x, y]` | A map position in pixels. |
| `"from_town_square"` | A `player_spawns` entry of the current map: where the party arrives from that exit. |
| `"to_town_square"` | A `warp_points` id of the current map: that exit. |
| `"my_marker"` | An entry in an optional `"markers": {"my_marker": [x, y]}` block you can add to a map in `Maps.json`. |
| a character reference | Where that character stands. |

If the place is inside a wall, people are put on the nearest open ground, and nobody lands on a tile someone already stands on (the party included).

---

## 5. Actions

Every action is `{"type": "...", ...fields}`. **Bold** fields are required.

### World state (flags)

Flags live in the saved world state, the same store quests read. Setting one makes quests re-check their transitions right away.

| Type | Fields | Example |
|---|---|---|
| `set_flag` | **flag**, value (default `true`), who | `{"type": "set_flag", "flag": "spared_the_knight"}` |
| `add_to_flag` | **flag**, **amount** (may be negative), who | `{"type": "add_to_flag", "flag": "bribes_paid", "amount": 1}` |
| `clear_flag` | **flag**, who | `{"type": "clear_flag", "flag": "spared_the_knight"}` |

With `who`, the flag belongs to that character (stored as `flag::<template id>::<flag>`). Use this for "has Federica met us?". The player sees nothing when a flag changes.

### Quests

Quest moves write the usual quest lines in the log: `Quest started:`, `<Quest>: <Stage>`, `Quest complete:`, `Quest failed: <Quest> — <reason>`.

| Type | Fields | Notes |
|---|---|---|
| `start_quest` | **quest** | `{"type": "start_quest", "quest": "cheese_it"}` |
| `set_quest_stage` | **quest**, **stage** | Starts the quest first if needed. `{"type": "set_quest_stage", "quest": "cheese_it", "stage": "intervene"}` |
| `complete_quest` | **quest**, who (who gets the reward, default protagonist) | Offers the quest's rewards, as a turn-in does. |
| `fail_quest` | **quest**, reason | `{"type": "fail_quest", "quest": "cheese_it", "reason": "The cheesemonger was eaten."}` |
| `turn_in_quest` | **quest**, who | Hands over the proof and completes the quest. Gate it with a `can_turn_in` check. |

### Items and gold

| Type | Fields | What the player sees |
|---|---|---|
| `give_item` | **item**, count (1), to (protagonist), name, description | `Mira receives Torch (x2).` and `+Torch (x2)` over her. Given to someone outside the party: `Federica takes Torch.` (only if the party can see them). |
| `take_item` | **item**, count (1), from (party), to | All or nothing: if they don't have enough, nothing is taken and `Mira doesn't have 2 x Torch.` is logged. With `to`, the item goes to that character: `Mira gives Severed Head to Guild Clerk.` Without it: `Mira loses Severed Head.` |
| `give_gold` | **amount**, to (protagonist) | `Mira receives 25 gold.` |
| `take_gold` | **amount**, from (party), to | `Mira pays 10 gold to Gareth.`, or `Mira can't pay 50 gold (has 12).` and nothing is taken. |

`name` and `description` let one conversation hand out a one-off thing without a new `Items.json` entry. It is an existing item with a new name, for example the bones Federica bags become "Arms of Octavian". Checks still go by the item's id (`bones`). Only use this on items that don't stack, or the new name is lost when it stacks. Weapons count too, whether held or stowed: `has_item` sees them, `give_item` stows one, and `take_item` takes stowed ones first, then one from the hand (as the trade window does).

### Characters

| Type | Fields | Notes |
|---|---|---|
| `spawn` | **template**, count (1), at, near, distance, tag, name, faction, dialogue, titles | Makes new characters. `at` is a place; `near` is a character. With both, `near` is used if this map doesn't have the place. `distance` is the spacing in pixels (64 round someone, 40 at a place). `name` is one name for all of them, or a list naming them in order. When the party can see them: `Centurion and Town Guard (x3) arrive.` They stay until the map unloads; they aren't added to the map's saved population. |
| `despawn` | **who**, quiet | Removes characters (corpses included), `Town Guard leaves.`. Party members are refused: use `leave_party` first. |
| `walk_to` | **who**, **to**, stay (true) | They walk there on the map's paths. With `stay`, they don't wander off afterwards. Characters under the player's control are refused (use `teleport`). |
| `teleport` | **who**, **to** | Puts them there at once. |
| `set_faction` | **who**, **faction** | Moves them into an existing faction. `Gleg now sides with Waldau (hostile to you).` |
| `make_hostile` | **who**, toward (party), group | Turns them against the party, or against the factions or characters in `toward`, **without** turning their whole faction. See section 7. |
| `make_peaceful` | **who**, faction | Puts them back in the faction they had before the conversation changed it (or in `faction`), and calls off any hunt. `Federica stands down.` |
| `start_combat` | **attackers**, targets (party), group, pause (true) | `make_hostile`, plus everyone on both sides (except the party, whom you control) is alerted and goes looking for the other side. One log line: `Combat! Surgeon Captain Federica attacks you and the Golden Guard.` With `pause`, the game pauses when the conversation closes, so the player can plan. |
| `join_party` | **who** | They join the party for good, saved with the party. `Gleg joins the party.` Someone the maps place only once (Deputy Gleg, Zakariah) stops appearing where the map placed them while they are with you; a generic character (a town guard) doesn't hide the others. |
| `leave_party` | **who**, faction | They leave, going back to the faction they had before joining (or to `faction`). The leader can't leave. `Gleg leaves the party.` |
| `apply_condition` | **who**, **condition**, stacks (1), duration (seconds; -1 = permanent; default = the condition's own) | `Mira is now Blessed.`, or `Mira resists Frightened.` |
| `remove_condition` | **who**, **condition** | `Mira is no longer Poisoned.` |
| `heal` | **who**, amount (`"full"` by default) | `+N` over them; `Mira recovers 8 HP.` |
| `damage` | **who**, **amount**, damage_type (`"bludgeoning"`) | Goes through armour like any hit; logs what actually landed: `Mira takes 3 bludgeoning damage.` Nobody is blamed for it (no crime, no witnesses). |
| `add_trait` | **who**, **trait**, tiers (1) | `Mira gains the Subtle trait (now 1).` Use the trait's real capitalised name (`Subtle`, `Pious`). |
| `remove_trait` | **who**, **trait** | `Mira loses the Subtle trait.` |
| `change_favor` | **who**, **amount** | The usual `Jacana approves (+3 favour, now 13).` |
| `set_dialogue` | **who**, **dialogue**, persist (true) | What they say next time they are talked to. `""` = nothing to say. It is remembered for that template across maps and saves, so it affects every character made from that template (fine for named characters; for generic ones like `town_guard`, use `"persist": false`). |
| `tag` | **who**, **tag** | Marks existing characters so later actions can say `"tag:<tag>"`. |

### Factions and the law

| Type | Fields | Notes |
|---|---|---|
| `change_standing` | **faction**, **amount** | The player's standing with a faction. `Standing with Waldau: -20 (now -20).`, plus `They are now hostile to you.` when it crosses a line. |
| `set_relation` | **faction**, **other**, **relation** (`enemy`, `ally`, `neutral`) | How two factions regard each other from now on, both ways. Either side may be `"party"` or a character reference (their faction). Saved. `Golden Guard and Waldau are now enemies.` / `Waldau now counts you as an enemy.` |
| `change_faction_tier` | **faction**, **amount** | A faction's power tier (quests watch it). `Liziti grows stronger (tier 3).` |
| `report_crime` | **statute**, who (protagonist), witnesses, law | A crime named by statute. It goes through the law system: the statute must be law where the party stands, according to that place's law code, or nothing happens. The usual `<Name> commits Theft (severity 25) — a crime under the law of liziti.` line is logged. Then each witness (or, without `witnesses`, whoever can see it) starts the normal outcry: a delay, then a scream. Silencing them in time still works. An enforcer who hears it marks the party wanted. |
| `pardon` | **faction** | Clears the outlaw mark, lifts standing back to 0 if it was below, calls off manhunts. Records stay, marked settled. `Liziti pardons you. You are no longer wanted there.` |

### The conversation itself

| Type | Fields | Notes |
|---|---|---|
| `log` | **text** | Writes a line to the game log. `[[protagonist.name]]` and `**bold**` work as in dialogue lines. |
| `start_dialogue` | **dialogue** | Plays that conversation when this one ends. |
| `call` | **call** | The older call syntax, e.g. `"QuestManager.start_quest('x')"`. Prefer a typed action: a `call` runs whatever method it names, so it is only as safe as that method, and nothing checks it at startup. |

---

## 6. Checks

Every check is `{"type": "...", ...fields}` and can carry `"not": true` to flip it. A list of checks means all of them must pass. In `requires` / `show_if` / `if` you can also use the older condition strings.

| Type | Fields | Passes when | Greyed-out reason |
|---|---|---|---|
| `flag` | **flag**, who, equals / at_least / at_most | The flag has that value or range (`equals` matches `3` and `"3"` alike; `true` counts as 1 for a range). With none of those: the flag is set, and isn't false, 0 or empty. | Not available (write a `locked_text`) |
| `quest` | **quest**, **state** (`active`, `completed`, `failed`, `not_started`, `started`), stage | The quest is in that state (and, with `stage`, active at that stage). | Needs the quest X / Finish X first |
| `can_turn_in` | **quest**, who | They carry everything the current stage asks for. | Needs what X asks for |
| `has_item` | **item**, count (1), who (party) | Carrying at least that many. | Needs 2 x Torch |
| `has_gold` | **amount**, who (party) | Carrying at least that much gold. | Needs 20 gold |
| `standing` | **faction**, at_least / at_most | The player's standing is in range. | Needs standing 25 with Liziti |
| `stance` | **faction**, **is** (`hostile`, `neutral`, `friendly`) | How that faction regards the player. | Liziti must be friendly |
| `outlaw` | **faction** (or `"any"`) | The party is wanted there. | Only while wanted by X |
| `hostile` | **a**, **b** (factions, `"party"`, or characters) | The hostility rules say they fight. | Not available |
| `in_party` | **who** | Everyone named is in the party. | Gleg must be in the party |
| `present` | **who** | Someone by that reference is here and alive. | Gleg isn't here |
| `has_condition` | **who**, **condition** | Anyone named has it. | Needs Blessed |
| `has_trait` | **who**, **trait**, at_least (1) | Anyone named has it at that tier. | Needs Pious 2 |
| `favor` | **who**, at_least / at_most | That companion's favour is in range. | Jacana must like you more |
| `ability_check` | **stat**, who (protagonist), advantages, disadvantages, target | A real dice roll, logged with roll and target (`Mira passes a Charisma check (rolled 34 vs 60).`). **Branches only**: a roll in `requires` would re-roll every time the options are drawn. | — |
| `any` | **of** (list of checks) | Any of them passes. | Not available |
| `all` | **of** (list of checks) | All of them pass. | The first failing one's reason |

A check about someone who isn't on the map simply fails, without a warning.

---

## 7. How hostility works (and why)

Who fights whom is decided in one place, `FactionDatabase.are_hostile`, which reads faction relations. The AI, the attack cursor, the menus and the law all ask it. These actions only ever change the **data** it reads; they never add a second rule beside it.

- `make_hostile` / `start_combat` put the characters into a faction made during play, named after them ("Surgeon Captain Federica's band"). It is a copy of their own faction: their old friends stay friends, and it is at war with whoever they turned on. All of Waldau does **not** turn on you because Federica did. When the band is hostile to the party, attacking its members counts as self-defence, not assault. When it only turned on someone else (Federica on the guards), it is still under the local law's protection, so killing her there is murder unless she is also at war with that law's faction (add a `set_relation` with it). Use `group` to put several characters into one named band.
- `set_relation` changes how two whole factions regard each other.
- Factions made during play and relation changes are saved with the game.
- Crimes go through `CrimeManager` (`report_crime` uses the same verdict, log line and witness outcry as a crime the player commits by hand), and `pardon` through `CrimeManager.pardon`. Whether something is a crime is up to the law code of the place, never the dialogue.

---

## 8. Worked example: Surgeon Captain Federica

`Federica_greet` originally had code written into the text (`[[spawn_character_from_name('golden_guard',4)]]` and so on). That code never ran and was cut from the text when the dialogue was ported. It is now done with the actions above:

| Node | What happens |
|---|---|
| `Federica-intro-fight` | `start_combat` — Federica attacks the party. The game pauses when the talk closes. |
| `Federica-intro-agree-to-help` | `give_item` — the knight's arms go into Federica's bag as "Arms of Octavian" (`once`). |
| `Federica-intro-guard-fight` (you shouted for the guard) | `spawn` 4 town guards (`tag:night_patrol`) arriving from the town (`from_town_square`), then `start_combat` — Federica turns on the party **and** the patrol. |
| `Federica-intro-interrogation-continued` | `give_item` — the scholar's head goes into her bag as "Skull of a Scholar" (`once`); `spawn` 4 town guards round the grave, the first named "Centurion"; `start_combat` — Federica turns on the guards. The guards don't turn on the party: "What you do next, that is your affair." |
| `end-convo` (you slipped away) | `add_trait` Subtle +1 (`once`). |

For example, the patrol:

```json
"actions": [
  {"type": "spawn", "template": "town_guard", "count": 4,
   "at": "from_town_square", "near": "surgeon_captain_federica", "tag": "night_patrol"},
  {"type": "start_combat", "attackers": "surgeon_captain_federica",
   "targets": ["party", "tag:night_patrol"]}
]
```
