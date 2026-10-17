extends Node

# Dialogue Manager - Autoload Singleton
# Handles loading and displaying dialogues with play-style format, variable substitution, 
# markdown formatting, and conditional branching with function calls

var dialogues: Dictionary = {}
var current_dialogue_id: String = ""
var current_node_id: String = ""
var current_line_index: int = 0
var current_node_lines: Array = []
# Most recently emitted choices, so select_choice() can resolve by index without
# the panel having to track them. Each entry carries trait metadata and
# precomputed ally reactions used to apply favorability deltas on selection.
var current_choices: Array = []
# Pending dialogue ids to start once the active one ends. Map/zone/time
# triggers funnel through start_dialogue() which appends here if a dialogue
# is already in progress.
var _pending_dialogues: Array = []
@onready var game = get_node_or_null("/root/Game")

# The action/check vocabulary nodes and choices carry ("actions", "on_enter",
# "requires", "show_if", array branches). See docs/dialogue_actions.md.
const DialogueActionsScript = preload("res://Global/DialogueActions.gd")
var actions_api = DialogueActionsScript.new(self)
# Who the player opened this conversation with (the Talk target), or null.
# Actions reach them as "partner".
var current_partner: Node = null


# Reserved keywords that aren't character names
const RESERVED_KEYS = ["choices", "next", "branch", "prerequisites", "actions", "on_enter"]

# Signals for UI to connect to
signal dialogue_updated(speaker_name: String, portrait: Texture, text: String, has_next: bool)
signal choices_available(choices: Array)
signal dialogue_ended()

func _ready():
	load_dialogues()
	# Other autoloads (QuestDatabase, conditions) finish loading after this
	# one, and /root/Game arrives later still.
	call_deferred("_validate_dialogue_actions")
	call_deferred("_connect_game_signals")

# Every action/check problem in Dialogues.json that can be seen without
# playing, said once at startup rather than when a player reaches it.
func _validate_dialogue_actions() -> void:
	for problem in actions_api.validate_all(dialogues):
		push_warning("Dialogues.json: " + str(problem))

func _connect_game_signals() -> void:
	var g = _get_game()
	if g != null and g.has_signal("map_loaded") and not g.map_loaded.is_connected(_on_map_loaded):
		g.map_loaded.connect(_on_map_loaded)

# set_dialogue choices outlive the map, and someone who joined the party
# isn't also standing where the map placed them.
func _on_map_loaded(_map_id: String) -> void:
	actions_api.on_map_loaded()

## The character this conversation was opened with, while they still exist.
func get_partner() -> Node:
	if current_partner != null and is_instance_valid(current_partner):
		return current_partner
	return null

# The Talk target named `npc_name`: the in-scene character with that Name
# nearest the party leader (two guards may share a name).
func _find_partner(npc_name: String) -> Node:
	var g = _get_game()
	if npc_name == "" or g == null or not ("characters_in_scene" in g):
		return null
	var anchor = g.get("player")
	var best: Node = null
	var best_d: float = INF
	for c in g.characters_in_scene:
		if not is_instance_valid(c) or str(c.get("Name")) != npc_name:
			continue
		var d: float = 0.0
		if anchor != null and is_instance_valid(anchor) and c is Node2D:
			d = c.global_position.distance_squared_to(anchor.global_position)
		if d < best_d:
			best_d = d
			best = c
	return best

# Load all dialogues from JSON file
func load_dialogues():
	var file_path = "res://data/Dialogues.json"
	
	if not FileAccess.file_exists(file_path):
		push_error("Dialogue file not found: " + file_path)
		return
	
	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_error("Failed to open dialogue file: " + file_path)
		return
	
	var json_string = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_string)
	
	if parse_result != OK:
		push_error("Failed to parse dialogue JSON: " + json.get_error_message())
		return
	
	dialogues = json.data
	#print("Dialogues loaded successfully: ", dialogues)

# Whether a dialogue is currently playing.
func is_active() -> bool:
	return current_dialogue_id != ""

# The Game scene. Looked up on use: this autoload is ready before /root/Game
# exists, so the @onready `game` above is always null.
func _get_game() -> Node:
	if game != null and is_instance_valid(game):
		return game
	return get_node_or_null("/root/Game")

# Start a dialogue by its ID. If another dialogue is already active, queue this
# one and start it when the current one ends. `npc_name` is the character the
# player asked to talk to, if any; when the dialogue can't start, the log says
# they have nothing to say instead of the click doing nothing. Talk arms pass
# the NPC's active_dialogue_id() as is: an empty id with a name is just "has
# nothing to say" (the one place that line is written), not a data error.
func start_dialogue(dialogue_id: String, npc_name: String = ""):
	if dialogue_id == "" and npc_name != "":
		_log_nothing_to_say(npc_name)
		return
	if not dialogues.has(dialogue_id):
		push_error("Dialogue not found: " + dialogue_id)
		_log_nothing_to_say(npc_name)
		return
	if is_active():
		_pending_dialogues.append(dialogue_id)
		return
	print("starting dialouges dialogues: ", dialogues[dialogue_id])
	var dialogue_data = dialogues[dialogue_id]
	
	# Resolve the first node before touching any state, so a malformed dialogue
	# can't leave the manager "active" with nothing on screen (which would queue
	# every later dialogue forever). The first node is usually named after the
	# dialogue; otherwise use the first authored node (JSON keeps file order):
	# guild_bounty_offer starts at "start", Federica_greet at "Federica_intro".
	var nodes = dialogue_data.get("dialogueNodes", {}) if dialogue_data is Dictionary else {}
	if not (nodes is Dictionary) or nodes.is_empty():
		push_error("Dialogue has no dialogueNodes: " + dialogue_id)
		_log_nothing_to_say(npc_name)
		return
	var start_node: String = dialogue_id if nodes.has(dialogue_id) else str(nodes.keys()[0])
	_connect_game_signals()
	current_dialogue_id = dialogue_id
	current_node_id = start_node
	current_partner = _find_partner(npc_name)
	show_node(start_node)

func _log_nothing_to_say(npc_name: String) -> void:
	if npc_name != "" and GameLog:
		# Over them too: the game log starts closed.
		var who = _find_partner(npc_name)
		if who != null and who.has_method("notify"):
			who.notify("Nothing to say", Color(0.85, 0.85, 0.85), "%s has nothing to say." % npc_name)
		else:
			GameLog.add_entry("%s has nothing to say." % npc_name)

# Display a specific dialogue node
func show_node(node_id: String):
	var dialogue_data = dialogues[current_dialogue_id]
	print("Attemtping to show node for dialogue_data: ", dialogue_data)
	var nodes = dialogue_data["dialogueNodes"]
	
	if not nodes.has(node_id):
		push_error("Node not found: " + node_id)
		# Close the conversation instead of leaving dead choice buttons on
		# screen and the manager stuck active.
		if GameLog:
			GameLog.add_entry("[i]The conversation trails off.[/i]")
		end_dialogue()
		return
	
	var node = nodes[node_id]
	current_node_id = node_id
	current_line_index = 0
	# Clear any choices left over from the previous node so a stale list can't
	# be selected against.
	current_choices = []
	
	# Check prerequisites if they exist
	if node.has("prerequisites"):
		if not evaluate_prerequisites(node["prerequisites"]):
			push_warning("Prerequisites not met for node: " + node_id)
			end_dialogue()
			return

	# "on_enter" actions fire as the node opens, before its first line.
	if node.has("on_enter"):
		actions_api.run_list(node["on_enter"], "on_enter")
		if not is_active() or current_node_id != node_id:
			return
	
	# Parse all dialogue lines from the node (excluding reserved keywords).
	# JSON can't repeat a key, so a speaker's second and later lines in one
	# node are keyed "Name#2", "Name#3"...; the suffix is dropped here.
	# Non-string values (a misspelled reserved key) aren't spoken lines.
	current_node_lines = []
	for key in node.keys():
		if key not in RESERVED_KEYS and node[key] is String:
			current_node_lines.append({
				"speaker": str(key).get_slice("#", 0).strip_edges(),
				"text": node[key]
			})
	
	# Show the first line or handle navigation if no lines
	print("how big is current nodes?: ", current_node_lines.size())
	if current_node_lines.size() > 0:
		
		show_current_line(node)
	else:
		# No dialogue lines, handle navigation immediately
		handle_node_navigation(node)

# Show the current line in the sequence
func show_current_line(node: Dictionary):
	if current_line_index >= current_node_lines.size():
		# All lines shown, handle navigation
		print("current_line_index exceeds current_node_lines size")
		handle_node_navigation(node)
		return
	
	var line = current_node_lines[current_line_index]
	var speaker_name = _resolve_speaker_name(line["speaker"])
	var text = line["text"]
	
	# Get character portrait texture
	var portrait = get_character_portrait(line["speaker"])
	
	# Process text with variable substitution and formatting
	var processed_text = process_text(text)
	print("processed_text")
	# Check if there are more lines to show
	var has_next = current_line_index < current_node_lines.size() - 1
	
	# Emit signal for UI to display
	dialogue_updated.emit(speaker_name, portrait, processed_text, has_next)

# Advance to the next line in the current node
func advance_line():
	if not is_active():
		return
	current_line_index += 1
	
	var dialogue_data = dialogues[current_dialogue_id]
	var nodes = dialogue_data["dialogueNodes"]
	var node = nodes[current_node_id]
	
	show_current_line(node)

# Run a node's or a choice's side-effecting `actions` list. Entries are action
# objects from Global/DialogueActions.gd, e.g.
#   "actions": [{"type": "give_item", "item": "torch", "to": "protagonist"}]
# (every type is in docs/dialogue_actions.md), or the older call-string syntax
# `branch` accepts, e.g. "QuestManager.start_quest('bandit_bounty')", resolved
# against /root/ autoloads by evaluate_function_call for effect.
#
# This is the hook the inline [[...]] markup scattered through Dialogues.json
# always looked like it was using; that markup goes through substitute_variables
# and is inert, so authors should use `actions` instead.
func run_actions(actions, where: String = "actions") -> void:
	actions_api.run_list(actions, where)

# Handle node navigation (choices, branch, or next)
func handle_node_navigation(node: Dictionary):
	# Side effects fire before navigation so a branch in this same node can test
	# the state the actions just wrote (e.g. accept a quest, then branch on it).
	run_actions(node.get("actions", null))

	# Check for branch (conditional navigation)
	if node.has("branch"):
		var next_node = evaluate_branch(node["branch"])
		if next_node != "":
			show_node(next_node)
		else:
			end_dialogue()
		return
	
	# Check for choices
	if node.has("choices"):
		var processed_choices = []
		var authored: Array = node["choices"] if node["choices"] is Array else []
		var any_open := false
		for ci in range(authored.size()):
			var choice = authored[ci]
			if not (choice is Dictionary):
				continue
			# "show_if": not offered at all when unmet. "requires": offered
			# greyed out, saying what is missing.
			if choice.has("show_if") and not actions_api.check_all(choice["show_if"]):
				continue
			var locked_reason := ""
			if choice.has("requires") and not actions_api.check_all(choice["requires"]):
				# (Only worked out when there is no locked_text: it re-runs the checks.)
				locked_reason = str(choice["locked_text"]) if choice.has("locked_text") \
					else actions_api.unmet_reason(choice["requires"])
				if locked_reason.is_empty():
					locked_reason = "Not available"
			else:
				any_open = true
			var preferred: Array = choice.get("preferred_traits", [])
			var disliked: Array = choice.get("disliked_traits", [])
			var choice_data = {
				"text": process_text(choice["text"]),
				"nextNode": choice.get("nextNode", ""),
				"branch": choice.get("branch", null),
				"preferred_traits": preferred,
				"disliked_traits": disliked,
				"favorability_weight": float(choice.get("favorability_weight", 1.0)),
				"ally_reactions": _compute_ally_reactions(preferred, disliked),
				# Carried through so select_choice can fire it; the UI ignores it.
				"actions": choice.get("actions", null),
				"disabled": not locked_reason.is_empty(),
				"locked_reason": locked_reason,
				"slot": "choice %d" % (ci + 1),
			}
			processed_choices.append(choice_data)

		if processed_choices.is_empty():
			# Every option hidden by show_if: carry on as if there were none,
			# rather than leaving an empty panel nothing can close.
			push_warning("Dialogue %s/%s: every choice is hidden by show_if" % [current_dialogue_id, current_node_id])
		else:
			if not any_open:
				# Nothing the player can pick: always leave a way out.
				processed_choices.append({"text": "Leave.", "nextNode": "", "branch": null,
					"preferred_traits": [], "disliked_traits": [], "favorability_weight": 1.0,
					"ally_reactions": [], "actions": null, "disabled": false, "locked_reason": "",
					"slot": "leave"})
			current_choices = processed_choices
			choices_available.emit(processed_choices)
			return
	
	# Check for simple next navigation
	if node.has("next"):
		show_node(node["next"])
		return
	
	# No navigation found, end dialogue
	end_dialogue()

# Evaluate a branch to determine which node to go to
func evaluate_branch(branch_data) -> String:
	# Branch can be a dictionary of conditions or a function call string
	
	if branch_data is Dictionary:
		# Evaluate each condition in order
		for condition in branch_data.keys():
			if evaluate_condition(condition):
				return branch_data[condition]
	elif branch_data is Array:
		# [{"if": <check or list of checks>, "next": "node"}, ..., {"next": "fallback"}]
		# The first entry whose checks all pass wins; no "if" always passes.
		for entry in branch_data:
			if not (entry is Dictionary) or not entry.has("next"):
				push_warning("Dialogue %s/%s: branch entry needs a next node: %s" % [current_dialogue_id, current_node_id, str(entry)])
				continue
			if not entry.has("if") or actions_api.check_all(entry["if"]):
				return str(entry["next"])
	elif branch_data is String:
		# It's a function call that returns a node name
		return evaluate_function_call(branch_data)
	
	return ""

# Evaluate a condition expression or function call
func evaluate_condition(condition: String) -> bool:
	if condition == "default":
		return true
	
	# Check if it's a function call (contains parentheses)
	if "(" in condition:
		var result = evaluate_function_call(condition)
		# Checks return a success level, where a critical failure is -1. A
		# call that couldn't be made returns null, which fails the condition.
		match typeof(result):
			TYPE_INT, TYPE_FLOAT:
				return result > 0
			TYPE_BOOL:
				return result
		return result != null
	
	# Otherwise, evaluate as expression
	return evaluate_expression(condition)

# Evaluate a function call like "protagonist.ability_check('persuasion', 15)"
func evaluate_function_call(call_string: String):
	# Parse the function call
	var regex = RegEx.new()
	regex.compile("([a-zA-Z_][a-zA-Z0-9_.]*)\\((.*)\\)")
	var match_obj = regex.search(call_string)
	
	if not match_obj:
		push_error("Invalid function call: " + call_string)
		return null
	
	var func_path = match_obj.get_string(1)
	var args_string = match_obj.get_string(2)
	
	# Parse the path to get object and method
	var parts = func_path.split(".")
	var method_name = parts[-1]
	var object_path = ".".join(parts.slice(0, -1))
	
	# Get the object. get_variable_value returns the literal "[path]" String on a
	# miss rather than null, so a bare null check lets a String through and the
	# has_method call below then fails on a non-Object. Check the type instead.
	var obj = get_variable_value(object_path)
	if obj == null or not (obj is Object):
		push_error("Object not found: " + object_path)
		return null

	# Parse arguments
	var args = parse_function_args(args_string)
	
	# Call the method
	if obj.has_method(method_name):
		var result = obj.callv(method_name, args)
		if method_name == "ability_check":
			_log_ability_check(obj, args, result)
		return result
	else:
		push_error("Method not found: " + method_name + " on " + object_path)
		return null

# Dialogue checks branch silently, so say in the log who rolled what and how
# it went. The roll and target are included when the character exposes them
# as `last_check` ({"roll", "target"}).
func _log_ability_check(character: Object, args: Array, result) -> void:
	if not GameLog:
		return
	var who: String = str(character.get("Name")) if character.get("Name") else ""
	if who == "" and "display_name" in character:
		who = str(character.display_name)
	var stat_name: String = str(args[0]).replace("_", " ").capitalize() if args.size() > 0 else "Ability"
	var passed: bool = result > 0 if typeof(result) in [TYPE_INT, TYPE_FLOAT] else (result is bool and result)
	var detail := ""
	var last = character.get("last_check")
	if last is Dictionary and last.has("roll") and last.has("target"):
		detail = " (rolled %d vs %d)" % [int(last["roll"]), int(last["target"])]
	var article: String = "an" if stat_name.substr(0, 1).to_lower() in ["a", "e", "i", "o", "u"] else "a"
	var line: String = "%s %s %s %s check%s." % [who, "passes" if passed else "fails", article, stat_name, detail]
	GameLog.add_entry(line)
	# The game log starts closed, so the roll also floats over whoever made it
	# (every roll: not notify, which drops a repeat within a second).
	if character is Node2D and (character as Node2D).is_inside_tree():
		Globals.show_floating_text("%s %s" % [stat_name, "passed" if passed else "failed"],
			character.global_position, character,
			Color(0.55, 1.0, 0.55) if passed else Color(1.0, 0.6, 0.4), 0, Globals.NOTICE_FONT_SIZE)

# Parse function arguments from string
func parse_function_args(args_string: String) -> Array:
	if args_string.strip_edges() == "":
		return []
	
	var args = []
	var current_arg = ""
	var in_quotes = false
	var quote_char = ""
	# Nesting depth of [...] list literals; their commas don't split arguments.
	var bracket_depth = 0
	
	for i in range(args_string.length()):
		var c = args_string[i]
		
		# Quote characters are kept so parse_arg_value can tell a quoted
		# literal ('charisma') from a variable path (protagonist.level).
		if c in ["'", '"'] and (i == 0 or args_string[i-1] != "\\"):
			if not in_quotes:
				in_quotes = true
				quote_char = c
			elif c == quote_char:
				in_quotes = false
				quote_char = ""
			current_arg += c
		elif c == "[" and not in_quotes:
			bracket_depth += 1
			current_arg += c
		elif c == "]" and not in_quotes:
			bracket_depth -= 1
			current_arg += c
		elif c == "," and not in_quotes and bracket_depth == 0:
			args.append(parse_arg_value(current_arg.strip_edges()))
			current_arg = ""
		else:
			current_arg += c
	
	if current_arg.strip_edges() != "":
		args.append(parse_arg_value(current_arg.strip_edges()))
	
	return args

# Parse a single argument value
func parse_arg_value(arg: String):
	# Remove quotes if present
	if (arg.begins_with("'") and arg.ends_with("'")) or (arg.begins_with('"') and arg.ends_with('"')):
		return arg.substr(1, arg.length() - 2)
	
	# List literal, e.g. ['secular', 'occult']
	if arg.begins_with("[") and arg.ends_with("]"):
		return parse_function_args(arg.substr(1, arg.length() - 2))
	
	# Try to parse as number
	if arg.is_valid_int():
		return int(arg)
	if arg.is_valid_float():
		return float(arg)
	
	# Check for boolean
	if arg == "true":
		return true
	if arg == "false":
		return false
	
	# Check if it's a variable reference
	if not arg.begins_with("'") and not arg.begins_with('"'):
		return get_variable_value(arg)
	
	return arg

# Handle player's choice selection. Reads from the choices most recently
# emitted via `choices_available` (stored in current_choices), so the UI only
# needs the index. Applies trait-based favorability deltas to present party
# members before navigating to the chosen branch/nextNode.
func select_choice(choice_index: int):
	if choice_index < 0 or choice_index >= current_choices.size():
		push_error("Invalid choice index: " + str(choice_index))
		return

	var choice = current_choices[choice_index]
	if bool(choice.get("disabled", false)):
		# The panel greys these out; a pick that gets here anyway is told why.
		if GameLog:
			GameLog.add_entry("Can't choose that: %s." % str(choice.get("locked_reason", "not available")))
		return
	_apply_choice_favorability(choice)
	# Consume the list so a late double-click can't re-apply the same delta.
	current_choices = []

	# Side effects fire after favorability and before navigation, so a choice's
	# own branch can test what its actions just wrote.
	run_actions(choice.get("actions", null), str(choice.get("slot", "choice")))

	# Check if choice has a branch
	if choice["branch"] != null:
		var next_node = evaluate_branch(choice["branch"])
		if next_node != "":
			show_node(next_node)
		else:
			end_dialogue()
	# Otherwise use nextNode
	elif choice["nextNode"] != "":
		show_node(choice["nextNode"])
	else:
		end_dialogue()

# Build the per-ally net-rating list for one choice. Iterates the party
# (excluding the protagonist) and runs each ally's `rate_choice`. Returns
# [] when the choice has no trait metadata so existing dialogues are
# completely unaffected.
func _compute_ally_reactions(preferred: Array, disliked: Array) -> Array:
	if preferred.is_empty() and disliked.is_empty():
		return []
	var out: Array = []
	var party: Array = []
	var g = _get_game()
	if g and g.has_method("get_party"):
		party = g.get_party()
	for ally in party:
		if not is_instance_valid(ally):
			continue
		if "is_protagonist" in ally and ally.is_protagonist:
			continue
		if not ally.has_method("rate_choice"):
			continue
		out.append({
			"character": ally,
			"display_name": ally.display_name if "display_name" in ally else str(ally),
			"net_rating": ally.rate_choice(preferred, disliked),
		})
	return out

func _apply_choice_favorability(choice: Dictionary) -> void:
	var weight: float = float(choice.get("favorability_weight", 1.0))
	for reaction in choice.get("ally_reactions", []):
		var delta: int = int(round(float(reaction.get("net_rating", 0)) * weight))
		if delta == 0:
			continue
		var ally = reaction.get("character", null)
		if ally and is_instance_valid(ally) and ally.has_method("apply_favorability_delta"):
			ally.apply_favorability_delta(delta, "dialogue:" + current_dialogue_id)

# Process text for variable substitution and markdown formatting
func process_text(text: String) -> String:
	# First, handle variable substitution [[variable.path]]
	var processed = substitute_variables(text)
	
	# Then, apply markdown formatting
	processed = apply_markdown(processed)
	
	return processed

# Substitute variables in double brackets [[variable]]
func substitute_variables(text: String) -> String:
	var regex = RegEx.new()
	regex.compile("\\[\\[([^\\]]+)\\]\\]")
	
	var result = text
	var matches = regex.search_all(text)
	
	for match_obj in matches:
		var variable_path = match_obj.get_string(1).strip_edges()
		# Inline actions ([[spawn_character_from_name(...)]] etc.) aren't run
		# from dialogue text (use the node's "actions" list); drop them rather
		# than show raw code to the player.
		if "(" in variable_path:
			push_warning("Dialogue action not supported, skipped: " + variable_path)
			result = result.replace(match_obj.get_string(0), "")
			continue
		var value = get_variable_value(variable_path)
		result = result.replace(match_obj.get_string(0), str(value))
	
	return result

# Resolve the first segment of a variable path to an object.
#
# Autoloads live at /root/<Name> and resolve directly. Two names that authored
# dialogue already uses do NOT: `game` is /root/Game, and `protagonist` is one of
# Game's children, not a root node at all. Without these aliases every shipped
# "protagonist.ability_check(...)" branch resolved to null and silently took the
# default path, so those skill checks have never actually been rolled.
func _resolve_root_object(root_name: String):
	var g = game if (game != null and is_instance_valid(game)) else get_node_or_null("/root/Game")
	match root_name:
		"game", "Game":
			return g
		"protagonist", "player", "Protagonist":
			if g != null and "player" in g:
				return g.player
			return null
	return get_node_or_null("/root/" + root_name)

# Get variable value from path (e.g., "protagonist.name")
func get_variable_value(path: String):
	var parts = path.split(".")

	var current = _resolve_root_object(parts[0])

	if current == null:
		push_warning("Variable not found: " + path)
		return "[" + path + "]"
	
	# Navigate through the path
	for i in range(1, parts.size()):
		if current is Dictionary:
			if current.has(parts[i]):
				current = current[parts[i]]
			else:
				push_warning("Variable path not found: " + path)
				return "[" + path + "]"
		elif current is Object:
			# A character's "name" is its display name, not its scene-node name.
			if parts[i] == "name" and "display_name" in current:
				current = current.get("display_name")
			elif parts[i] in current:
				current = current.get(parts[i])
			else:
				push_warning("Variable path not found: " + path)
				return "[" + path + "]"
		else:
			push_warning("Cannot navigate path: " + path)
			return "[" + path + "]"
	
	return current

# Apply markdown formatting (bold and italics)
func apply_markdown(text: String) -> String:
	var result = text
	
	# Bold: **text** or __text__ -> [b]text[/b]
	var bold_regex = RegEx.new()
	bold_regex.compile("\\*\\*([^\\*]+)\\*\\*|__([^_]+)__")
	var bold_matches = bold_regex.search_all(result)
	for match_obj in bold_matches:
		var content = match_obj.get_string(1) if match_obj.get_string(1) != "" else match_obj.get_string(2)
		result = result.replace(match_obj.get_string(0), "[b]" + content + "[/b]")
	
	# Italics: *text* or _text_ -> [i]text[/i]
	var italic_regex = RegEx.new()
	italic_regex.compile("(?<!\\*)\\*([^\\*]+)\\*(?!\\*)|(?<!_)_([^_]+)_(?!_)")
	var italic_matches = italic_regex.search_all(result)
	for match_obj in italic_matches:
		var content = match_obj.get_string(1) if match_obj.get_string(1) != "" else match_obj.get_string(2)
		result = result.replace(match_obj.get_string(0), "[i]" + content + "[/i]")
	
	return result

# Evaluate prerequisites
func evaluate_prerequisites(prerequisites) -> bool:
	# Prerequisites can be a string expression or array of expressions
	if prerequisites is String:
		return evaluate_expression(prerequisites)
	elif prerequisites is Array:
		for prereq in prerequisites:
			if not evaluate_expression(prereq):
				return false
		return true
	return true

# Evaluate a single expression
func evaluate_expression(expression: String) -> bool:
	# Remove whitespace
	expression = expression.strip_edges()
	
	# Try to use Godot's Expression class
	var expr = Expression.new()
	
	# Prepare variable context
	var input_names = []
	var input_values = []
	
	# Extract variable names (simplified - looks for common patterns)
	var var_pattern = RegEx.new()
	var_pattern.compile("([a-zA-Z_][a-zA-Z0-9_]*(?:\\.[a-zA-Z_][a-zA-Z0-9_]*)*)")
	var matches = var_pattern.search_all(expression)
	
	var modified_expression = expression
	var processed_vars = {}
	
	for match_obj in matches:
		var var_path = match_obj.get_string(1)
		
		# Skip if already processed
		if var_path in processed_vars:
			continue
		
		var value = get_variable_value(var_path)
		
		# Replace the variable path with a simple variable name
		var simple_name = var_path.replace(".", "_")
		modified_expression = modified_expression.replace(var_path, simple_name)
		
		input_names.append(simple_name)
		input_values.append(value)
		processed_vars[var_path] = true
	
	# Parse and execute the expression
	var parse_error = expr.parse(modified_expression, input_names)
	if parse_error != OK:
		push_error("Failed to parse expression: " + expression + " - " + expr.get_error_text())
		return false
	
	var result = expr.execute(input_values)
	
	if expr.has_execute_failed():
		push_error("Failed to execute expression: " + expression)
		return false
	
	return bool(result)

# Get character portrait from the speaking character's template icon
func get_character_portrait(speaker_name: String) -> Texture:
	if TopDownCharacterDatabase == null:
		push_warning("TopDownCharacterDatabase not found")
		return null
	var character = _find_speaker_character(speaker_name)
	if character == null or not ("template_id" in character):
		return null
	var template_id: String = str(character.template_id)
	if template_id == "" or not TopDownCharacterDatabase.get_all_template_ids().has(template_id):
		return null
	var icon_path: String = str(TopDownCharacterDatabase.get_template(template_id).get("icon", ""))
	if icon_path != "" and ResourceLoader.exists(icon_path):
		return load(icon_path)
	return null

# The in-scene character a speaker key refers to, or null. "protagonist" is
# the party leader; other keys match a display name ignoring case and hyphens
# ("Surgeon-Captain Federica" is "Surgeon Captain Federica"), or a template id.
func _find_speaker_character(speaker_name: String):
	var g = _get_game()
	if g == null:
		return null
	var key := speaker_name.to_lower().replace("-", " ").strip_edges()
	if key == "protagonist" or key == "player":
		var p = g.get("player")
		return p if p != null and is_instance_valid(p) else null
	if not ("characters_in_scene" in g):
		return null
	for c in g.characters_in_scene:
		if not is_instance_valid(c):
			continue
		if "display_name" in c and str(c.display_name).to_lower().replace("-", " ") == key:
			return c
		if "template_id" in c and str(c.template_id) == speaker_name.to_lower():
			return c
	return null

# The name shown above a line: narration has no speaker label, and a key
# that matches an in-scene character shows that character's name.
func _resolve_speaker_name(speaker_name: String) -> String:
	if speaker_name.to_lower() == "narrator":
		return ""
	var character = _find_speaker_character(speaker_name)
	if character != null and "display_name" in character:
		return str(character.display_name)
	return speaker_name

# End current dialogue
func end_dialogue():
	current_dialogue_id = ""
	current_node_id = ""
	current_line_index = 0
	current_node_lines = []
	current_choices = []
	current_partner = null
	dialogue_ended.emit()
	# A fight a conversation started opens paused, so the player can plan it.
	if actions_api.pause_requested:
		actions_api.pause_requested = false
		if PauseManager and not PauseManager.is_paused:
			PauseManager.pause()
	# Flush queued dialogues triggered while this one was active.
	if not _pending_dialogues.is_empty():
		var next_id: String = _pending_dialogues.pop_front()
		call_deferred("start_dialogue", next_id)
