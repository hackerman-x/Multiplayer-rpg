extends CharacterBody2D

@onready var hitbox: Area2D = $HitBoxNode
@onready var block_area: Area2D = $Shield
@onready var anim_player: AnimationPlayer = $AnimationPlayer
@onready var sprite: AnimatedSprite2D = $SirCrumbsBottom  # adjust path/type to match your actual sprite node
@onready var camera: Camera2D = $Camera2D
@onready var healthbar: TextureProgressBar = $HUD/Health
@onready var manabar: TextureProgressBar = $HUD/Mana
@onready var combo_timer: Timer = $ComboTimer   # Thrust window, started when Slash finishes
@onready var hitnumber: Label = $HitNumber
@onready var vignette : ColorRect = $HUD/ColorRect
@onready var dead_screen: CanvasLayer = $DeadScreen
@onready var spectate_name: Label = $DeadScreen/Root/Box/Spectate/Target
@onready var respawn_label: Label = $DeadScreen/Root/Box/Countdown

const CAPE_SHADER := preload("res://Shaders/cape_color.gdshader")
const IMPACT_SHADER := preload("res://Shaders/impact_frame.gdshader")

var SPEED = 100.0
var DASH = 200.0
var BASE_SPEED = 100.0
var LUNGE_SPEED = 250.0
var BLOCK_SPEED_MULTIPLIER = 0.5

var OFFENSIVE_DURATION = 0.4   # lock time for lunge attacks
var NORMAL_DURATION = 0.001     # lock time for quick basic slashes
var HOLD_DURATION = 0.4        # how long you hold attack (Stab lunge) or smash (Smash) before it fires
var smash_charging := false
var smash_start_time := 0.0
var swish_charging := false
var swish_start_time := 0.0
var SWISH_MANA_COST = 50
var SWISH_DISTANCE = 120.0     # how far the Swish teleport carries you (pixels)
var SWISH_WINDUP = 0.5         # how long you stand still before teleporting (seconds)
var SWISH_HIT_RADIUS = 14.0    # players this close to the teleport's path get hit
var IMPACT_FRAME_TIME = 0.12   # how long the black-and-white impact frame shows (seconds)
var IMPACT_FRAME_ATTACKS = ["Swish", "Smash"]   # landing a hit with these shows the impact frame
var impact_frame: ColorRect    # full-screen overlay, only exists for our own player

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
	["Down-Defensive", "Forward Overhead"]: "Counter Attack",
	["Up-Defensive", "South Slash"]: "Counter Attack",
	["Left-Defensive", "Forward Lunge Right"]: "Counter Attack",
	["Right-Defensive", "Forward Lunge Left"]: "Counter Attack",
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

var MAX_HEALTH = 100
var health: float = MAX_HEALTH
var LOW_HEALTH = 20             # below this, the red vignette pulses
var HEALTH_REGEN_DELAY = 6.0   # seconds without taking damage before health starts refilling
var HEALTH_REGEN_RATE = 15.0     # health refilled per second after that
var last_damaged := -INF        # when we last took damage (seconds)
var vignette_tween: Tween
var dead := false
var spectate_index := 0
# The SpawnIn frames are 300px tall with the ball at the very bottom; this lifts them so the ball sits on the player
var SPAWN_VFX_OFFSET = Vector2(0, -135)

var MAX_MANA = 100
var mana: float = MAX_MANA
var DASH_MANA_COST = 10
var SMASH_MANA_COST = 30
var BLOCK_MANA_DISCOUNT = 5   # a blocked hit costs (its damage - this) mana
var MANA_REGEN_DELAY = 5.0    # seconds without spending mana before it starts refilling
var MANA_REGEN_RATE = 15.0    # mana refilled per second after that
var last_mana_spent := -INF   # when mana was last spent (seconds)

# How much health each attack takes from the player it hits
var DAMAGE = {
	"Slash": 10,
	"Thrust": 5,
	"Stab": 20,    # the lunge
	"Smash": 30,
	"Swish": 50,
}

# aim is frozen from the moment a move fires until its animation finishes
var aim_locked := false
var locked_angle := 0.0
var locked_aim_dir := ""
var hit = false

# shared cooldown for every attack and block (starts when the move's lock time ends)
var ATTACK_COOLDOWN = 0.1
var cooldown_end := 0.0
var HIT_EFFECT_RADIUS = 8.0   # how far from the victim's center the hit sparks appear
var BLOCK_ARC_DEGREES = 60.0  # hits within this many degrees either side of the shield's facing are blocked

# How hard each attack pushes the player it hits (starting push speed in pixels/second)
var KNOCKBACK = {
	"Slash": 150.0,
	"Thrust": 250.0,
	"Stab": 400.0,    # the lunge
	"Smash": 600.0,
	"Swish": 0.0,    # goes straight through, no push
}
var KNOCKBACK_FRICTION = 1200.0   # how quickly a push slows down; higher = shorter slide
var knockback_velocity := Vector2.ZERO
var current_attack := ""          # animation name of the attack we're doing right now
var hit_this_attack: Array[int] = []   # players already hit by the current attack (each can only be hit once)
var hitnumber_start: Vector2           # where the damage number sits before it floats up
var vfx_offset: Vector2                # where the crack VFX sits when aiming right (from the scene)
# Each sound's normal pitch (1.0 = as recorded; lower = slower and deeper). Sounds not listed use 1.0
var SFX_BASE_PITCH = {
	"Walking": 0.75,
}
var SFX_PITCH_OFFSET = 0.1   # every play adds a random offset between -this and +this to the base pitch


func _enter_tree() -> void:
	set_multiplayer_authority(str(name).to_int())



func is_local_player() -> bool:
	return not multiplayer.has_multiplayer_peer() or is_multiplayer_authority()



func _ready() -> void:
	healthbar.value = health
	manabar.value = mana
	hitnumber_start = hitnumber.position
	hitnumber.text = ""
	vfx_offset = $VFX.position
	# Cape colour picked from the peer id, so every screen gives this player the same colour
	var cape := ShaderMaterial.new()
	cape.shader = CAPE_SHADER
	cape.set_shader_parameter("cape_hue", fposmod(str(name).to_int() * 0.618034, 1.0))
	sprite.material = cape
	# Run _process after the AnimationPlayer (priority 0), so its fixed VFX position doesn't undo our rotation
	process_priority = 1
	Global.player = self
	$Shield.visible = false
	if str(name) == "1":
		$Label.text = "Host"
	else:
		$Label.text = "Player " + str(name)

	hitbox.monitoring = false
	block_area.monitoring = false
	anim_player.animation_finished.connect(_on_animation_finished)
	# Every player has a HUD in the same screen corner; only show our own, or theirs covers ours
	$HUD.visible = is_local_player()
	dead_screen.visible = false
	$DeadTime.timeout.connect(respawn)
	$DeadScreen/Root/Box/Spectate/Prev.pressed.connect(spectate.bind(-1))
	$DeadScreen/Root/Box/Spectate/Next.pressed.connect(spectate.bind(1))

	if not is_local_player(): return
	camera.make_current()

	# Impact-frame overlay, above everything else on screen
	var impact_layer := CanvasLayer.new()
	impact_layer.layer = 10
	impact_frame = ColorRect.new()
	impact_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	impact_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	impact_frame.material = ShaderMaterial.new()
	impact_frame.material.shader = IMPACT_SHADER
	impact_frame.visible = false
	impact_layer.add_child(impact_frame)
	add_child(impact_layer)




func _process(_delta: float) -> void:
	# The slash is turned 180° when facing left; flipping it vertically too keeps it the right way up
	$Attack.flip_v = cos($Attack.rotation) < -0.01
	$Shield/Sprite2D.flip_v = cos($Shield.rotation) < -0.01

	if dead and is_local_player():
		respawn_label.text = "Respawning in %d" % ceili($DeadTime.time_left)
		# The player we were watching left or died: move on to someone else
		if camera.target != self and (not is_instance_valid(camera.target) or camera.target.dead):
			spectate(0)

	# Point the crack the same way as the sword, on every player's screen
	if $VFX.visible and $VFX.animation == &"Crack":
		var angle: float = $Attack.rotation
		# Facing left: mirror the crack instead of turning it 180°, so it isn't upside down
		var facing_left := cos(angle) < -0.01
		$VFX.flip_h = facing_left
		$VFX.rotation = angle - PI if facing_left else angle
		$VFX.position = vfx_offset.rotated(angle)


func _unhandled_input(_event: InputEvent) -> void:
	if not is_local_player(): return



func _physics_process(delta: float) -> void:
	if not is_local_player(): return
	if dead: return
	var direction := Input.get_vector("left", "right", "up", "down")

	if lunging:
		velocity = lunge_direction * LUNGE_SPEED
	elif blocking:
		velocity = direction * SPEED * BLOCK_SPEED_MULTIPLIER
	elif attacking:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.y = move_toward(velocity.y, 0, SPEED)
	elif direction:
		velocity = direction * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.y = move_toward(velocity.y, 0, SPEED)

	# Being knocked back overrides your own movement until the push dies down
	if knockback_velocity != Vector2.ZERO:
		velocity = knockback_velocity
		knockback_velocity = knockback_velocity.move_toward(Vector2.ZERO, KNOCKBACK_FRICTION * delta)

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

	# Refill mana once none has been spent for a while
	if mana < MAX_MANA and Time.get_ticks_msec() / 1000.0 - last_mana_spent >= MANA_REGEN_DELAY:
		mana = minf(mana + MANA_REGEN_RATE * delta, MAX_MANA)
		manabar.value = mana

	# Refill health once we haven't been hurt for a while
	if health < MAX_HEALTH and Time.get_ticks_msec() / 1000.0 - last_damaged >= HEALTH_REGEN_DELAY:
		health = minf(health + HEALTH_REGEN_RATE * delta, MAX_HEALTH)
		healthbar.value = health
		update_low_health_effect()

	if Input.is_action_just_pressed("Dash") and spend_mana(DASH_MANA_COST):
		$DashTimer.start()
		SPEED = DASH
		$Dash.emitting = true
	
	if not blocking:
		handle_attack_input()

	if Input.is_action_just_pressed("block"):
		handle_block()
	elif blocking and not Input.is_action_pressed("block"):
		stop_block()



func handle_attack_input() -> void:
	var aim_dir = get_aim_direction()
	var now := Time.get_ticks_msec() / 1000.0

	if Input.is_action_just_pressed("smash"):
		smash_charging = true
		smash_start_time = now
	if smash_charging and Input.is_action_pressed("smash") and now - smash_start_time >= HOLD_DURATION:
		smash_charging = false
		# Only pay (and smash) if we're allowed to act and have the mana
		if can_act() and spend_mana(SMASH_MANA_COST):
			# stay rooted for the whole Smash animation
			register_move("Smash", false, anim_player.get_animation("Smash").length)
	if Input.is_action_just_released("smash"):
		smash_charging = false

	# Swish: hold R, then dash straight through whoever is in the way
	if Input.is_action_just_pressed("Swish"):
		swish_charging = true
		swish_start_time = now
	if swish_charging and Input.is_action_pressed("Swish") and now - swish_start_time >= HOLD_DURATION:
		swish_charging = false
		if can_act() and spend_mana(SWISH_MANA_COST):
			register_move("Swish", false, anim_player.get_animation("Swish").length)
	if Input.is_action_just_released("Swish"):
		swish_charging = false

	if Input.is_action_just_pressed("attack"):
		if combo_timer.time_left > 0:
			combo_timer.stop()
			charging = false
			register_move("Thrust", false, NORMAL_DURATION, true)
			return
		charging = true
		lunge_triggered = false
		charge_direction = aim_dir
		charge_start_time = now

	if charging and Input.is_action_pressed("attack"):
		var held_time = now - charge_start_time

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
		register_move(move_map[key], false, NORMAL_DURATION)



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
	$SFX/Shield.play()


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



func register_move(move_name: String, is_defensive: bool, duration: float, ignore_cooldown := false) -> void:
	if not ignore_cooldown and not can_act(): return
	# Attacks can't be interrupted: you're locked out until the animation has finished
	var lock_time := duration
	var anim := anim_for_move(move_name)
	if anim_player.has_animation(anim):
		lock_time = maxf(duration, anim_player.get_animation(anim).length)
	cooldown_end = Time.get_ticks_msec() / 1000.0 + lock_time + ATTACK_COOLDOWN
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
	elif move_name == "Smash" or move_name == "Swish":
		# Snap to the nearest of up/down/left/right, like the lunge
		angle = snappedf(angle, PI / 2)
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
	elif move_name == "Swish":
		lunge_direction = Vector2.from_angle(angle)
		start_swish_dash()

	if not is_defensive:
		current_attack = anim_for_move(move_name)
		hit_this_attack.clear()
		play_animation.rpc(current_attack)


# Stand still for the wind-up, then dash (the AttackTimer ends the dash)
func start_swish_dash() -> void:
	await get_tree().create_timer(SWISH_WINDUP).timeout
	if not attacking or current_attack != "Swish" or dead:
		return
	# Teleport: stops early at walls; players aren't in our collision mask, so we go straight through them
	var start := global_position
	move_and_collide(lunge_direction * SWISH_DISTANCE)
	var end := global_position
	play_sfx_for_all.rpc("Swish")
	# Far too fast for the hitbox to notice, so check everyone standing along the path directly
	for p in get_parent().get_children():
		if p != self and p.scene_file_path == scene_file_path and not p.dead:
			var closest := Geometry2D.get_closest_point_to_segment(p.global_position, start, end)
			if closest.distance_to(p.global_position) <= SWISH_HIT_RADIUS:
				hit_player(p)


func anim_for_move(move_name: String) -> String:
	match move_name:
		"Forward Overhead", "South Slash", "Forward Lunge Left", "Forward Lunge Right":
			return "Stab"
		"Smash", "Thrust", "Swish":
			return move_name
	return "Slash"


@rpc("call_local")
func play_animation(anim_name: String) -> void:
	if $Attack.sprite_frames.has_animation(anim_name):
		$Attack.animation = anim_name
	anim_player.play(anim_name)
	match anim_name:
		"Slash":
			play_sfx("Sword")
		"Smash":
			play_sfx("Smash")


@rpc("call_local")
func play_sfx_for_all(sound: String) -> void:
	play_sfx(sound)


# Black-and-white flash over the whole screen; called on our own player, and sent to the victim's game
@rpc("any_peer")
func show_impact_frame() -> void:
	if impact_frame == null:
		return
	impact_frame.visible = true
	await get_tree().create_timer(IMPACT_FRAME_TIME).timeout
	impact_frame.visible = false


# Plays one of the sounds under the SFX node; skipped if that sound node doesn't exist
func play_sfx(sound: String) -> void:
	var player := get_node_or_null("SFX/" + sound) as AudioStreamPlayer2D
	if player:
		play_with_random_pitch(player)


#different pitch every time, so repeated sounds don't feel robotic
func play_with_random_pitch(player: AudioStreamPlayer2D) -> void:
	var base: float = SFX_BASE_PITCH.get(str(player.name), 1.0)
	player.pitch_scale = base + randf_range(-SFX_PITCH_OFFSET, SFX_PITCH_OFFSET)
	player.play()


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
	if anim_name == &"Slash" and is_local_player():
		combo_timer.start()
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
	# The walk animations all end in "animated", so footsteps follow them
	var steps := get_node_or_null("SFX/Walking") as AudioStreamPlayer2D
	if steps:
		var walking := anim_name.ends_with("animated")
		if walking and not steps.playing:
			play_with_random_pitch(steps)
		elif not walking and steps.playing:
			steps.stop()


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
func recieve_damage(hit_pos: Vector2, knockback: Vector2, damage: int) -> void:
	if dead:
		return
	# Never accept more than the strongest attack does, in case a modified game sends a huge number
	damage = clampi(damage, 0, DAMAGE.values().max())
	# With no mana left the shield can't stop anything, so the hit goes through
	if mana > 0 and is_hit_blocked(hit_pos):
		block_effect.rpc(hit_pos)
		set_mana(mana - maxi(damage - BLOCK_MANA_DISCOUNT, 0))
		return
	knockback_velocity = knockback
	health -= damage
	last_damaged = Time.get_ticks_msec() / 1000.0
	var tween = create_tween()
	tween.tween_property(healthbar, "value", health, 0.3)
	flash_white.rpc(hit_pos)
	show_hit_number.rpc(damage)
	shake_camera.rpc()
	
	if health <= 0:
		die()
	update_low_health_effect()


# ---------------- Death, spectating and respawning (runs in the dead player's own game) ----------------

func die() -> void:
	health = 0
	knockback_velocity = Vector2.ZERO
	velocity = Vector2.ZERO
	charging = false
	smash_charging = false
	swish_charging = false
	if blocking:
		stop_block()
	set_dead_state.rpc(true, global_position)
	$DeadTime.start()
	dead_screen.visible = true
	spectate(0)


func respawn() -> void:
	var spawn_points: Array = get_parent().get_node("SpawnPoints").get_children()
	var spawn_pos: Vector2 = spawn_points.pick_random().global_position
	health = MAX_HEALTH
	healthbar.value = health
	set_mana(MAX_MANA)
	dead_screen.visible = false
	camera.target = self
	set_dead_state.rpc(false, spawn_pos)
	update_low_health_effect()


# Hides/shows this player for everyone; on respawn also moves them and plays the SpawnIn effect
@rpc("call_local")
func set_dead_state(is_dead: bool, pos: Vector2) -> void:
	dead = is_dead
	visible = not is_dead
	global_position = pos
	$CollisionShape2D.set_deferred("disabled", is_dead)
	if not is_dead:
		play_spawn_vfx()


func play_spawn_vfx() -> void:
	var frames: SpriteFrames = $VFX.sprite_frames
	$VFX.animation = &"SpawnIn"
	$VFX.position = SPAWN_VFX_OFFSET
	$VFX.rotation = 0
	$VFX.flip_h = false
	$VFX.visible = true
	$SFX/Spawn.play()
	$VFX.play()
	await get_tree().create_timer(frames.get_frame_count(&"SpawnIn") / frames.get_animation_speed(&"SpawnIn")).timeout
	$VFX.visible = false
	$VFX.animation = &"Crack"
	$VFX.position = vfx_offset


# Points our camera at the next/previous living player (step -1 or 1; 0 = stay on/refresh the current one)
func spectate(step: int) -> void:
	var others: Array = []
	for p in get_parent().get_children():
		if p != self and p.scene_file_path == scene_file_path and not p.dead:
			others.append(p)
	if others.is_empty():
		camera.target = self
		spectate_name.text = "No one to spectate"
		return
	spectate_index = posmod(spectate_index + step, others.size())
	camera.target = others[spectate_index]
	spectate_name.text = others[spectate_index].get_node("Label").text


# Pulses the red vignette while health is low. Only starts/stops it when crossing the line, never every frame
func update_low_health_effect() -> void:
	var low: bool = health < LOW_HEALTH and not dead
	if low == vignette.visible:
		return
	vignette.visible = low
	if vignette_tween:
		vignette_tween.kill()
	if low:
		vignette_tween = create_tween().set_loops()
		vignette_tween.tween_property(vignette.material, "shader_parameter/vignette_radius", 1.6, 1)
		vignette_tween.tween_property(vignette.material, "shader_parameter/vignette_radius", 2.0, 1)
	else:
		vignette.material.set_shader_parameter("vignette_radius", 2.0)

	


func set_mana(value: float) -> void:
	if value < mana:
		last_mana_spent = Time.get_ticks_msec() / 1000.0
	mana = clampf(value, 0, MAX_MANA)
	create_tween().tween_property(manabar, "value", mana, 0.3)


# Pays the cost and returns true, or returns false (and pays nothing) if there isn't enough mana
func spend_mana(cost: int) -> bool:
	if mana < cost:
		return false
	set_mana(mana - cost)
	return true


func is_hit_blocked(hit_pos: Vector2) -> bool:
	if not blocking:
		return false
	var shield_dir := Vector2.from_angle($Shield.global_rotation)
	var hit_dir := hit_pos - global_position
	return absf(shield_dir.angle_to(hit_dir)) <= deg_to_rad(BLOCK_ARC_DEGREES)


@rpc("any_peer", "call_local")
func block_effect(hit_pos: Vector2) -> void:
	$Collide.global_position = hit_pos
	var bounce_dir := hit_pos - global_position
	if not bounce_dir.is_zero_approx():
		$Collide.direction = bounce_dir.normalized()
	$Collide.restart()
	var shield_sprite: Sprite2D = $Shield/Sprite2D
	shield_sprite.modulate = Color(3, 3, 3)
	create_tween().tween_property(shield_sprite, "modulate", Color(1, 1, 1), 0.15)


@rpc("any_peer", "call_local")
func show_hit_number(damage: int) -> void:
	hitnumber.scale = Vector2(1.0, 1.0)   # start big so it "pops", then shrinks back to normal
	var tween := create_tween().set_parallel(true)
	tween.tween_property(hitnumber, "scale", Vector2(0.6, 0.6), 0.5)
	hitnumber.text = str(-damage)
	hitnumber.pivot_offset = hitnumber.size / 2   # tilt around the middle, not the top-left corner
	hitnumber.rotation_degrees = randf_range(-10, 10)
	hitnumber.position = hitnumber_start
	hitnumber.modulate.a = 1.0
	var target := hitnumber_start + Vector2(randf_range(-5, 5), -15)   # up and a little sideways
	tween.tween_property(hitnumber, "position", target, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(hitnumber, "modulate:a", 0.0, 0.5).set_delay(0.2)


@rpc("any_peer", "call_local")
func flash_white(hit_pos: Vector2) -> void:
	$Collide.global_position = hit_pos
	var blow_dir := global_position - hit_pos
	if not blow_dir.is_zero_approx():
		$Collide.direction = blow_dir.normalized()
	$Collide.restart()
	play_sfx("Hurt")
	sprite.modulate = Color(10, 10, 10)
	var tween = create_tween()
	tween.tween_property(sprite, "modulate", Color(1, 1, 1), 0.15)
	tween.tween_property(sprite, "scale", Vector2(1.4, 1.4), 0.06)
	#await get_tree().create_timer(0.1).timeout
	tween.tween_property(sprite, "scale", Vector2(1, 1), 0.06)
	
	
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
	if not is_multiplayer_authority():
		return
	if body == self:
		return
	if not body.has_method("recieve_damage"):
		return
	hit_player(body)


# Damages another player with our current attack (used by the hitbox and by the Swish teleport)
func hit_player(body: Node2D) -> void:
	if body.get_multiplayer_authority() == multiplayer.get_unique_id():
		return
	if body.dead:
		return
	# Getting pushed out and back into the hitbox during the same attack doesn't count again
	if body.get_instance_id() in hit_this_attack:
		return
	hit_this_attack.append(body.get_instance_id())
	# The spot on the victim's edge facing our sword's hitbox
	var to_sword: Vector2 = $HitBoxNode/HitBox.global_position - body.global_position
	var hit_pos: Vector2 = body.global_position + to_sword.limit_length(HIT_EFFECT_RADIUS)
	# Push them straight away from us, as hard as the current attack hits
	var push_dir := (body.global_position - global_position).normalized()
	var knockback: Vector2 = push_dir * KNOCKBACK.get(current_attack, 0.0)
	var damage: int = DAMAGE.get(current_attack, 0)
	body.recieve_damage.rpc_id(body.get_multiplayer_authority(), hit_pos, knockback, damage)
	if current_attack in IMPACT_FRAME_ATTACKS:
		show_impact_frame()
		body.show_impact_frame.rpc_id(body.get_multiplayer_authority())


func _on_hittimer_timeout() -> void:
	var tween = create_tween()
	tween.tween_property(hitnumber, "visible", false, 0.5)
	tween.tween_property(hitnumber, "scale", 0.3, 0.5)
	hitnumber.text = ""
	hitnumber.rotation = 0
