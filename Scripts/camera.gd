extends Camera2D

## The node this camera follows
@export var target: Node2D = null
## How quickly the camera catches up to the target
@export var speed: float = 5.0
## Keep the camera from moving on the X axis
@export var lock_x: bool = false
## Keep the camera from moving on the Y axis
@export var lock_y: bool = false

func _process(delta: float) -> void:
	if target == null:
		return

	var new_position: Vector2 = target.global_position
	if lock_x:
		new_position.x = global_position.x
	if lock_y:
		new_position.y = global_position.y

	global_position = lerp(global_position, new_position, speed * delta)
