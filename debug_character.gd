extends CharacterBody3D


const SPEED = 5.0
const JUMP_VELOCITY = 4.5
const HEIGHT : float = 2.0
@onready var snow_check_ray : RayCast3D = $RayCast3D
@onready var snow_check : Area3D = $Area3D
@export var no_gravity := false
var did_not_move := false
var ticks := 0
var ticks_since_moved := 0

func _ready() -> void:
	Input.mouse_mode =Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	ticks += 1
	ticks_since_moved += 1
	if current_tile and ticks % 3 == 0:
		#current_tile.on_player_step(snow_check.global_position)
		print("deforming snow")
	
	# Add the gravity.
	if not is_on_floor() and !no_gravity:
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector("l", "r", "f", "b")
	var direction :Vector3= (basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
		ticks_since_moved = 0
		
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	
	$RayCast3D.position = basis * direction  + Vector3(0.0,1.1,0.0)
	if ticks % 3 == 0 and ticks_since_moved < 10:
			if check_for_snow(direction):
				print("hit snow")

	move_and_slide()
	
	
var current_tile : Snow_Tile

func check_for_snow(direction : Vector3) -> bool:
	var collider :Node3D= snow_check_ray.get_collider()
	if !collider :
		return false
	var potential = collider.get_parent()
	if potential is Snow_Tile:
		print("potential is snow!")

		potential.on_player_step(global_position + direction * 0.5, ((global_position.y - (HEIGHT / 2.0))))
	return false

func _on_area_3d_body_entered(body: Node3D) -> void:
	var collider =body.get_parent()
	if collider is Snow_Tile:
		current_tile = collider

func _on_area_3d_body_exited(body: Node3D) -> void:
	var collider = body.get_parent()
	if collider == current_tile:
		current_tile = null

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		$Camera3D.rotation.x -= event.relative.y * 0.001
		rotation.y -= event.relative.x * 0.001
