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

	# One click sound for every menu button, played the moment it's pressed down
	var click := AudioStreamPlayer.new()
	click.stream = BUTTON_SOUND
	add_child(click)
	for button in find_children("*", "BaseButton", true, false):
		button.button_down.connect(click.play)


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
	for id in names:
		var player := get_node_or_null(str(id))
		if player:
			player.get_node("Label").text = names[id]


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
