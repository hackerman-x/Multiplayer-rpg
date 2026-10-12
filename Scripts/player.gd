extends CharacterBody2D

@onready var hitbox: Area2D = $HitBoxNode
@onready var block_area: Area2D = $Shield
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var sprite: AnimatedSprite2D = $SirCrumbsBottom  # adjust path/type to match your actual sprite node
@onready var camera: Camera2D = $Camera2D

var SPEED = 100.0
var DASH = 200.0
var BASE_SPEED = 100.0
var LUNGE_SPEED = 250.0
var BLOCK_SPEED_MULTIPLIER = 0.5

var OFFENSIVE_DURATION = 0.4   # lock time for lunge attacks
var NORMAL_DURATION = 0.001     # lock time for quick basic slashes
var HOLD_DURATION = 0.4        # how long you must hold attack before the charged (Stab) attack fires

var move_map = {
	"none_up": "Jodan Slice",
	"none_down": "Gedan Slice",
	"none_left": "Side Slash Left",
	"none_right": "Side Slash Right"
}

var offensive_map = {
	"left": "Forward Lunge Left",
	"right": "Forward Lunge Right",
	"up": "Forward Overhead",
	"down": "South Slash"
}

var defensive_map = {
	"left": "Left-Defensive",
	"right": "Right-Defensive",
	"up": "Up-Defensive",
	"down": "Down-Defensive"
}

var lunge_moves = {
	"Forward Lunge Left": Vector2.LEFT,
	"Forward Lunge Right": Vector2.RIGHT,
	"Forward Overhead": Vector2.UP,
	"South Slash": Vector2.DOWN
}

var combos = {
	["Jodan Slice"]: "Jodan Slice",
	["Gedan Slice"]: "Gedan Slice",
	["Down-Defensive", "Forward Overhead"]: "Counter Attack"
}

var moves = []
var attacking := false
var defending := false
var lunging := false
var blocking := false
var lunge_direction := Vector2.ZERO

# charge tracking for hold-to-lunge
var charging := false
var charge_direction := ""
var charge_start_time := 0.0
var lunge_triggered := false

var health := 3

# aim is frozen from the moment a move fires until its animation finishes
var aim_locked := false
var locked_angle := 0.0
var locked_aim_dir := ""
var hit = false

# shared cooldown for every attack and block (starts when the move's lock time ends)
var ATTACK_COOLDOWN = 0.1
var cooldown_end := 0.0


func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())



func is_local_player() -> bool:
	return not multiplayer.has_multiplayer_peer() or is_multiplayer_authority()



func _ready() -> void:
	Global.player = self
	$Shield.visible = false
	if str(name) == "1":
		$Label.text = "Host"
	else:
		$Label.text = "Player " + str(name)

	hitbox.monitoring = false
	block_area.monitoring = false
	anim_player.animation_finished.connect(_on_animation_finished)

	if not is_local_player(): return

	camera.make_current()



func _unhandled_input(_event: InputEvent) -> void:
	if not is_local_player(): return



func _physics_process(_delta: float) -> void:
	if not is_local_player(): return
	var direction_x := Input.get_axis("left", "right")
	var direction_y := Input.get_axis("up", "down")
	
	if lunging:
		velocity = lunge_direction * LUNGE_SPEED
	elif blocking:
		velocity = Vector2(direction_x, direction_y) * SPEED * BLOCK_SPEED_MULTIPLIER
	elif attacking:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.y = move_toward(velocity.y, 0, SPEED)
	elif direction_x or direction_y:
		velocity.x = direction_x * SPEED
		velocity.y = direction_y * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.y = move_toward(velocity.y, 0, SPEED)
	
	move_and_slide()

	if aim_locked:
		$Attack.global_rotation = locked_angle
		$HitBoxNode.global_rotation = locked_angle
		$Shield.global_rotation = locked_angle
	else:
		$Attack.look_at(get_global_mouse_position())
		$HitBoxNode.look_at(get_global_mouse_position())
		if blocking:
			set_shield_angle.rpc((get_global_mouse_position() - global_position).angle())

	apply_facing.rpc(body_animation())

	if Input.is_action_just_pressed("Dash"):
		$DashTimer.start()
		SPEED = DASH
		$GPUParticles2D.emitting = true
	
	if not blocking:
		handle_attack_input()

	if Input.is_action_just_pressed("block"):
		handle_block()
	elif blocking and not Input.is_action_pressed("block"):
		stop_block()



func handle_attack_input() -> void:
	var aim_dir = get_aim_direction()

	if Input.is_action_just_pressed("attack"):
		if offensive_map.has(aim_dir):
			charging = true
			lunge_triggered = false
			charge_direction = aim_dir
			charge_start_time = Time.get_ticks_msec() / 1000.0
		else:
			charging = false
			fire_normal_attack(aim_dir)

	if charging and Input.is_action_pressed("attack"):
		var held_time = (Time.get_ticks_msec() / 1000.0) - charge_start_time

		if held_time >= HOLD_DURATION and not lunge_triggered:
			lunge_triggered = true
			var move_name = offensive_map[charge_direction]
			register_move(move_name, false, OFFENSIVE_DURATION)

	if Input.is_action_just_released("attack"):
		if charging and not lunge_triggered:
			fire_normal_attack(aim_dir)
		charging = false
		lunge_triggered = false



func fire_normal_attack(aim_dir: String) -> void:
	var key = "none_" + aim_dir
	if move_map.has(key):
		var move_name = move_map[key]
		register_move(move_name, false, NORMAL_DURATION)



func can_act() -> bool:
	return Time.get_ticks_msec() / 1000.0 >= cooldown_end



func handle_block() -> void:
	if blocking or not can_act(): return
	var aim := get_global_mouse_position() - global_position

	blocking = true
	attacking = true
	defending = true
	charging = false
	block_area.monitoring = true
	$AttackTimer.stop()
	aim_locked = false
	track_combo(defensive_map[opposite_direction(dir_from_vector(aim))])
	set_shield_angle.rpc(aim.angle())
	play_animation.rpc("BlockStart")


func stop_block() -> void:
	blocking = false
	attacking = false
	defending = false
	block_area.monitoring = false
	cooldown_end = Time.get_ticks_msec() / 1000.0 + ATTACK_COOLDOWN
	end_block_visuals.rpc()


@rpc("call_local", "unreliable_ordered")
func set_shield_angle(angle: float) -> void:
	$Shield.global_rotation = angle


@rpc("call_local")
func end_block_visuals() -> void:
	aim_locked = false
	anim_player.stop()
	$Shield.visible = false
	$Shield/CollisionShape2D.set_deferred("disabled", true)



func opposite_direction(dir: String) -> String:
	match dir:
		"up": return "down"
		"down": return "up"
		"left": return "right"
		"right": return "left"
	return ""




func get_aim_direction() -> String:
	if aim_locked:
		return locked_aim_dir
	return dir_from_vector(get_global_mouse_position() - global_position)


func dir_from_vector(v: Vector2) -> String:
	if abs(v.x) > abs(v.y):
		return "right" if v.x > 0 else "left"
	return "down" if v.y > 0 else "up"



func register_move(move_name: String, is_defensive: bool, duration: float) -> void:
	if not can_act(): return
	cooldown_end = Time.get_ticks_msec() / 1000.0 + duration + ATTACK_COOLDOWN
	track_combo(move_name)
	perform_attack(move_name, is_defensive, duration)


func track_combo(move_name: String) -> void:
	moves.append(move_name)
	$Timer.start()

	if combos.has(moves) and moves.size() > 1:
		var _combo_name = combos[moves]
	
	var could_extend = false
	for combo_seq in combos.keys():
		if combo_seq.size() > moves.size() and combo_seq.slice(0, moves.size()) == moves:
			could_extend = true
			break
	if not could_extend:
		moves.clear()


func perform_attack(move_name: String, is_defensive: bool, duration: float) -> void:
	var angle := (get_global_mouse_position() - global_position).angle()
	if lunge_moves.has(move_name):
		angle = lunge_moves[move_name].angle()
	lock_aim.rpc(angle)

	attacking = true
	defending = is_defensive
	hitbox.monitoring = true
	block_area.monitoring = is_defensive

	$AttackTimer.wait_time = duration
	$AttackTimer.start()
	
	if lunge_moves.has(move_name):
		lunging = true
		lunge_direction = lunge_moves[move_name]

	if not is_defensive:
		play_animation.rpc(anim_for_move(move_name))


func anim_for_move(move_name: String) -> String:
	match move_name:
		"Forward Overhead", "South Slash", "Forward Lunge Left", "Forward Lunge Right":
			return "Stab"
	return "Slash"


@rpc("call_local")
func play_animation(anim_name: String) -> void:
	if $Attack.sprite_frames.has_animation(anim_name):
		$Attack.animation = anim_name
	anim_player.play(anim_name)


@rpc("call_local")
func lock_aim(angle: float) -> void:
	aim_locked = true
	locked_angle = angle
	locked_aim_dir = dir_from_vector(Vector2.from_angle(angle))
	$Attack.global_rotation = angle
	$HitBoxNode.global_rotation = angle
	$Shield.global_rotation = angle
	apply_facing(locked_aim_dir)


func _on_animation_finished(anim_name: StringName) -> void:
	if blocking:
		if anim_name == &"BlockStart" or anim_name == &"Blocking":
			play_animation.rpc("Blocking")
		return
	aim_locked = false


func body_animation() -> String:
	var facing := get_aim_direction()
	var walk_anim := facing + "animated"
	if velocity.length() > 1.0 and sprite.sprite_frames.has_animation(walk_anim):
		return walk_anim
	return facing


@rpc("call_local")
func apply_facing(anim_name: String) -> void:
	sprite.play(anim_name)


@rpc("any_peer", "call_local")
func shake_camera() -> void:
	var cam = get_viewport().get_camera_2d()
	if cam == null:
		return

	var strength := 3.0
	var duration := 0.2
	var steps := 8

	var tween = create_tween()
	for i in steps:
		var target = Vector2(randf_range(-strength, strength), randf_range(-strength, strength))
		tween.tween_property(cam, "offset", target, duration / steps)
	tween.tween_property(cam, "offset", Vector2.ZERO, 0.02)



@rpc("any_peer")
func recieve_damage() -> void:
	health -= 1
	flash_white.rpc()
	shake_camera.rpc()
	if health <= 0:
		health = 3
		position = Vector2.ZERO
	


@rpc("any_peer", "call_local")
func flash_white() -> void:
	sprite.modulate = Color(10, 10, 10)
	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color(1, 1, 1), 0.15)


func _on_attack_timer_timeout() -> void:
	attacking = false
	defending = false
	lunging = false
	hitbox.monitoring = false
	block_area.monitoring = false



func _on_dash_timer_timeout() -> void:
	SPEED = BASE_SPEED



func _on_timer_timeout() -> void:
	moves.clear()


func _on_hit_box_node_body_entered(body: Node2D) -> void:
	if body == self:
		return
	if not body.has_method("recieve_damage"):
		return
	if body.get_multiplayer_authority() == multiplayer.get_unique_id():
		return
	body.recieve_damage.rpc_id(body.get_multiplayer_authority())
