extends Node

# Dialogue Manager - Autoload Singleton
# Handles loading and displaying dialogues with play-style format, variable substitution, 
# markdown formatting, and conditional branching with function calls

var dialogues: Dictionary = {}
var current_dialogue_id: String = ""
var current_node_id: String = ""
var current_line_index: int = 0
var current_node_lines: Array = []
@onready var game = get_node_or_null("/root/Game")
# Reference to CharacterDatabase (assumed to be another autoload)


# Reserved keywords that aren't character names
const RESERVED_KEYS = ["choices", "next", "branch", "prerequisites"]

# Signals for UI to connect to
signal dialogue_updated(speaker_name: String, portrait: Texture, text: String, has_next: bool)
signal choices_available(choices: Array)
signal dialogue_ended()

func _ready():
	load_dialogues()

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

# Start a dialogue by its ID
func start_dialogue(dialogue_id: String):
	print("starting dialouges dialogues: ", dialogues[dialogue_id])
	if not dialogues.has(dialogue_id):
		push_error("Dialogue not found: " + dialogue_id)
		return
	
	current_dialogue_id = dialogue_id
	var dialogue_data = dialogues[dialogue_id]
	
	# Find the first node (usually same as dialogue_id)
	if dialogue_data.has("dialogueNodes"):
		var nodes = dialogue_data["dialogueNodes"]
		if nodes.has(dialogue_id):
			current_node_id = dialogue_id
			show_node(current_node_id)
		else:
			push_error("Starting node not found: " + dialogue_id)
	else:
		push_error("Dialogue has no dialogueNodes: " + dialogue_id)

# Display a specific dialogue node
func show_node(node_id: String):
	var dialogue_data = dialogues[current_dialogue_id]
	print("Attemtping to show node for dialogue_data: ", dialogue_data)
	var nodes = dialogue_data["dialogueNodes"]
	
	if not nodes.has(node_id):
		push_error("Node not found: " + node_id)
		return
	
	var node = nodes[node_id]
	current_node_id = node_id
	current_line_index = 0
	
	# Check prerequisites if they exist
	if node.has("prerequisites"):
		if not evaluate_prerequisites(node["prerequisites"]):
			push_warning("Prerequisites not met for node: " + node_id)
			dialogue_ended.emit()
			return
	
	# Parse all dialogue lines from the node (excluding reserved keywords)
	current_node_lines = []
	for key in node.keys():
		if key not in RESERVED_KEYS:
			current_node_lines.append({
				"speaker": key,
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
	var speaker_name = line["speaker"]
	var text = line["text"]
	
	# Get character portrait texture
	var portrait = get_character_portrait(speaker_name)
	
	# Process text with variable substitution and formatting
	var processed_text = process_text(text)
	print("processed_text")
	# Check if there are more lines to show
	var has_next = current_line_index < current_node_lines.size() - 1
	
	# Emit signal for UI to display
	dialogue_updated.emit(speaker_name, portrait, processed_text, has_next)

# Advance to the next line in the current node
func advance_line():
	current_line_index += 1
	
	var dialogue_data = dialogues[current_dialogue_id]
	var nodes = dialogue_data["dialogueNodes"]
	var node = nodes[current_node_id]
	
	show_current_line(node)

# Handle node navigation (choices, branch, or next)
func handle_node_navigation(node: Dictionary):
	# Check for branch (conditional navigation)
	if node.has("branch"):
		var next_node = evaluate_branch(node["branch"])
		if next_node != "":
			show_node(next_node)
		else:
			dialogue_ended.emit()
		return
	
	# Check for choices
	if node.has("choices"):
		var processed_choices = []
		for choice in node["choices"]:
			var choice_data = {
				"text": process_text(choice["text"]),
				"nextNode": choice.get("nextNode", ""),
				"branch": choice.get("branch", null)
			}
			processed_choices.append(choice_data)
		
		choices_available.emit(processed_choices)
		return
	
	# Check for simple next navigation
	if node.has("next"):
		show_node(node["next"])
		return
	
	# No navigation found, end dialogue
	dialogue_ended.emit()

# Evaluate a branch to determine which node to go to
func evaluate_branch(branch_data) -> String:
	# Branch can be a dictionary of conditions or a function call string
	
	if branch_data is Dictionary:
		# Evaluate each condition in order
		for condition in branch_data.keys():
			if evaluate_condition(condition):
				return branch_data[condition]
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
		return bool(result)
	
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
	
	# Get the object
	var obj = get_variable_value(object_path)
	if obj == null:
		push_error("Object not found: " + object_path)
		return null
	
	# Parse arguments
	var args = parse_function_args(args_string)
	
	# Call the method
	if obj.has_method(method_name):
		return obj.callv(method_name, args)
	else:
		push_error("Method not found: " + method_name + " on " + object_path)
		return null

# Parse function arguments from string
func parse_function_args(args_string: String) -> Array:
	if args_string.strip_edges() == "":
		return []
	
	var args = []
	var current_arg = ""
	var in_quotes = false
	var quote_char = ""
	
	for i in range(args_string.length()):
		var c = args_string[i]
		
		if c in ["'", '"'] and (i == 0 or args_string[i-1] != "\\"):
			if not in_quotes:
				in_quotes = true
				quote_char = c
			elif c == quote_char:
				in_quotes = false
				quote_char = ""
			else:
				current_arg += c
		elif c == "," and not in_quotes:
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

# Handle player's choice selection
func select_choice(choice_index: int, choices: Array):
	if choice_index < 0 or choice_index >= choices.size():
		push_error("Invalid choice index: " + str(choice_index))
		return
	
	var choice = choices[choice_index]
	
	# Check if choice has a branch
	if choice["branch"] != null:
		var next_node = evaluate_branch(choice["branch"])
		if next_node != "":
			show_node(next_node)
		else:
			dialogue_ended.emit()
	# Otherwise use nextNode
	elif choice["nextNode"] != "":
		show_node(choice["nextNode"])
	else:
		dialogue_ended.emit()

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
		var value = get_variable_value(variable_path)
		result = result.replace(match_obj.get_string(0), str(value))
	
	return result

# Get variable value from path (e.g., "protagonist.name")
func get_variable_value(path: String):
	var parts = path.split(".")
	
	# Try to get from root first
	var current = get_node_or_null("/root/" + parts[0])
	
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
			if parts[i] in current:
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

# Get character portrait from CharacterDatabase
func get_character_portrait(speaker_name: String) -> Texture:
	if CharacterDatabase == null:
		push_warning("CharacterDatabase not found")
		return null
	for character in game.characters_in_scene:
		if character.character_id == speaker_name:
			return load(character["icon"])
		else: 
			push_warning("Character not found for dialogue")
	#var key = speaker_name.to_lower()
	#var character = game.characters_in_scene(key)
	
	
	push_warning("Character portrait not found for: " + speaker_name)
	return null

# End current dialogue
func end_dialogue():
	current_dialogue_id = ""
	current_node_id = ""
	current_line_index = 0
	current_node_lines = []
	dialogue_ended.emit()
