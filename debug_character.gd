extends CharacterBody3D


const SPEED = 5.0
const JUMP_VELOCITY = 6.0
const HEIGHT : float = 2.0
const SNOWHIGH : float = 1.5
const SNOWMED : float = 0.9
const SNOWHIGHMULT : float = 0.2
const SNOWMEDMULT : float = 0.5
@onready var snow_check_ray : RayCast3D = $RayCast3D
@onready var snow_height_ray: RayCast3D = $SnowHeightCheck
@export var no_gravity := false
@export var have_accumulate_snow_for_some_reason_damn : bool = false
@export var debug_visual : Viewport.DebugDraw = Viewport.DEBUG_DRAW_DISABLED
var did_not_move := false
var ticks := 0
var ticks_since_moved := 0
var last_physics_frame := 0
var dir : Vector3 = Vector3.ZERO
func _ready() -> void:
	Input.mouse_mode =Input.MOUSE_MODE_CAPTURED
	
func _process(_delta: float) -> void:
	get_viewport().debug_draw = debug_visual
	#print("checking visual snow")
	if Engine.get_physics_frames() != last_physics_frame:
		print("skipped process frame due to physics frame")
		return
		
	if ticks_since_moved < 3: check_for_snow(dir, true)
	last_physics_frame = Engine.get_physics_frames()
func _physics_process(delta: float) -> void:
	last_physics_frame = Engine.get_physics_frames()
	ticks += 1
	ticks_since_moved += 1
	#if current_tile and ticks % 2 == 0:
		##current_tile.on_player_step(snow_check.global_position)
		#print("deforming snow")
	
	# Add the gravity.
	if not is_on_floor() and !no_gravity:
		velocity += get_gravity() * delta

	# Handle jump.
	if Input.is_action_just_pressed("ui_accept") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector("l", "r", "f", "b")
	var direction :Vector3= ($Pivot.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	var processed_speed : float = SPEED * check_snow_height(direction)
	if direction:
		velocity.x = direction.x * processed_speed
		velocity.z = direction.z * processed_speed
	
	
		
	else:
		velocity.x = move_toward(velocity.x, 0, processed_speed)
		velocity.z = move_toward(velocity.z, 0, processed_speed)
	dir = direction
	#$RayCast3D.position = basis.inverse() * direction  + Vector3(0.0,1.5,0.0)
	if ticks % 1 == 0 and ticks_since_moved < 3:
			if check_for_snow(direction):
				print("hit snow")

	move_and_slide()
	if velocity:
		ticks_since_moved = 0
	
var current_tile : Snow_Tile

func check_for_snow(direction : Vector3, visual : bool = false) -> bool:
	var collider :Node3D= snow_check_ray.get_collider()
	if !collider :
		return false
	var potential = collider
	if potential is Snow_Tile:
		#print("potential is snow!")
		var pos :Vector3= global_position + direction * 0.3
		var height: float = ((global_position.y - (1.0)))
		if !have_accumulate_snow_for_some_reason_damn:
			potential.on_player_move(pos, height , visual)
		else:
			potential.on_accumulate_event(pos, 1.5, 0.5, false, false)
		var speed : int = roundi(velocity.length())
		if ticks % (15 - speed) == 0 and velocity and !have_accumulate_snow_for_some_reason_damn:
			#print("STEP")
			var pair : float = int(ticks % (30 - speed * 2) == 0) * 2 - 1
			potential.on_player_step(pos + ($Pivot.basis * Vector3(0.3 * sign(pair), -1.0, 0.0)), height, false)
	return false

##runs by itself. Check height of snow.
func check_snow_height(direction : Vector3) -> float:
	if direction == Vector3.ZERO:
		return 1.0
	var dire :Vector3= direction * 0.5
	snow_height_ray.position = Vector3(dire.x,1.5, dire.z)
	var snow_position : Vector3 = snow_height_ray.get_collision_point()
	if !snow_height_ray.get_collider():
		return 1.0
	var height : float = to_local(snow_position).y + 1.0
	#print("height of snow is ", height)
	if height > SNOWHIGH:
		return SNOWHIGHMULT
	elif height > SNOWMED:
		return SNOWMEDMULT
	return 1.0
	
func boom() -> void:
	print("boom")
	var snow : Snow_Tile = snow_check_ray.get_collider()
	if !snow:
		return
	if !have_accumulate_snow_for_some_reason_damn:
		snow.on_explosion(global_position, 10.0, 0.9)
	else:
		snow.on_accumulative_exposion(global_position, 10.0, 0.9)

func BFG() -> void:
	print("BIG FUCKKING BOOM")
	var snow : Snow_Tile = snow_check_ray.get_collider()
	if !snow:
		return
	elif !have_accumulate_snow_for_some_reason_damn:
		snow.on_explosion(global_position, 10.0, 2.0)
	else:
		snow.on_accumulate_event(global_position, 10.0, 1.0)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		$Pivot/Camera3D.rotation.x -= event.relative.y * 0.001
		$Pivot.rotation.y -= event.relative.x * 0.001
	elif event is InputEventMouseButton:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event.is_action_pressed("ui_down"):
		var amount : float = 1.0 - float(int(have_accumulate_snow_for_some_reason_damn))
		SnowSurfaceManager.reset_all_snow(amount)
	elif event.is_action_pressed("ui_up"):
		have_accumulate_snow_for_some_reason_damn = !have_accumulate_snow_for_some_reason_damn
	
	elif event.is_action_pressed("ui_right"):
		boom()
	elif event.is_action_pressed("ui_end"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event.is_action_pressed("ui_left"):
		BFG()
