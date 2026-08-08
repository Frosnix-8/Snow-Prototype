extends Node3D
class_name Snow_Tile
const TEXTURE_RESOLUTION : int = 128
const CPU_HEIGHTMAP_RESOLUTION : int = 64
const CPU_HEIGHTMAP_RESOLUTION_REDUCED : int = 9
static var CPU_grid_thread : Thread = Thread.new()
static var CPU_grid_thread_semaphore : Semaphore = Semaphore.new()
static var CPU_grid_thread_mutex : Mutex = Mutex.new()
var CPU_grid_thread_mutex_instance:Mutex = Mutex.new()
static var CPU_grid_thread_queue : Array[Dictionary] = []
static var thread_started : bool = false
signal thread_job_finished
static var thread_finished : bool = false

@onready var snow_viewport_1 : SubViewport    = $SnowViewPort
@onready var snow_viewport_2 : SubViewport  = $SnowViewPortBackBuffer

@onready var snow_tex_1    : TextureRect    =  $SnowViewPort/snowbase
@onready var snow_tex_2    : TextureRect    = $SnowViewPortBackBuffer/snowbase

var active_viewport   :SubViewport
var inactive_viewport :SubViewport
var active_tex  : TextureRect
var inactive_tex: TextureRect

@export var snow_max_height: float = 2.0
@onready var snow_mesh     : MeshInstance3D = $SnowMesh
@onready var snow_mesh_material : ShaderMaterial
@onready var idle_timer    : Timer			= $Timer
@onready var snow_stamp_prototype : PackedScene = preload("res://snow/snow_stamp.tscn")
#@onready var snow_curve : CurveTexture = preload("res://snow/snow-compresion-curve-tex.tres")
@onready var snow_tile : PackedScene = preload("res://snow/snow prototype.tscn")
var stamp_count := 0
var stamps : Array[TextureRect]
var pending_stamps : Array[Dictionary] = []

@export var debug_step := false
@export var debug_print := false
@export var debug_propagate_large_area := false
@export var bake_max_stamps : int = 150
@export var bake_idle_time : float = 5.0
var is_baking := false


const TILE_SIZE : float = 6.0
var ticks := 0


#region CPU side snow height map
var snow_map_CPU : PackedFloat32Array
var snow_map_CPU_reduced : PackedFloat32Array
@export var no_collision:bool = false
@export var use_thread : bool = true
var is_updating_collision := false
@export var collision_update_ratio : int = 4
var collisions_changed : bool = false


@onready var coliision := $SnowCollision/CollisionShape3D
#endregion

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if global_rotation != Vector3.ZERO:
		$SnowCollision.queue_free()
	if debug_propagate_large_area:
		print("PROPAGATING INTO LARGE AREA")
		
		for x in range(10):
			for y in range(10):
				
				await get_tree().physics_frame
				var new_tile : Snow_Tile= snow_tile.instantiate()
				new_tile.debug_propagate_large_area = false
				get_parent().add_child(new_tile)
				new_tile.global_position = global_position + Vector3(x - 5, 0, y - 5) * TILE_SIZE
				if new_tile.global_position == self.global_position:
					new_tile.queue_free()
	snow_map_CPU.resize(CPU_HEIGHTMAP_RESOLUTION * CPU_HEIGHTMAP_RESOLUTION)
	for x in snow_map_CPU.size():
		snow_map_CPU[x] = snow_max_height / coliision.scale.x
	snow_map_CPU_reduced.resize(CPU_HEIGHTMAP_RESOLUTION_REDUCED*CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	main_viewport_select()
	snow_tex_1.size = Vector2(TEXTURE_RESOLUTION,TEXTURE_RESOLUTION)
	snow_tex_1.position = Vector2.ZERO
	snow_tex_2.size = Vector2(TEXTURE_RESOLUTION,TEXTURE_RESOLUTION)
	snow_tex_2.position = Vector2.ZERO
	idle_timer.wait_time = bake_idle_time
	
	snow_mesh_material = snow_mesh.get_active_material(0)#.duplicate()
	#snow_mesh.set_surface_override_material(0, snow_mesh_material)
	#snow_mesh.set_instance_shader_parameter("snow_curve", snow_curve)
	snow_mesh_material.set_shader_parameter("snow_tex", snow_viewport_1.get_texture())
	snow_mesh_material.set_shader_parameter("max_height", snow_max_height)
	_build_axis_indices(CPU_HEIGHTMAP_RESOLUTION, CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	CPU_create_low_res_heightmap()
	start_thread()
	if !debug_step:
		set_process_unhandled_input(false)
	if !debug_print:
		set_physics_process(false)
	if no_collision:
		coliision.queue_free()
func start_thread() -> void:
	if thread_started:
		return
	CPU_grid_thread.start(_thread_process)
	thread_started = true
##Process used by the grid thread.
static func _thread_process() -> void:
	while !thread_finished:
		print("thread is awaiting a new semaphore post")
		CPU_grid_thread_semaphore.wait()
		CPU_grid_thread_mutex.lock()
		if !CPU_grid_thread_queue.front() or thread_finished:
			CPU_grid_thread_mutex.unlock()
			continue
		var current_job : Dictionary = CPU_grid_thread_queue.front()
		CPU_grid_thread_queue.pop_front()
		CPU_grid_thread_mutex.unlock()
			
		
		var job_owner : Snow_Tile = current_job[&"job_owner"]
		job_owner.CPU_grid_thread_mutex_instance.lock()
		prints.call_deferred("thread has received a job from", job_owner)
		var source_array : PackedFloat32Array = current_job[&"snow_map_CPU"]
		var final_array : PackedFloat32Array = current_job[&"snow_map_CPU_reduced"]
		
		
		
		final_array = downsample_max_pool(source_array, CPU_HEIGHTMAP_RESOLUTION, CPU_HEIGHTMAP_RESOLUTION_REDUCED) 
		job_owner.set_thread_safe(&"snow_map_CPU_reduced",final_array)
		
		print("thread has completed job.")
		
		job_owner.CPU_grid_thread_mutex_instance.unlock()
		job_owner.call_deferred_thread_group(&"emit_signal", &"thread_job_finished")
	
	print("thread is finished.")

func _thread_finished() -> void:
	thread_job_finished.emit()
	
func _physics_process(_delta: float) -> void:
	ticks += 1
	if ticks % collision_update_ratio == 0:
		update_collision()
	#if ticks % 120 == 0:
		#printt("active viewport is ", active_viewport.name, active_tex.name)
		#printt("inactive viewport is ", inactive_viewport.name, inactive_tex.name)

func snow_compression_event(local_uv : Vector2, radius: float, depth: float = 1.0) -> Error:
	if is_baking:
		pending_stamps.append({
			"local_uv" : local_uv,
			"radius" : radius,
			"depth" : depth})
		if debug_print:
			print("deferring snow compression to after bake is complete.")
		return OK
		
	var stamp : TextureRect = snow_stamp_prototype.instantiate()
	
	stamp_count += 1
	stamps.append(stamp)
	active_viewport.add_child(stamp)
	if debug_print:
		print("wrote to active viewport ", active_viewport)
	
	var px_pos : Vector2 = local_uv * Vector2(active_viewport.size)
	stamp.position = px_pos - stamp.size * 0.5
	
	var mat : ShaderMaterial = stamp.material
	mat.set_shader_parameter("stamp_radius", radius)

	stamp.set_instance_shader_parameter("stamp_depth", depth)
	check_event_count()
	idle_timer.start()
	update_viewport()
	return OK

# Only iterate the grid cells that could plausibly fall inside falloff_radius,
# instead of scanning the full 64x64 grid every footstep.
func CPU_snow_compression_event(local_uv : Vector2, radius: float, depth : float) -> Error:
	if no_collision:
		return OK
	var grid_res := CPU_HEIGHTMAP_RESOLUTION
	var falloff_radius : float = radius * 0.3
	collisions_changed = true
	# convert the UV-space radius into grid-cell-space radius, then get a
	# bounding box around the footstep center in grid coordinates
	var center_x : float = local_uv.x * (grid_res - 1)
	var center_y : float = local_uv.y * (grid_res - 1)
	var cell_radius : float = falloff_radius * (grid_res - 1)

	var min_x : int = max(0, int(floor(center_x - cell_radius)))
	var max_x : int = min(grid_res - 1, int(ceil(center_x + cell_radius)))
	var min_y : int = max(0, int(floor(center_y - cell_radius)))
	var max_y : int = min(grid_res - 1, int(ceil(center_y + cell_radius)))

	for gy in range(min_y, max_y + 1):
		for gx in range(min_x, max_x + 1):
			var grid_uv : Vector2 = Vector2(float(gx), float(gy)) / float(grid_res - 1)
			var dist : float = grid_uv.distance_to(local_uv)
			if dist < falloff_radius:
				var influence : float = 1.0 - (dist / falloff_radius)
				var idx : int = gy * grid_res + gx
				snow_map_CPU[idx] = clamp((snow_map_CPU[idx] - (depth * influence * 2)), 0.0, snow_max_height / coliision.scale.x)
	CPU_create_low_res_heightmap()
	return OK
	
##Generates a lower resolution heightmap for the collision system.
func CPU_create_low_res_heightmap() -> void:
	if !use_thread:
		snow_map_CPU_reduced = downsample_max_pool(snow_map_CPU, CPU_HEIGHTMAP_RESOLUTION, CPU_HEIGHTMAP_RESOLUTION_REDUCED)
		return
	
	while CPU_grid_thread_mutex.try_lock() == false:
		if debug_print:
			prints(self.name ,"is waiting for the work thread to finish.")
		await thread_job_finished
	CPU_grid_thread_queue.append({
		&"snow_map_CPU" : snow_map_CPU,
		&"snow_map_CPU_reduced" : snow_map_CPU_reduced,
		&"CPU_HEIGHTMAP_RESOLUTION" : CPU_HEIGHTMAP_RESOLUTION,
		&"CPU_HEIGHTMAP_RESOLUTION_REDUCED" : CPU_HEIGHTMAP_RESOLUTION_REDUCED,
		&"job_owner" : self
	})
	CPU_grid_thread_mutex.unlock()
	CPU_grid_thread_semaphore.post()
	if debug_print:
		prints("added a new threaded job from", self.name)


func update_collision() -> void:
	if is_updating_collision == true: return
	elif !collisions_changed: return
	is_updating_collision = true
	var heightmap :HeightMapShape3D= coliision.shape
	if CPU_grid_thread_mutex_instance.try_lock() == false:
		await thread_job_finished
	heightmap.map_data = snow_map_CPU_reduced 
	CPU_grid_thread_mutex_instance.unlock()
	if debug_print:
		print("updated collisions")
	is_updating_collision = false
	collisions_changed = false

	

##Initializes all the queued stamps during baking.
func flush_queued_compression_events() -> void:
	var events : Array[Dictionary] = pending_stamps.duplicate()
	pending_stamps.clear()
	for x : Dictionary in events:
		snow_compression_event(x["local_uv"], x["radius"], x["depth"])

##Switches the main viewport and texture. leave empty to return to base mode.
func main_viewport_select(use_secondary: bool = false) -> void:
	active_viewport = snow_viewport_1 if !use_secondary else snow_viewport_2
	inactive_viewport = snow_viewport_2 if !use_secondary else snow_viewport_1
	active_tex = snow_tex_1 if !use_secondary else snow_tex_2
	inactive_tex = snow_tex_2 if !use_secondary else snow_tex_1
	
func main_viewport_switch() -> void:
	var old_active : SubViewport = active_viewport
	active_viewport = inactive_viewport
	inactive_viewport = old_active
	var old_active_rect : TextureRect = active_tex
	active_tex = inactive_tex
	inactive_tex = old_active_rect

func update_viewport() -> void:
	active_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
##Checks if the stamps exceed the limit. if so, returns true and bakes.
func check_event_count() -> bool:
	if stamp_count > bake_max_stamps:
		bake_snow_compression()
		return true
	return false

##Does some GPU side compressing for perofrmance
func bake_snow_compression() -> void:
	is_baking = true
	if debug_print:
		print("initiating bake.")
	inactive_tex.texture = active_viewport.get_texture()
	inactive_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await RenderingServer.frame_post_draw
	
	for s : TextureRect in stamps:
		s.queue_free()
	stamps.clear()
	stamp_count = 0
	
	main_viewport_switch()
	
	snow_mesh_material.set_shader_parameter("snow_tex", active_viewport.get_texture())
	
	is_baking = false
	

##Takes final image created by stamps, and bakes into a single image for performance.
func bake_snow_compression_CPU(tile :Snow_Tile = self) -> void:
	await RenderingServer.frame_post_draw
	var new_snow_tex : Image = active_viewport.get_viewport().get_texture().get_image()
	var final_tex : Texture2D = ImageTexture.create_from_image(new_snow_tex)
	_apply_snow_compression_CPU(tile, final_tex)

func _apply_snow_compression_CPU(tile : Snow_Tile, image : Texture2D) -> void:
	tile.active_tex.texture = image
	print(tile.active_tex.texture)
	print("reset successfully, removing stamps")
	for x in stamps:
		x.queue_free()
	stamps.clear()
	stamp_count = 0
	update_viewport()
	printt("there are now ", stamp_count, "stamps")
	


func world_to_tile_uv(world_position : Vector3) -> Vector2:
	var local_pos: Vector3 = to_local(world_position)
	var u : float = (local_pos.x / TILE_SIZE) + 0.5
	var v : float = (local_pos.z / TILE_SIZE) + 0.5
	
	return Vector2(u, v)

func on_player_step(world_position: Vector3, collision_height : float = -999.0) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	var depth := 0.4
	if collision_height != -999.0:
		depth = clamp((1.0 -((collision_height - global_position.y)) / snow_max_height), 0.0, 1.0)
		print("position of snow:",global_position.y)
		printt("height of collider:",collision_height)
	snow_compression_event(local_uv, 0.6, depth)
	CPU_snow_compression_event(local_uv, 0.6, depth)
	print("depth is ", depth)
	return 

func setup_snow(_target_height : float = 1.2) -> void:
	pass

## not mines
# Precomputed weight entry for one output cell along one axis.
class AxisWeight:
	var index: int
	var weight: float
	func _init(i: int, w: float) -> void:
		index = i
		weight = w
static var _axis_indices: Array[Array] = [] # _axis_indices[dst_index] = Array[int] of src indices
# Call once at startup (or when src_size/dst_size change), not per-frame.
static func _build_axis_indices(src_size: int, dst_size: int) -> void:
	_axis_indices.clear()
	_axis_indices.resize(dst_size)
	var _scale: float = float(src_size) / float(dst_size)

	for dc in dst_size:
		var x0: int = int(floor(dc * _scale))
		var x1: int = int(ceil((dc + 1) * _scale))
		var indices: Array[int] = []
		for sx in range(x0, min(x1, src_size)):
			indices.append(sx)
		_axis_indices[dc] = indices

# Runtime downsample — picks max value per output cell, no per-call float math.
# src: PackedFloat32Array, flattened src_size x src_size grid, index = y * src_size + x
# use_min: set true if your depressions are stored as negative values and you want
#          the deepest point preserved instead of the highest peak
static func downsample_max_pool(src: PackedFloat32Array, src_size: int, dst_size: int, use_min: bool = false) -> PackedFloat32Array:
	# pass 1: rows
	var pass1: PackedFloat32Array = PackedFloat32Array()
	pass1.resize(src_size * dst_size)
	for r in src_size:
		var row_offset: int = r * src_size
		var dst_offset: int = r * dst_size
		for dc in dst_size:
			var best: float = INF if use_min else -INF
			for sx in _axis_indices[dc]:
				var v: float = src[row_offset + sx]
				if use_min:
					best = min(best, v)
				else:
					best = max(best, v)
			pass1[dst_offset + dc] = best

	# pass 2: columns
	var dst: PackedFloat32Array = PackedFloat32Array()
	dst.resize(dst_size * dst_size)
	for dr in dst_size:
		for dc in dst_size:
			var best: float = INF if use_min else -INF
			for sy in _axis_indices[dr]:
				var v: float = pass1[sy * dst_size + dc]
				if use_min:
					best = min(best, v)
				else:
					best = max(best, v)
			dst[dr * dst_size + dc] = best
	return dst

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):

		on_player_step(Vector3(randf_range(-3,3),0,randf_range(-3,3)))
			
		printt("there are", stamp_count, "stamps")
	elif event.is_action_pressed("ui_left"):
		update_collision()
		

#func queue_bake(tile: Snow_Tile) -> void:
	#WorkerThreadPool.add_task(bake_snow_compression_threaded.bind(Snow_Tile))


func _on_idle_time() -> void:
	bake_snow_compression()
	print("baking snow after idle limit")

func _exit_tree() -> void:
	CPU_grid_thread_semaphore.post()
	thread_finished = true
	CPU_grid_thread.wait_to_finish()
