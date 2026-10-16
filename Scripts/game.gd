extends Node

# ---------------- Connection settings ----------------
# Exported builds (web and desktop) connect securely through Caddy on the game droplet
# (139.59.76.134): wss://LIVE_SERVER_HOST/manager and wss://LIVE_SERVER_HOST/lobby/<port>
# Running from the Godot editor connects to a manager on this computer: ws://localhost:<port>
const LIVE_SERVER_HOST := "139-59-76-134.sslip.io"
# true: exported desktop builds connect straight to the droplet's IP instead (ws://, no Caddy needed).
# Browser builds always use the secure address above, since https pages can't use plain ws://.
const USE_DIRECT_IP := true
const DIRECT_SERVER_IP := "139.59.76.134"

const MANAGER_PORT := 9999
const LOBBY_PORT_FIRST := 10000
const MAX_LOBBIES := 5             # every lobby is its own server process (~70 MB each)
const MAX_PLAYERS := 8
const MIN_PLAYERS_TO_START := 2
const CODE_LENGTH := 20
const CODE_CHARS := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
const EMPTY_LOBBY_TIMEOUT := 60.0  # a lobby nobody joins closes after this many seconds
const REGISTER_TIMEOUT := 5.0      # connections that don't send the right code get dropped
const LOBBY_CONNECT_RETRIES := 10  # a new lobby server needs a moment to start up

const Player = preload("res://Scenes/player.tscn")
const BUTTON_SOUND = preload("res://Assets/SFX/button_press.tres")   # random pitch is set in this file
const FONT = preload("res://Assets/UI/PixelOperator8.ttf")
const FONT_BOLD = preload("res://Assets/UI/PixelOperator8-Bold.ttf")
const TITLE_MENU_WIDTH := 314.0    # main/lobby menu width on the title screen (wide enough for "Paste lobby code here")
const TITLE_MENU_MARGIN := 0.02    # gap left of the menu, as a fraction of the window width
const TITLE_WORDS_START := 0.3     # the title words start this far across the title picture (the rest is empty grass)
const TITLE_MENU_MIN_SCALE := 0.8  # the menu may shrink to this size to make room for the title
const TITLE_GRASS_COLOR := Color8(114, 117, 27)   # the title picture's grass, used to fill any gap around it

# One card per move in the Tutorial screen: picture, name, keys, and what it does
const TUTORIAL_MOVES = [
	{"pic": "move", "name": "Move", "keys": "W A S D", "info": "Walk around. You always face your mouse."},
	{"pic": "slash", "name": "Slash", "keys": "Left Click", "info": "Quick swing. 10 damage, a small push."},
	{"pic": "thrust", "name": "Thrust", "keys": "Click again right after a Slash", "info": "Follow-up poke once the Slash finishes. 5 damage."},
	{"pic": "lunge", "name": "Lunge", "keys": "Hold Left Click", "info": "Dash forward with a stab in the way you aim. 20 damage, big push."},
	{"pic": "spin", "name": "Spin Attack", "keys": "Hold Space", "info": "Spin your sword and hit everyone around you. 25 damage, 25 mana."},
	{"pic": "smash", "name": "Smash", "keys": "Hold Q", "info": "Slam the ground and crack it. 40 damage, huge push. Costs 30 mana."},
	{"pic": "swish", "name": "Swish", "keys": "Hold R", "info": "Wind up, then teleport straight through the enemy. 30 damage. Costs 25 mana."},
	{"pic": "block", "name": "Block", "keys": "Hold Right Click", "info": "Shield follows your mouse and stops hits from the front. Blocking costs mana; at 0 mana hits go through."},
	{"pic": "dash", "name": "Dash", "keys": "Shift", "info": "Quick burst of speed. Costs 10 mana."},
]

@onready var main_menu: Control = $CanvasLayer/MainMenu
@onready var host_button: Button = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/HostButton
@onready var join_button: Button = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/JoinButton
@onready var code_entry: LineEdit = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/AddressEntry
@onready var menu_status: Label = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/StatusLabel
@onready var lobby_menu: Control = $CanvasLayer/LobbyMenu
@onready var lobby_code_box: LineEdit = $CanvasLayer/LobbyMenu/MarginContainer/VBoxContainer/CodeRow/CodeBox
@onready var player_list: Label = $CanvasLayer/LobbyMenu/MarginContainer/VBoxContainer/PlayerList
@onready var start_button: Button = $CanvasLayer/LobbyMenu/MarginContainer/VBoxContainer/StartButton
@onready var lobby_status: Label = $CanvasLayer/LobbyMenu/MarginContainer/VBoxContainer/LobbyStatus
@onready var name_tag: LineEdit = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/NameTag
@onready var tutorial_menu: Control = $CanvasLayer/TutorialMenu
@onready var tutorial_list: VBoxContainer = $CanvasLayer/TutorialMenu/MarginContainer/Box/Scroll/Moves
@onready var leaderboard: PanelContainer = $LeaderboardLayer/Leaderboard
@onready var leaderboard_grid: GridContainer = $LeaderboardLayer/Leaderboard/Box/Grid

enum Role { CLIENT, MANAGER, LOBBY_SERVER }
var role := Role.CLIENT

# Manager state
var lobbies := {}   # code -> { "port": int, "pid": int }

# Lobby server state
var lobby_code := ""
var members: Array[int] = []   # peer ids in join order; members[0] is the host
var member_names := {}         # peer id -> the name they typed (or "Player N")
var game_started := false

# Client state
var client_phase := ""         # "manager" while asking for a lobby, "lobby" once in one
var pending_action := ""       # "create" or "join"
var current_code := ""
var lobby_port := 0
var connect_attempts := 0
var refusal_message := ""

# Leaderboard (hold Tab in a match)
var title_backdrop: ColorRect   # grass-coloured fill behind the title picture (made by _layout_title_screen)
var player_names := {}         # peer id -> name, sent when the match starts
var scores := {}               # peer id -> {"kills": int, "deaths": int}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port_arg := _arg_value(args, "--lobby-port=")
	if port_arg != "":
		_start_lobby_server(int(port_arg), _arg_value(args, "--lobby-code="))
	elif "--manager" in args:
		_start_manager()
	else:
		_setup_client()


func _arg_value(args: PackedStringArray, prefix: String) -> String:
	for arg in args:
		if arg.begins_with(prefix):
			return arg.substr(prefix.length())
	return ""


func _listen(port: int) -> bool:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_error("Could not listen on port %d (error %d)" % [port, err])
		return false
	multiplayer.multiplayer_peer = peer
	return true


# =====================================================================
# Lobby manager: hands out codes and starts one lobby server per code
# =====================================================================

func _start_manager() -> void:
	role = Role.MANAGER
	main_menu.hide()
	if not _listen(MANAGER_PORT):
		get_tree().quit(1)
		return
	var cleanup := Timer.new()
	cleanup.wait_time = 5.0
	cleanup.timeout.connect(_remove_dead_lobbies)
	add_child(cleanup)
	cleanup.start()
	print("Lobby manager listening on port %d" % MANAGER_PORT)


func _remove_dead_lobbies() -> void:
	for code in lobbies.keys():
		if not OS.is_process_running(lobbies[code].pid):
			lobbies.erase(code)


func _free_lobby_port() -> int:
	var used := []
	for lobby in lobbies.values():
		used.append(lobby.port)
	for i in MAX_LOBBIES:
		var port := LOBBY_PORT_FIRST + i
		if port not in used:
			return port
	return -1


func _new_code() -> String:
	var bytes := Crypto.new().generate_random_bytes(CODE_LENGTH)
	var code := ""
	for b in bytes:
		code += CODE_CHARS[b % CODE_CHARS.length()]
	return code


@rpc("any_peer", "reliable")
func request_create_lobby() -> void:
	if role != Role.MANAGER:
		return
	var sender := multiplayer.get_remote_sender_id()
	_remove_dead_lobbies()
	var port := _free_lobby_port()
	if port == -1:
		lobby_error.rpc_id(sender, "The server is full right now. Try again later.")
		return

	var code := _new_code()
	var args := PackedStringArray()
	if OS.has_feature("editor"):
		# Running from the Godot editor: the child needs to be told where the project is
		args.append_array(["--path", ProjectSettings.globalize_path("res://")])
	args.append_array(["--headless", "--", "--lobby-port=%d" % port, "--lobby-code=%s" % code])
	var pid := OS.create_process(OS.get_executable_path(), args)
	if pid == -1:
		lobby_error.rpc_id(sender, "Could not create a lobby.")
		return

	lobbies[code] = {"port": port, "pid": pid}
	print("Started lobby %s on port %d" % [code, port])
	lobby_ready.rpc_id(sender, code, port)


@rpc("any_peer", "reliable")
func request_join_lobby(code: String) -> void:
	if role != Role.MANAGER:
		return
	var sender := multiplayer.get_remote_sender_id()
	_remove_dead_lobbies()
	if not lobbies.has(code):
		lobby_error.rpc_id(sender, "No lobby with that code.")
		return
	lobby_ready.rpc_id(sender, code, lobbies[code].port)


# =====================================================================
# Lobby server: one per lobby, runs the waiting room and then the match
# =====================================================================

func _start_lobby_server(port: int, code: String) -> void:
	role = Role.LOBBY_SERVER
	lobby_code = code
	main_menu.hide()
	if not _listen(port):
		get_tree().quit(1)
		return
	multiplayer.peer_connected.connect(_on_lobby_peer_connected)
	multiplayer.peer_disconnected.connect(_on_lobby_peer_disconnected)
	get_tree().create_timer(EMPTY_LOBBY_TIMEOUT).timeout.connect(_quit_if_empty)
	print("Lobby %s listening on port %d" % [code, port])


func _quit_if_empty() -> void:
	if members.is_empty():
		get_tree().quit()


func _on_lobby_peer_connected(id: int) -> void:
	if game_started:
		_refuse(id, "That game has already started.")
		return
	await get_tree().create_timer(REGISTER_TIMEOUT).timeout
	if id not in members and id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _on_lobby_peer_disconnected(id: int) -> void:
	if id not in members:
		return
	members.erase(id)
	member_names.erase(id)
	remove_player(id)
	if members.is_empty():
		get_tree().quit()
	elif not game_started:
		_broadcast_lobby()


func _refuse(id: int, message: String) -> void:
	join_refused.rpc_id(id, message)
	# Give the message a moment to arrive before hanging up
	await get_tree().create_timer(0.5).timeout
	if id in multiplayer.get_peers():
		multiplayer.multiplayer_peer.disconnect_peer(id)


func _broadcast_lobby() -> void:
	for id in members:
		update_lobby.rpc_id(id, members, members[0], member_names)


@rpc("any_peer", "reliable")
func register_in_lobby(code: String, player_name: String) -> void:
	if role != Role.LOBBY_SERVER:
		return
	var id := multiplayer.get_remote_sender_id()
	if code != lobby_code:
		_refuse(id, "Wrong lobby code.")
	elif game_started:
		_refuse(id, "That game has already started.")
	elif members.size() >= MAX_PLAYERS:
		_refuse(id, "That lobby is full.")
	elif id not in members:
		members.append(id)
		player_name = player_name.strip_edges().left(16)
		member_names[id] = player_name if player_name != "" else "Player %d" % members.size()
		_broadcast_lobby()


@rpc("any_peer", "reliable")
func request_start_game() -> void:
	if role != Role.LOBBY_SERVER or game_started:
		return
	var id := multiplayer.get_remote_sender_id()
	if members.is_empty() or id != members[0] or members.size() < MIN_PLAYERS_TO_START:
		return
	game_started = true
	for member in members:
		add_player(member)
	for member in members:
		on_game_started.rpc_id(member, member_names)
	print("Lobby %s started with %d players" % [lobby_code, members.size()])


# =====================================================================
# Client: menus, connecting, lobby screen
# =====================================================================

func _setup_client() -> void:
	role = Role.CLIENT
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	lobby_menu.hide()
	main_menu.show()
	menu_status.text = ""

	# Fit the title screen to the window now and whenever the window is resized
	get_viewport().size_changed.connect(_layout_title_screen)
	_layout_title_screen.call_deferred()

	# One click sound for every menu button, played the moment it's pressed down
	var click := AudioStreamPlayer.new()
	click.stream = BUTTON_SOUND
	add_child(click)
	for button in find_children("*", "BaseButton", true, false):
		button.button_down.connect(click.play)

	tutorial_menu.hide()
	_build_tutorial()


func _process(_delta: float) -> void:
	if role != Role.CLIENT:
		return
	# Only during a match: hold Tab to see the scores
	var show := Input.is_key_pressed(KEY_TAB) and not _players().is_empty()
	if show and not leaderboard.visible:
		_refresh_leaderboard()
	leaderboard.visible = show


# ---------------- Leaderboard ----------------

func _players() -> Array:
	return get_children().filter(func(c): return c.scene_file_path == Player.resource_path)


# The panel, title and grid are in game.tscn (LeaderboardLayer); this fills in the rows
func _refresh_leaderboard() -> void:
	for child in leaderboard_grid.get_children():
		child.queue_free()
	var gold := Color(1, 0.85, 0.4)
	for header in ["#", "Player", "Kills", "Deaths"]:
		leaderboard_grid.add_child(_board_cell(header, FONT_BOLD, gold))

	# Only players still in the match; most kills first, fewer deaths breaks ties
	var ids: Array = _players().map(func(p): return str(p.name).to_int())
	ids.sort_custom(func(a, b):
		var sa := _score(a)
		var sb := _score(b)
		if sa.kills != sb.kills:
			return sa.kills > sb.kills
		return sa.deaths < sb.deaths)

	var my_id := multiplayer.get_unique_id()
	for i in ids.size():
		var id: int = ids[i]
		var color := Color(0.55, 0.85, 1) if id == my_id else Color(0.92, 0.92, 0.92)
		var player_name: String = player_names.get(id, "Player %d" % id)
		if id == my_id:
			player_name += " (you)"
		leaderboard_grid.add_child(_board_cell(str(i + 1), FONT, color))
		leaderboard_grid.add_child(_board_cell(player_name, FONT, color))
		leaderboard_grid.add_child(_board_cell(str(_score(id).kills), FONT, color))
		leaderboard_grid.add_child(_board_cell(str(_score(id).deaths), FONT, color))


func _score(id: int) -> Dictionary:
	return scores.get(id, {"kills": 0, "deaths": 0})


func _board_cell(text: String, font: Font, color: Color) -> Label:
	var label := _tutorial_label(text, font, color)
	label.autowrap_mode = TextServer.AUTOWRAP_OFF
	return label


# Sent by a player when they die, to everyone (including themselves)
@rpc("any_peer", "call_local", "reliable")
func record_kill(killer_id: int, victim_id: int) -> void:
	# The victim's own game sends this, so ignore anyone reporting a death that isn't theirs
	var sender := multiplayer.get_remote_sender_id()
	if sender != 0 and sender != victim_id and sender != multiplayer.get_unique_id():
		return
	var victim := _score(victim_id)
	victim.deaths += 1
	scores[victim_id] = victim
	if killer_id != victim_id and killer_id != 0:
		var killer := _score(killer_id)
		killer.kills += 1
		scores[killer_id] = killer
	if leaderboard and leaderboard.visible:
		_refresh_leaderboard()


# The title animation is a full background picture (1280x720) with empty space on its left:
# stretch it to cover the whole window, and put the menus in that empty space.
# The menus' CanvasLayer follows the camera, so everything here is in world units.
func _layout_title_screen() -> void:
	var cam: Camera2D = $Camera2D
	var view := Rect2()
	view.size = get_viewport().get_visible_rect().size / cam.zoom
	view.position = cam.get_screen_center_position() - view.size / 2

	var logo: AnimatedSprite2D = $SirCrumbs
	var frame_size := logo.sprite_frames.get_frame_texture(logo.animation, 0).get_size()
	var menu_left := view.position.x + view.size.x * TITLE_MENU_MARGIN
	# Fill the whole window with the picture; on very wide windows fit the height instead so the knight isn't cut off
	var fit := minf(maxf(view.size.x / frame_size.x, view.size.y / frame_size.y), view.size.y / frame_size.y)
	# Room left of the title words (the picture's right edge sits on the window's right edge)
	var room := view.end.x - frame_size.x * fit * (1.0 - TITLE_WORDS_START) - 10 - menu_left
	if room < TITLE_MENU_WIDTH * TITLE_MENU_MIN_SCALE:
		# Narrow window: shrink the picture until the smallest menu fits beside the words
		room = TITLE_MENU_WIDTH * TITLE_MENU_MIN_SCALE
		fit = (view.end.x - 10 - menu_left - room) / (frame_size.x * (1.0 - TITLE_WORDS_START))
	var menu_scale := minf(room / TITLE_MENU_WIDTH, 1.0)

	logo.centered = true
	logo.scale = Vector2(fit, fit)
	logo.position = Vector2(view.end.x - frame_size.x * fit / 2, view.get_center().y)
	# Any part of the window the picture doesn't reach gets the picture's grass colour, so the map never peeks through
	if title_backdrop == null:
		title_backdrop = ColorRect.new()
		title_backdrop.color = TITLE_GRASS_COLOR
		title_backdrop.show_behind_parent = true
		title_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
		logo.add_child(title_backdrop)
	title_backdrop.position = (view.position - logo.position) / fit
	title_backdrop.size = view.size / fit

	for menu: Control in [main_menu, lobby_menu]:
		menu.set_anchors_preset(Control.PRESET_TOP_LEFT)
		menu.custom_minimum_size.x = TITLE_MENU_WIDTH
		menu.size = Vector2.ZERO   # shrink to fit its contents
		menu.scale = Vector2(menu_scale, menu_scale)
		menu.position = Vector2(menu_left, view.get_center().y - menu.size.y * menu_scale / 2)


# Fills the Tutorial screen with one card per move (edit TUTORIAL_MOVES to change them)
func _build_tutorial() -> void:
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0, 0, 0, 0.35)
	card_style.border_color = Color(0.95, 0.75, 0.35, 0.8)
	card_style.set_border_width_all(2)
	card_style.set_content_margin_all(8)

	for move in TUTORIAL_MOVES:
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", card_style)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		card.add_child(row)

		var pic := TextureRect.new()
		pic.texture = load("res://Assets/UI/Tutorial/%s.png" % move.pic)
		pic.custom_minimum_size = Vector2(128, 64)   # pictures are 128x64, shown at exactly 1x so they stay crisp
		pic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		row.add_child(pic)

		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text.add_theme_constant_override("separation", 2)
		row.add_child(text)
		text.add_child(_tutorial_label(move.name, FONT_BOLD, Color(1, 0.85, 0.4)))
		text.add_child(_tutorial_label(move.keys, FONT, Color(0.55, 0.85, 1)))
		text.add_child(_tutorial_label(move.info, FONT, Color(0.92, 0.92, 0.92)))

		tutorial_list.add_child(card)


func _tutorial_label(text: String, font: Font, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", color)
	return label


func _on_tutorial_button_pressed() -> void:
	main_menu.hide()
	tutorial_menu.show()


func _on_tutorial_back_pressed() -> void:
	tutorial_menu.hide()
	main_menu.show()


func _use_live_server() -> bool:
	return not OS.has_feature("editor")


func _manager_url() -> String:
	if not _use_live_server():
		return "ws://localhost:%d" % MANAGER_PORT
	if USE_DIRECT_IP and not OS.has_feature("web"):
		return "ws://%s:%d" % [DIRECT_SERVER_IP, MANAGER_PORT]
	return "wss://%s/manager" % LIVE_SERVER_HOST


func _lobby_url(port: int) -> String:
	if not _use_live_server():
		return "ws://localhost:%d" % port
	if USE_DIRECT_IP and not OS.has_feature("web"):
		return "ws://%s:%d" % [DIRECT_SERVER_IP, port]
	return "wss://%s/lobby/%d" % [LIVE_SERVER_HOST, port]


func _connect_to(url: String) -> void:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		_return_to_menu.call_deferred("Could not connect (error %d)." % err)
		return
	var old_peer := multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = peer
	if old_peer is WebSocketMultiplayerPeer:
		old_peer.close()


func _on_host_button_pressed() -> void:
	pending_action = "create"
	_ask_manager()


func _on_join_button_pressed() -> void:
	var code := code_entry.text.strip_edges()
	if code.is_empty():
		menu_status.text = "Paste a lobby code first."
		return
	current_code = code
	pending_action = "join"
	_ask_manager()


func _ask_manager() -> void:
	host_button.disabled = true
	join_button.disabled = true
	menu_status.text = "Connecting to the server..."
	refusal_message = ""
	client_phase = "manager"
	_connect_to(_manager_url())


func _on_connected_to_server() -> void:
	if client_phase == "manager":
		if pending_action == "create":
			request_create_lobby.rpc_id(1)
		else:
			request_join_lobby.rpc_id(1, current_code)
	elif client_phase == "lobby":
		register_in_lobby.rpc_id(1, current_code, name_tag.text)


@rpc("authority", "reliable")
func lobby_ready(code: String, port: int) -> void:
	current_code = code
	lobby_port = port
	_switch_to_lobby.call_deferred()


func _switch_to_lobby() -> void:
	# Leave the manager and connect to this lobby's own server
	client_phase = "lobby"
	connect_attempts = 0
	menu_status.text = "Joining the lobby..."
	_connect_to(_lobby_url(lobby_port))


@rpc("authority", "reliable")
func lobby_error(message: String) -> void:
	_return_to_menu.call_deferred(message)


@rpc("authority", "reliable")
func join_refused(message: String) -> void:
	refusal_message = message


func _on_connection_failed() -> void:
	if client_phase == "lobby" and connect_attempts < LOBBY_CONNECT_RETRIES:
		# The lobby's server may still be starting up, so try again shortly
		connect_attempts += 1
		await get_tree().create_timer(0.5).timeout
		if client_phase == "lobby":
			_connect_to(_lobby_url(lobby_port))
		return
	_return_to_menu.call_deferred("Could not reach the server.")


func _on_server_disconnected() -> void:
	var message := refusal_message if refusal_message != "" else "Disconnected from the server."
	_return_to_menu.call_deferred(message)


@rpc("authority", "reliable")
func update_lobby(player_ids: Array, host_id: int, names: Dictionary) -> void:
	main_menu.hide()
	$SirCrumbs.hide()   # the title logo is only for the main menu
	lobby_menu.show()
	lobby_code_box.text = current_code

	var my_id := multiplayer.get_unique_id()
	var lines := PackedStringArray()
	for i in player_ids.size():
		var line: String = names[player_ids[i]]
		if player_ids[i] == host_id:
			line += " (host)"
		if player_ids[i] == my_id:
			line += " - you"
		lines.append(line)
	player_list.text = "\n".join(lines)

	var is_host := host_id == my_id
	var enough_players := player_ids.size() >= MIN_PLAYERS_TO_START
	start_button.visible = is_host
	start_button.disabled = not enough_players
	if not is_host:
		lobby_status.text = "Waiting for the host to start..."
	elif enough_players:
		lobby_status.text = "Ready! Press Start when everyone is in."
	else:
		lobby_status.text = "Send the code to a friend to let them join."


@rpc("authority", "reliable")
func on_game_started(names: Dictionary) -> void:
	lobby_menu.hide()
	_set_menu_mood(false)
	player_names = names
	scores.clear()
	for id in names:
		var player := get_node_or_null(str(id))
		if player:
			player.get_node("Label").text = names[id]


# Menu music and the menu Light: on in the menus, off once the match starts
func _set_menu_mood(in_menu: bool) -> void:
	$SirCrumbs.visible = in_menu
	if in_menu and not $TheSongsOfWar.playing:
		$TheSongsOfWar.play()
	elif not in_menu:
		$TheSongsOfWar.stop()


func _on_copy_button_pressed() -> void:
	_copy_to_clipboard(current_code)
	lobby_status.text = "Code copied!"


func _copy_to_clipboard(text: String) -> void:
	if OS.has_feature("web"):
		# Browsers only allow the modern clipboard API on https pages, so fall back to the old copy command
		JavaScriptBridge.eval("""
(function (t) {
	if (navigator.clipboard && window.isSecureContext) { navigator.clipboard.writeText(t); return; }
	var a = document.createElement('textarea');
	a.value = t;
	document.body.appendChild(a);
	a.select();
	document.execCommand('copy');
	document.body.removeChild(a);
})(%s)""" % JSON.stringify(text))
	else:
		DisplayServer.clipboard_set(text)


func _on_start_button_pressed() -> void:
	start_button.disabled = true
	request_start_game.rpc_id(1)


func _on_leave_button_pressed() -> void:
	_return_to_menu.call_deferred("")


func _return_to_menu(message: String) -> void:
	client_phase = ""
	var old_peer := multiplayer.multiplayer_peer
	multiplayer.multiplayer_peer = null
	if old_peer is WebSocketMultiplayerPeer:
		old_peer.close()
	for child in get_children():
		if child.scene_file_path == Player.resource_path:
			child.queue_free()
	$Camera2D.make_current()
	scores.clear()
	player_names.clear()
	leaderboard.hide()
	_set_menu_mood(true)
	lobby_menu.hide()
	main_menu.show()
	host_button.disabled = false
	join_button.disabled = false
	menu_status.text = message


func add_player(peer_id):
	var player = Player.instantiate()
	player.name = str(peer_id)   # must stay the peer id: it decides who controls this player
	add_child(player)

func remove_player(peer_id):
	var player = get_node_or_null(str(peer_id))
	if player:
		player.queue_free()
