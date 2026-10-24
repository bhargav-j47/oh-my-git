extends Control

signal command_done

# Font size (zoom) settings. The default is large enough to be readable from
# the back of a big room when presenting.
const FONT_SIZE_DEFAULT = 40
const FONT_SIZE_MIN = 16
const FONT_SIZE_MAX = 140
const FONT_SIZE_STEP = 4

# Floating window settings.
const MODE_NONE = 0
const MODE_MOVE = 1
const MODE_RESIZE = 2
const EDGE_LEFT = 1
const EDGE_RIGHT = 2
const EDGE_TOP = 4
const EDGE_BOTTOM = 8
const RESIZE_BORDER = 12
const KEEP_VISIBLE_X = 120
const KEEP_VISIBLE_Y = 60

var font_size = FONT_SIZE_DEFAULT
var term_font

# The terminal is a free floating window if it is not managed by a container.
var floating = true
var _drag_mode = MODE_NONE
var _resize_edges = 0
var _drag_start_mouse = Vector2.ZERO
var _drag_start_rect = Rect2()
var _default_rect = Rect2()

# Plain text copy of everything shown in the output (used by "Copy all").
var transcript = ""

var history_position = 0
var git_commands = ["add", "am", "archive", "bisect", "branch", "bundle", "checkout", "cherry-pick", "citool", "clean", "clone", "commit", "describe", "diff", "fetch", "format-patch", "gc", "gitk", "grep", "gui", "init", "log", "merge", "mv", "notes", "pull", "push", "range-diff", "rebase", "reset", "restore", "revert", "rm", "shortlog", "show", "sparse-checkout", "stash", "status", "submodule", "switch", "tag", "worktree", "config", "fast-export", "fast-import", "filter-branch", "mergetool", "pack-refs", "prune", "reflog", "remote", "repack", "replace", "annotate", "blame", "bugreport", "count-objects", "difftool", "fsck", "gitweb", "help", "instaweb", "merge-tree", "rerere", "show-branch", "verify-commit", "verify-tag", "whatchanged", "archimport", "cvsexportcommit", "cvsimport", "cvsserver", "imap-send", "p", "quiltimport", "request-pull", "send-email", "svn", "apply", "checkout-index", "commit-graph", "commit-tree", "hash-object", "index-pack", "merge-file", "merge-index", "mktag", "mktree", "multi-pack-index", "pack-objects", "prune-packed", "read-tree", "symbolic-ref", "unpack-objects", "update-index", "update-ref", "write-tree", "cat-file", "cherry", "diff-files", "diff-index", "diff-tree", "for-each-ref", "get-tar-commit-id", "ls-files", "ls-remote", "ls-tree", "merge-base", "name-rev", "pack-redundant", "rev-list", "rev-parse", "show-index", "show-ref", "unpack-file", "var", "verify-pack", "daemon", "fetch-pack", "http-backend", "send-pack", "update-server-info", "check-attr", "check-ignore", "check-mailmap", "check-ref-format", "column", "credential", "credential-cache", "credential-store", "fmt-merge-msg", "interpret-trailers", "mailinfo", "mailsplit", "merge-one-file", "patch-id", "sh-i", "sh-setup"]

var git_commands_help = []

onready var input = $Rows/InputLine/Input
onready var output = $Rows/TopHalf/Output
onready var completions = $Rows/TopHalf/Completions
onready var editor = $Rows/TopHalf/TextEditor
onready var prompt = $Rows/InputLine/Prompt
onready var pager_text = $Pager/Text
onready var size_label = $Rows/TitleBar/Items/SizeLabel
var repository
onready var main = get_tree().get_root().get_node("Main")

var shell = Shell.new()

var COLORS = [
	Color.webgray, # black
	Color.crimson, # red
	Color.chartreuse, # green
	Color.gold, # yellow
	Color.royalblue, # blue
	Color.magenta, # magenta
	Color.cyan, # cyan
	Color.white # white
]

var premade_commands = [
	'git commit --allow-empty -m "empty"',
	'echo $RANDOM | git hash-object -w --stdin',
	'git switch -c $RANDOM',
]

func _ready():
	var error = editor.connect("hide", self, "editor_closed")
	if error != OK:
		helpers.crash("Could not connect TextEditor's hide signal")
	input.grab_focus()

	for subcommand in git_commands:
		git_commands_help.push_back("")
	
	completions.hide()
	history_position = game.state["history"].size()
	
	# Set up the zoomable font.
	term_font = preload("res://fonts/monospace.tres").duplicate()
	font_size = int(game.state.get("terminal_font_size", FONT_SIZE_DEFAULT))
	set_font_size(font_size, false)
	
	# Detached window behavior only makes sense if no container controls our rect.
	floating = not (get_parent() is Container)
	_default_rect = Rect2(rect_global_position, rect_size)
	if floating:
		call_deferred("_keep_on_screen")

# --- Font size (zoom) ---

func increase_font_size():
	set_font_size(font_size + FONT_SIZE_STEP)

func decrease_font_size():
	set_font_size(font_size - FONT_SIZE_STEP)

func set_font_size(new_size, save = true):
	font_size = int(clamp(new_size, FONT_SIZE_MIN, FONT_SIZE_MAX))
	term_font.size = font_size
	
	# Re-assigning the overrides makes every control re-measure its text.
	output.add_font_override("normal_font", term_font)
	output.add_font_override("mono_font", term_font)
	input.add_font_override("font", term_font)
	prompt.add_font_override("font", term_font)
	completions.add_font_override("font", term_font)
	pager_text.add_font_override("normal_font", term_font)
	editor.add_font_override("font", term_font)
	size_label.text = str(font_size) + " pt"
	
	# Make the RichTextLabels re-layout the text they already contain.
	output.notification(NOTIFICATION_RESIZED)
	pager_text.notification(NOTIFICATION_RESIZED)
	
	if save:
		game.state["terminal_font_size"] = font_size
		game.save_state()

# Returns true if the event was a zoom shortcut (Ctrl/Cmd and +, - or 0, or
# Ctrl/Cmd and the mouse wheel over the terminal).
func _handle_zoom_event(event):
	if event is InputEventKey and event.pressed and (event.control or event.meta):
		var key = event.scancode
		if key == KEY_PLUS or key == KEY_EQUAL or key == KEY_KP_ADD:
			increase_font_size()
			return true
		elif key == KEY_MINUS or key == KEY_KP_SUBTRACT or key == KEY_UNDERSCORE:
			decrease_font_size()
			return true
		elif key == KEY_0 or key == KEY_KP_0:
			set_font_size(FONT_SIZE_DEFAULT)
			return true
	elif event is InputEventMouseButton and event.pressed and (event.control or event.meta):
		if get_global_rect().has_point(get_global_mouse_position()):
			if event.button_index == BUTTON_WHEEL_UP:
				increase_font_size()
				return true
			elif event.button_index == BUTTON_WHEEL_DOWN:
				decrease_font_size()
				return true
	return false

# --- Copy & paste ---

func _selected_text():
	var sources = [output, pager_text]
	if $Pager.visible:
		sources = [pager_text, output]
	for source in sources:
		if source.has_method("get_selected_text"):
			var text = source.get_selected_text()
			if text != "":
				return text
	return ""

# Copies the selected output text. Returns true if something was copied.
func _handle_copy_event(event):
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return false
	if not event.is_action("ui_copy"):
		return false
	# While the player has typed something, let the input line copy its own text.
	if input.has_focus() and input.text != "":
		return false
	var text = _selected_text()
	if text == "":
		return false
	OS.clipboard = text
	return true

func copy_all():
	OS.clipboard = transcript
	var button = $Rows/TitleBar/Items/CopyAll
	button.text = "Copied!"
	yield(get_tree().create_timer(1.5), "timeout")
	button.text = "Copy all"

# Typing while the output has focus (after selecting text) goes to the input.
func _refocus_input_on_typing(event):
	if event is InputEventKey and event.pressed and output.has_focus():
		if input.editable and not event.control and not event.meta and not event.alt and event.unicode != 0:
			input.grab_focus()

# --- Detached, movable and resizable window ---

func _edges_at(pos):
	var edges = 0
	if pos.x <= RESIZE_BORDER:
		edges |= EDGE_LEFT
	elif pos.x >= rect_size.x - RESIZE_BORDER:
		edges |= EDGE_RIGHT
	if pos.y <= RESIZE_BORDER:
		edges |= EDGE_TOP
	elif pos.y >= rect_size.y - RESIZE_BORDER:
		edges |= EDGE_BOTTOM
	return edges

func _cursor_for_edges(edges):
	var horizontal = (edges & (EDGE_LEFT | EDGE_RIGHT)) != 0
	var vertical = (edges & (EDGE_TOP | EDGE_BOTTOM)) != 0
	if horizontal and vertical:
		var same_diagonal = ((edges & EDGE_LEFT) != 0) == ((edges & EDGE_TOP) != 0)
		return CURSOR_FDIAGSIZE if same_diagonal else CURSOR_BDIAGSIZE
	elif horizontal:
		return CURSOR_HSIZE
	elif vertical:
		return CURSOR_VSIZE
	return CURSOR_ARROW

# Mouse events on the window border (everything not covered by child controls).
func _gui_input(event):
	if not floating:
		return
	if event is InputEventMouseMotion and _drag_mode == MODE_NONE:
		mouse_default_cursor_shape = _cursor_for_edges(_edges_at(event.position))
	elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			var edges = _edges_at(event.position)
			if edges != 0:
				_begin_drag(MODE_RESIZE, edges)
		else:
			_end_drag()

# Mouse events on the title bar: dragging moves the window.
func _title_bar_gui_input(event):
	if not floating:
		return
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			if event.doubleclick:
				reset_window()
			else:
				_begin_drag(MODE_MOVE, 0)
		else:
			_end_drag()

func _begin_drag(mode, edges):
	raise()
	_drag_mode = mode
	_resize_edges = edges
	_drag_start_mouse = get_global_mouse_position()
	_drag_start_rect = Rect2(rect_global_position, rect_size)
	set_process(true)

func _end_drag():
	_drag_mode = MODE_NONE
	_resize_edges = 0
	set_process(false)
	input.grab_focus()

func _process(_delta):
	if _drag_mode == MODE_NONE:
		set_process(false)
		return
	if not Input.is_mouse_button_pressed(BUTTON_LEFT):
		_end_drag()
		return
	_update_drag(get_global_mouse_position())

func _update_drag(mouse):
	var delta = mouse - _drag_start_mouse
	if _drag_mode == MODE_MOVE:
		rect_global_position = _clamp_position(_drag_start_rect.position + delta)
	elif _drag_mode == MODE_RESIZE:
		var viewport_size = get_viewport_rect().size
		var minimum = get_combined_minimum_size()
		var left = _drag_start_rect.position.x
		var top = _drag_start_rect.position.y
		var right = _drag_start_rect.end.x
		var bottom = _drag_start_rect.end.y
		if _resize_edges & EDGE_LEFT:
			left = clamp(left + delta.x, 0, right - minimum.x)
		if _resize_edges & EDGE_RIGHT:
			right = clamp(right + delta.x, left + minimum.x, viewport_size.x)
		if _resize_edges & EDGE_TOP:
			top = clamp(top + delta.y, 0, bottom - minimum.y)
		if _resize_edges & EDGE_BOTTOM:
			bottom = clamp(bottom + delta.y, top + minimum.y, viewport_size.y)
		rect_global_position = Vector2(left, top)
		rect_size = Vector2(right - left, bottom - top)

# Keeps enough of the window on screen so it can always be grabbed again.
func _clamp_position(pos):
	var viewport_size = get_viewport_rect().size
	pos.x = clamp(pos.x, KEEP_VISIBLE_X - rect_size.x, viewport_size.x - KEEP_VISIBLE_X)
	pos.y = clamp(pos.y, 0, viewport_size.y - KEEP_VISIBLE_Y)
	return pos

func _keep_on_screen():
	rect_global_position = _clamp_position(rect_global_position)

func reset_window():
	rect_global_position = _default_rect.position
	rect_size = _default_rect.size
	_end_drag()

func _input(event):
	if _handle_zoom_event(event) or _handle_copy_event(event):
		get_tree().set_input_as_handled()
		return
	_refocus_input_on_typing(event)
	
	if not input.has_focus() or not event.is_pressed():
		return

	if event.is_action("tab_complete"):
		if completions.visible:
			completions.get_root().get_children().select(0)
		get_tree().set_input_as_handled()
	elif event.is_action("delete_word"):
		var first_half = input.text.substr(0,input.caret_position)
		var second_half = input.text.substr(input.caret_position)
		
		var idx = first_half.strip_edges(false, true).find_last(" ")
		if idx > 0:
			input.text = first_half.substr(0,idx+1) + second_half
			input.caret_position = idx+1
		else:
			input.text = "" + second_half
	elif event.is_action("clear"):
		clear()
	elif event.is_action("ui_page_up"):
		var scroll = output.get_v_scroll()
		scroll.set_value(scroll.value - output.get_rect().size.y / 2)
	elif event.is_action("ui_page_down"):
		var scroll = output.get_v_scroll()
		scroll.set_value(scroll.value + output.get_rect().size.y / 2)
	elif game.state["history"].size() > 0:
		if event.is_action("ui_up"):
			if history_position > 0:
				history_position -= 1
				input.text = game.state["history"][history_position]
				input.caret_position = input.text.length()
			# This prevents the Input taking the arrow as a "skip to beginning" command.
			get_tree().set_input_as_handled()
		elif event.is_action("ui_down"):
			if history_position < game.state["history"].size():
				history_position += 1
				if history_position == game.state["history"].size():
					input.text = ""
				else:
					input.text = game.state["history"][history_position]
				input.caret_position = input.text.length()
			get_tree().set_input_as_handled()

func load_command(id):
	input.text = premade_commands[id]
	input.caret_position = input.text.length()

func send_command(command):
	close_all_editors()
	game.state["history"].push_back(command)
	game.save_state()
	history_position = game.state["history"].size()
	
	# `clear` (and `cls`) wipes the terminal output like in a real terminal.
	# It is handled here because there is no real terminal behind the output.
	if command.strip_edges() in ["clear", "cls"]:
		clear()
		input.text = ""
		completions.hide()
		input.grab_focus()
		return
	
	input.editable = false
	completions.hide()

	var pretty_command = command

	# `git revert` would open an editor for the commit message and wait for it
	# before creating the commit. Skip that so the revert happens right away.
	command = make_revert_non_interactive(command)

	# If someone tries to run an editor, use fake-editor instead.
	var editor_regex = RegEx.new()
	editor_regex.compile("^(vim?|gedit|emacs|kate|nano|code) ")
	command = editor_regex.sub(command, "fake-editor ")
	# If someone tries to run git and don't pipe it, add color
	var commands = command.rsplit("|", 1)
	var git_regex = RegEx.new()
	git_regex.compile("^git ([^>|]*)$")
	commands[-1] = git_regex.sub(commands[-1], "git -c color.ui=always $1")
	var gnu_color_regex = RegEx.new()
	gnu_color_regex.compile("^(\\s*([a-z]?grep|ls|diff))\\b([^>]*)$")
	commands[-1] = gnu_color_regex.sub(commands[-1], "$1 --color=always$3")
	command = "|".join(commands)

	shell.cd(repository.path)
	var cmd = shell.run_async(command, pretty_command, false)
	yield(cmd, "done")
	call_deferred("command_done", cmd)

func make_revert_non_interactive(command):
	var revert_regex = RegEx.new()
	revert_regex.compile("^\\s*git\\s+revert\\b")
	if revert_regex.search(command) == null:
		return command
	
	# Respect flags where the player explicitly decides about the editor or
	# the commit, or is continuing/aborting a running revert.
	var padded = " " + command + " "
	var flags = ["--no-edit", "--edit", "-e", "-n", "--no-commit", "--continue", "--abort", "--quit", "--skip"]
	for flag in flags:
		if (" " + flag + " ") in padded:
			return command
	
	return revert_regex.sub(command, "git revert --no-edit")

func strip_ansi(text):
	var ansi_regex = RegEx.new()
	ansi_regex.compile(char(27) + "\\[[0-9;?]*[A-Za-z]")
	return ansi_regex.sub(text, "", true)

func add_ansi_command(pager, cmd):
	pager.push_color(Color.darkgoldenrod)
	pager.add_text("$ ")
	pager.push_color(pager.get_color("default_color"))
	pager.add_text(cmd.pretty_command + "\n")

func perform_ansi(pager, codes):
	# TODO lacks support for bold, italics, strikthrough, strong colors, etc
	# Not doing that for now because there are no relevant fonts anyways.
	for code in codes.split(";"):
		match code:
			"","0","39": # reset, reset, normal color
				pager.push_color(pager.get_color("default_color"))
			_: # 30 <= code <= 37 -> colors
				var color_index = int(code) - 30
				if (color_index >= 0) and (color_index <= 7):
					pager.push_color(COLORS[color_index])

func add_ansi_output(pager, cmd):
	var escape_start = char(27) + "["
	var escape_end = "m"
	var data = cmd.output
	while escape_start in data:
		var parts = data.split(escape_start, true, 1)
		pager.add_text(parts[0])
		if parts[1].begins_with("K"):
			data = parts[1].substr(1)
			continue
		if "m" in parts[1]:
			parts = parts[1].split("m", true, 1)
			data = parts[1]
			perform_ansi(pager, parts[0])
		else:
			data = parts[1]
	pager.add_text(data)

func command_done(cmd):
	if cmd.exit_code == 0:
		$OkSound.pitch_scale = rand_range(0.8, 1.2)
		$OkSound.play()
	else:
		$ErrorSound.play()
	
	input.text = ""
	input.editable = true
	
	transcript += "$ " + cmd.pretty_command + "\n" + strip_ansi(cmd.output)
	if not transcript.ends_with("\n"):
		transcript += "\n"
	
	add_ansi_command(output, cmd)
	if cmd.output.length() <= 1000:
		add_ansi_output(output, cmd)
		game.notify("This is your terminal! All commands are executed here, and you can see their output. You can also type your own commands here!", self, "terminal")
	else:
		var pager = $Pager/Text
		pager.clear()
		add_ansi_output(pager, cmd)
		# The pager is a popup, so it positions itself in screen coordinates.
		var screen = get_viewport_rect().size
		$Pager.popup(Rect2(60, 90, screen.x - 120, screen.y - 150))
	
	emit_signal("command_done")
	
func receive_output(text):
	output.text += text
	repository.update_everything()

func clear():
	output.clear()
	transcript = ""
	
func editor_closed():
	input.grab_focus()
		
func regenerate_completions_menu(new_text):
	var comp = generate_completions(new_text)
	
	completions.clear()
	
	
	var filtered_comp = []
	for c in comp:
		if c != new_text:
			filtered_comp.push_back(c)
	
	if filtered_comp.size() == 0:
		completions.hide()
	else:
		completions.show()
	
		var _root = completions.create_item()
		for c in filtered_comp:
			var child = completions.create_item()
			child.set_text(0, c)
			if c.split(" ").size() >= 2:
				var subcommand = c.split(" ")[1]
				var idx = git_commands.find(subcommand)
				if idx >= 0:
					child.set_text(1, git_commands_help[idx])
					
		# The menu opens right below the input line and grows downwards.
		var row_height = term_font.get_height() + 12
		var visible_rows = min(filtered_comp.size(), 5)
		completions.margin_top = 0
		completions.margin_bottom = min(visible_rows * row_height + 10, $Rows/TopHalf.rect_size.y)

func relevant_subcommands():
	var result = {}
	for h in game.state["history"]:
		var parts = Array(h.split(" "))
		if parts.size() >= 2 and parts[0] == "git":
			var subcommand = parts[1]
			if git_commands.has(subcommand):
				if not result.has(subcommand):
					result[subcommand] = 0
				result[subcommand] += 1
	
	# Convert to format [["add", 3], ["pull", 5]].
	var result_array = []
	for r in result:
		result_array.push_back([r, result[r]])
	
	result_array.sort_custom(self, "sort_by_frequency_desc")
	
	var plain_result = []
	for r in result_array:
		plain_result.push_back(r[0])
	return plain_result

func sort_by_frequency_desc(a, b):
	return a[1] > b[1]
	
func generate_completions(command):
	var results = []
	
	# Collect git commands.
	if command.substr(0, 4) == "git ":
		var rest = command.substr(4)
		var subcommands = relevant_subcommands()
		
		for sc in subcommands:
			if sc.substr(0, rest.length()) == rest:
				results.push_back("git "+sc)
	
	# Part 1: Only autocomplete after git subcommand.
	# Part2: Prevent autocompletion to only show filename at the beginning of a command.
	if !(command.substr(0,4) == "git " and command.split(" ").size() <= 2) and command.split(" ").size() > 1:
		var last_word = Array(command.split(" ")).pop_back()
		var file_string = repository.shell.run("find . -type f")
		var files = file_string.split("\n")
		files = Array(files)
		# The last entry is an empty string, remove it.
		files.pop_back()
		for file_path in files:
			file_path = file_path.substr(2)
			if file_path.substr(0,4) != ".git" and file_path.substr(0,last_word.length()) == last_word:
				results.push_back(command+file_path.substr(last_word.length()))
	
	return results

func _input_changed(new_text):
	call_deferred("regenerate_completions_menu", new_text)

func _completion_selected():
	var item = completions.get_selected()
	input.text = item.get_text(0)
	input.emit_signal("text_changed", input.text)
	#completions.hide()
	input.grab_focus()
	input.caret_position = input.text.length()

func editor_saved():
	emit_signal("command_done")

func close_all_editors():
	for editor in get_tree().get_nodes_in_group("editors"):
		editor.close()
