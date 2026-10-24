extends Control

var dragged = null

# The terminal is a detached, floating window that is a direct child of Main.
onready var terminal = $Terminal
onready var input = terminal.get_node("Rows/InputLine/Input")
onready var output = terminal.get_node("Rows/TopHalf/Output")
onready var repositories_node = $Rows/Columns/Repositories
var repositories = {}
onready var next_level_button = $Menu/Button
onready var level_name = $Rows/Columns/RightSide/LevelInfo/LevelPanel/LevelName
onready var level_description = $Rows/Columns/RightSide/LevelInfo/LevelPanel/Text/LevelDescription
onready var level_congrats = $Rows/Columns/RightSide/LevelInfo/LevelPanel/Text/LevelCongrats
onready var cards = $Rows/Controls/Cards
onready var file_browser = $Rows/Columns/RightSide/FileBrowser
onready var goals = $Rows/Columns/RightSide/LevelInfo/LevelPanel/Goals

var _hint_server
var _hint_client_connection

func _ready():
	_hint_server = TCP_Server.new()
	_hint_server.listen(1235, "127.0.0.1")
	OS.set_environment("HINT_TCP_PORT", "1235")
	
	var args = helpers.parse_args()
	if args.has("sandbox"):
		get_tree().change_scene("res://scenes/sandbox.tscn")
		return
	
	# Refresh the repositories, file browser and goals as soon as a command has
	# *finished*. Commands run asynchronously, so refreshing right after the
	# player pressed Enter would show the state from before the command ran.
	if not terminal.is_connected("command_done", self, "update_repos"):
		terminal.connect("command_done", self, "update_repos")

	load_level(game.current_level)
	input.grab_focus()

func _process(delta):
	if _hint_server.is_connection_available():
		_hint_client_connection = _hint_server.take_connection()
		var length = _hint_client_connection.get_u32()
		var message = _hint_client_connection.get_string(length)
		game.notify(message)
		
	$Rows.rect_size.y = 1064

func load_chapter(id):
	game.current_chapter = id
	load_level(0)

func load_level(level_id):
	if next_level_button: next_level_button.hide()
	if level_congrats: level_congrats.hide()
	if level_description: level_description.show()
	
	game.current_level = level_id
	game.used_cards = false
	
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), true)
	levels.chapters[game.current_chapter].levels[game.current_level].construct()

	var level = levels.chapters[game.current_chapter].levels[game.current_level]
	if level_description: level_description.bbcode_text = level.description[0]
	if level_congrats: level_congrats.bbcode_text = level.congrats
	if level_name: level_name.text = level.title
	
	var slug = levels.chapters[game.current_chapter].slug + "/" + level.slug
	var badge = find_node("CLIBadge", true, false)
	if badge:
		badge.active = slug in game.state["cli_badge"]
		badge.sparkling = false
	
	cards.draw(levels.chapters[game.current_chapter].levels[game.current_level].cards)
	
	for r in repositories_node.get_children():
		r.queue_free()
	repositories = {}
	
	var repo_names = level.repos.keys()
	repo_names.invert()
	
	for r in repo_names:
		var repo = level.repos[r]
		var new_repo = preload("res://scenes/repository.tscn").instance()
		new_repo.path = repo.path
		new_repo.label = repo.slug
		new_repo.size_flags_horizontal = SIZE_EXPAND_FILL
		new_repo.size_flags_vertical = SIZE_EXPAND_FILL
		
		if new_repo.label == "yours":
			file_browser.repository = new_repo
			file_browser.update()
			
		repositories_node.add_child(new_repo)        
		repositories[r] = new_repo
	
	terminal.repository = repositories[repo_names[repo_names.size()-1]]
	terminal.clear()
	
	var editor = terminal.find_node("TextEditor", true, false)
	if editor: editor.close()
	
	update_repos()
	
	var t = Timer.new()
	t.wait_time = 1
	add_child(t)
	t.start()
	yield(t, "timeout")
	AudioServer.set_bus_mute(AudioServer.get_bus_index("SFX"), false)

func reload_level():
	cards.load_card_store()
	levels.reload()
	load_level(game.current_level)

func load_next_level():
	game.current_level += 1
	if game.current_level >= levels.chapters[game.current_chapter].levels.size():
		back()
	else:
		load_level(game.current_level)
	
func show_win_status(win_states):
	var all_won = true
	var win_text = "\n\n"
	
	for child in goals.get_children():
		child.queue_free()
			
	for state in win_states:
		var b = Label.new()
		b.text = state
		b.align = HALIGN_LEFT
		var bg = StyleBoxFlat.new()
		if win_states[state]:
			bg.bg_color = Color(0.1, 0.5, 0.1)
		else:
			bg.bg_color = Color(0.5, 0.1, 0.1)
		bg.corner_radius_bottom_left = 8
		bg.corner_radius_bottom_right = 8
		bg.corner_radius_top_left = 8
		bg.corner_radius_top_right = 8
		bg.content_margin_bottom = 8
		bg.content_margin_top = 8
		bg.content_margin_left = 8
		bg.content_margin_right = 8
		b.set("custom_styles/normal", bg)
		
		goals.add_child(b)
		b.autowrap = true
		if not win_states[state]:
			all_won = false
			
	var level = levels.chapters[game.current_chapter].levels[game.current_level]
	if level_description:
		level_description.bbcode_text = level.description[0] + win_text
		for i in range(1,level.tipp_level+1):
			level_description.bbcode_text += level.description[i]
			
	if level_congrats and not level_congrats.visible and all_won and win_states.size() > 0:
		if next_level_button: next_level_button.show()
		if level_description: level_description.hide()
		level_congrats.show()
		$SuccessSound.play()
		var slug = levels.chapters[game.current_chapter].slug + "/" + level.slug
		if not slug in game.state["solved_levels"]:
			game.state["solved_levels"].push_back(slug)
			game.save_state()
		if not game.used_cards and not slug in game.state["cli_badge"]:
			game.state["cli_badge"].push_back(slug)
			game.save_state()
			var badge = find_node("CLIBadge", true, false)
			if badge:
				badge.active = true
				badge.sparkling = true

# We added "_ignore=null" so this function can accept the signal
# from the terminal (which sends the command text) without crashing
# or being ignored by Godot.
func update_repos(_ignore=null):
	var win_states = levels.chapters[game.current_chapter].levels[game.current_level].check_win()
	show_win_status(win_states)
	
	for r in repositories:
		var repo = repositories[r]
		repo.update_everything()
	
	file_browser.update()
	
	if input: input.grab_focus()

func toggle_cards():
	if cards: cards.visible = not cards.visible
	
func new_tip():
	var level = levels.chapters[game.current_chapter].levels[game.current_level]
	if level.description.size() - 1 > level.tipp_level :
		level.tipp_level += 1
		if level_description:
			level_description.bbcode_text += level.description[level.tipp_level]

func back():
	get_tree().change_scene("res://scenes/level_select.tscn")
