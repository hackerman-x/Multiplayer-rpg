@tool
extends Node

@onready var main_menu = $CanvasLayer/MainMenu
@onready var address_entry = $CanvasLayer/MainMenu/MarginContainer/VBoxContainer/AddressEntry

const Player = preload("res://Scenes/player.tscn")
const PORT = 9999
var enet_peer = ENetMultiplayerPeer.new()


func _ready() -> void:
	# Only auto-generate from map_data.json the first time (when the layers
	# are still empty). Once tiles exist -- whether from generation or from
	# hand-painting in the editor -- this never touches them again, so any
	# edits you make in the TileMap editor are preserved into gameplay.
	var map_layer = get_node_or_null("Map")
	var props_layer = get_node_or_null("Props")
	if map_layer == null or props_layer == null:
		return
	if map_layer.get_used_cells().is_empty() and props_layer.get_used_cells().is_empty():
		_load_map()


func _load_map() -> void:
	var map_layer = get_node_or_null("Map")
	var props_layer = get_node_or_null("Props")
	if map_layer == null or props_layer == null:
		return

	var file = FileAccess.open("res://Assets/map_data.json", FileAccess.READ)
	if file == null:
		push_warning("map_data.json not found, skipping map generation")
		return
	var data = JSON.parse_string(file.get_as_text())
	file.close()
	if data == null:
		push_warning("map_data.json failed to parse")
		return

	map_layer.clear()
	for cell in data.get("floor", []):
		map_layer.set_cell(Vector2i(cell[0], cell[1]), 0, Vector2i(cell[2], 0))

	props_layer.clear()
	for cell in data.get("props", []):
		props_layer.set_cell(Vector2i(cell[0], cell[1]), 1, Vector2i(cell[2], cell[3]))


func _on_host_button_pressed() -> void:
	if Engine.is_editor_hint():
		return
	main_menu.hide()

	enet_peer.create_server(PORT)
	multiplayer.multiplayer_peer = enet_peer
	multiplayer.peer_connected.connect(add_player)

	add_player(multiplayer.get_unique_id())

func _on_join_button_pressed() -> void:
	if Engine.is_editor_hint():
		return
	main_menu.hide()

	enet_peer.create_client("localhost", PORT)
	multiplayer.multiplayer_peer = enet_peer


func add_player(peer_id):
	var player = Player.instantiate()
	player.name = str(peer_id)
	add_child(player)
