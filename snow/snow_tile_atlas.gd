extends StaticBody3D
##Small tile section. samples its snow from the SnowComputeShader singleton. 
class_name Snow_Tile
enum eventmodes {
	normal, ##Event does both a visual and logical deformation of the snow.
	visual, ##Event does a visual deformation of the snow.
	logic   ##Event does a logical deformation of snow.
}
static var instance_count : int = 0
const TILE_TEXTURE_RESOLUTION : int = 128
const ATLAS_TEXTURE_RESOLUTION : int = 2048
const CPU_HEIGHTMAP_RESOLUTION : int = 64
const CPU_HEIGHTMAP_RESOLUTION_REDUCED : int = 13
const CPU_HEIGHTMAP_SCALE : float = 0.5
var CPU_workerthread_task_id : int = -1
var CPU_grid_thread_mutex_instance_queue : Mutex = Mutex.new()
var CPU_grid_thread_mutex_instance:Mutex = Mutex.new()
static var CPU_grid_thread_queue : Array[Dictionary] = []
var thread_started : bool = false
static var thread_finished : bool = false

const SNOW_MAX_HEIGHT: float = 2.0
@onready var snow_mesh     : MeshInstance3D = $SnowMesh
@onready var snow_mesh_material : ShaderMaterial

var mesh_high : PlaneMesh = preload("res://snow/snow meshes/high-quality-plane.tres")
var mesh_med :  PlaneMesh = preload("res://snow/snow meshes/medium-quality-mesh.tres")
var mesh_low :PlaneMesh = preload("res://snow/snow meshes/low-quality-mesh.tres")
var mesh_lowst :  PlaneMesh = preload("res://snow/snow meshes/lowest-quality-mesh.tres")


#@onready var snow_curve : CurveTexture = preload("res://snow/snow-compresion-curve-tex.tres")
@onready var snow_tile : PackedScene = preload("res://snow/snow-texture-redux.tscn")
@export_category("Debug")
@export var debug_step := false
@export var debug_print := false
@export var debug_propagate_large_area := false


const TILE_SIZE : float = 6.0
var ticks := 0

#region GPU atlas local coordinates
var UV_position : Vector2
const UV_RATIO := 0.0625 # 128 / 2048, ALERT not done real time for floating point precision reasons 
const UV_REDUCTOR_RATIO := 0.5 / TILE_SIZE #infinite fraction, better done once.
##Multiply by this constant the radius of an event for a proper size.
const TO_ATLAS_UV_RADIUS_RATIO := UV_REDUCTOR_RATIO * UV_RATIO
#endregion

#region CPU side snow height map
@export_category("CPU")
var snow_map_CPU : PackedFloat32Array
var snow_map_CPU_reduced : PackedFloat32Array
@export var no_collision:bool = false
@export var use_thread : bool = true
var is_updating_collision := false
@export var collision_update_ratio : int = 4
var collisions_changed : bool = true
@onready var coliision := $HeightCollision
##set to true if something important must be updated.
var CPU_important_update : bool = false

static var _axis_indices: Array[Array] = [] # _axis_indices[dst_index] = Array[int] of src indices
# Precomputed weight entry for one output cell along one axis.
class AxisWeight:
	var index: int
	var weight: float
	func _init(i: int, w: float) -> void:
		index = i
		weight = w

var queued_events : Array[Dictionary] = []

#endregion
@export_category("transform")
@export var x_axis_shear : float = 0.0
@export var z_axis_shear : float = 0.0
##should the shear be compensated, that is, the tile is lifted an amount equal to the tile's size multiplied by the shear.
@export var vertical_shear_correction : bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	debug_propagate()
	instance_count += 1
	prepare_UV_local()
	prepare_material_UV()
	prepare_collisions()
	prepare_CPU_heightmaps()
	prepare_shear_transform()
	SnowSurfaceManager.register_tile(self)
	#checks
	if global_rotation != Vector3.ZERO:
		no_collision = true
	if !debug_step:
		set_process_unhandled_input(false)
	if no_collision:
		push_warning("COLLISIONS DISABLED")
	
	

func _physics_process(_delta: float) -> void:
	ticks += 1
	if (collisions_changed == true and queued_events.size() > 0 and !thread_started) or CPU_important_update:
		thread_started = true
		CPU_workerthread_task_id = WorkerThreadPool.add_task(CPU_workerthread_compute_pending_events.bind(self), false, "Threaded job for computing CPU shit")
		if CPU_important_update:
			CPU_important_update = false
	if ticks % collision_update_ratio == 0 and collisions_changed == true:
		print("tile ", self.name, " is updating collisions")
		#print("gonna update now")
		if !use_thread:
			CPU_heightmap_create_low_synchronous()
		CPU_collision_update()
		
	if ticks % 2 == 0:
		LOD_mesh_update()
	
## builds performance weights for the CPU heightmap dimensions, making it run faster. only needs to run once per game.
static func prepare_axis_indices(src_size: int, dst_size: int) -> void:
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

#func start_thread() -> void:
	#if thread_started:
		#return
	#CPU_grid_thread.start(_thread_process)
	#thread_started = true

##creates the shear.
func prepare_shear_transform() -> void:
	var shear_basis := Basis.IDENTITY
	shear_basis.x.y = x_axis_shear
	shear_basis.z.y = z_axis_shear
	if debug_print and (x_axis_shear or z_axis_shear):
		printt("sheared by ", x_axis_shear, z_axis_shear)
	snow_mesh.basis = shear_basis
	if vertical_shear_correction:
		global_position.y += TILE_SIZE * 0.5 * (x_axis_shear + z_axis_shear)

##prepares the index of the tile and its position within the snow atlas.
func prepare_UV_local() -> void:
	var index : Vector2i = Vector2i(int(global_position.x / 6 + 8), int(global_position.z / 6 + 8))
	UV_position = index * UV_RATIO
	if debug_print:
		print("position is ", UV_position)
		

##prepares all CPU high and low heightmaps with proper resolution.
func prepare_CPU_heightmaps() -> void:
	snow_map_CPU.resize(CPU_HEIGHTMAP_RESOLUTION * CPU_HEIGHTMAP_RESOLUTION)
	for x in snow_map_CPU.size():
		snow_map_CPU[x] = SNOW_MAX_HEIGHT / coliision.scale.x
	snow_map_CPU_reduced.resize(CPU_HEIGHTMAP_RESOLUTION_REDUCED*CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	prepare_axis_indices(CPU_HEIGHTMAP_RESOLUTION, CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	CPU_heightmap_create_low_synchronous()

##Makes unique UV for this tile's ID.
func prepare_material_UV() -> void:
	snow_mesh_material = snow_mesh.get_active_material(0)
	snow_mesh_material.set_shader_parameter("snow_tex", SnowComputeManager.displayed_atlas_texture_wrapper)
	snow_mesh_material.set_shader_parameter("max_height", SNOW_MAX_HEIGHT)
	snow_mesh.set_instance_shader_parameter("UV_local_coordinates", UV_position)

##Makes a unique heightmap for the tile
func prepare_collisions() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_depth = CPU_HEIGHTMAP_RESOLUTION_REDUCED
	shape.map_width = CPU_HEIGHTMAP_RESOLUTION_REDUCED
	coliision.shape = shape

var LOD: int = 0
func LOD_mesh_update() -> void:
	return
	#more than 20m away
	var distance: float = get_viewport().get_camera_3d().global_position.distance_squared_to(global_position)
	if distance > 10000 and LOD != 3:
		LOD = 3
		snow_mesh.mesh = mesh_lowst
		print("updated to LOD 3")
	elif distance > 2500 and LOD != 2:
		LOD = 2
		snow_mesh.mesh = mesh_low
		print("updated to LOD 2")
	elif distance > 400 and LOD != 1:
		LOD = 1
		snow_mesh.mesh = mesh_med
		print("updated to LOD 1")
	elif LOD != 0:
		LOD = 0
		snow_mesh.mesh = mesh_high
		print("updated to LOD 0")
	
##Simulates a circular snow event on the GPU.
func GPU_snow_compression_event(local_uv : Vector2, radius: float, depth: float = 1.0, use_accumulate : bool = false) -> Error:
	var atlas_uv : Vector2 = local_to_atlas_uv(local_uv)
	var atlas_radius : float = radius * TO_ATLAS_UV_RADIUS_RATIO
	#if debug_print:
		##print("requested a stamp to snow compute.")
	SnowComputeManager.request_stamp(atlas_uv, atlas_radius, depth, int(use_accumulate))
	
	return OK

##to be called by a worker thread.
static func CPU_workerthread_compute_pending_events(user : Snow_Tile) -> void:

	#if user.debug_print:
		#print("main thread id: ", OS.get_main_thread_id(), " | this thread id: ", OS.get_thread_caller_id())
	user.CPU_grid_thread_mutex_instance_queue.lock()
	var q : Array[Dictionary] = user.queued_events.duplicate()
	user.queued_events.clear()
	user.CPU_grid_thread_mutex_instance_queue.unlock()
	#do all the silly CPU effects
	for x in q:
		user.CPU_snow_compression_event(x[&"local_uv"] as Vector2, x[&"radius"] as float, x[&"depth"] as float)
	#then make everything shrink :3
	var final_reduced : PackedFloat32Array = Snow_Tile.downsample_max_pool(user.snow_map_CPU, CPU_HEIGHTMAP_RESOLUTION,CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	final_reduced = user.apply_shear_to_heightmap(final_reduced)
	#finally, mutex and assign.
	user.CPU_grid_thread_mutex_instance.lock()
	user.snow_map_CPU_reduced = final_reduced
	user.CPU_grid_thread_mutex_instance.unlock()
	user.thread_started = false
	user.collisions_changed = true
func CPU_stash_or_use_sce(local_uv : Vector2, radius: float, depth : float) -> void:
	if use_thread:
		CPU_grid_thread_mutex_instance_queue.lock()
		queued_events.append({
			&"local_uv" : local_uv,
			&"radius" : radius,
			&"depth" : depth
		})
		collisions_changed = true
		CPU_grid_thread_mutex_instance_queue.unlock()

	else:
		CPU_snow_compression_event(local_uv, radius, depth)
	
##Simulates a circular snow event on the CPU side. When threaded, no muttexes are used since no fucking else
## is going to write here.
func CPU_snow_compression_event(local_uv : Vector2, radius: float, depth : float) -> Error:
	if no_collision:
		return OK
	
	if !use_thread:
		collisions_changed = true
	
	
	
	var grid_res := CPU_HEIGHTMAP_RESOLUTION
	var falloff_radius : float = radius * UV_REDUCTOR_RATIO * 1.5
	
	var center_x : float = local_uv.x * (grid_res - 1)
	var center_y : float = local_uv.y * (grid_res - 1)
	var cell_radius : float = falloff_radius * (grid_res - 1)

	var min_x : int = max(0, int(floor(center_x - cell_radius)))
	var max_x : int = min(grid_res - 1, int(ceil(center_x + cell_radius)))
	var min_y : int = max(0, int(floor(center_y - cell_radius)))
	var max_y : int = min(grid_res - 1, int(ceil(center_y + cell_radius)))
	#reminder that 0.75 is the heightmap's scale. I'm too lazy to make a constant
	var full_height : float = SNOW_MAX_HEIGHT / CPU_HEIGHTMAP_SCALE

	for gy in range(min_y, max_y + 1):
		for gx in range(min_x, max_x + 1):
			var grid_uv : Vector2 = Vector2(float(gx), float(gy)) / float(grid_res - 1)
			var dist : float = grid_uv.distance_to(local_uv)
			if dist < falloff_radius:
				var influence : float = 1.0 - (dist / falloff_radius)
				var idx : int = gy * grid_res + gx
				# target_height: how tall the snow SHOULD be here given this stamp's depth,
				# not a delta to subtract from whatever's currently there.
				var target_height : float = clamp(full_height * (1.0 - depth * influence), 0.0, full_height)
				snow_map_CPU[idx] = min(snow_map_CPU[idx], target_height)


	return OK

##Generates a lower resolution heightmap for the collision system, synchronously.
##Meant to be called only from the non-threaded path. Threaded version will be
##a separate function once that system is rebuilt.
func CPU_heightmap_create_low_synchronous() -> void:
	if collisions_changed == false:
		return
	snow_map_CPU_reduced = downsample_max_pool(snow_map_CPU, CPU_HEIGHTMAP_RESOLUTION, CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	snow_map_CPU_reduced = apply_shear_to_heightmap(snow_map_CPU_reduced)

##Generates a lower resolution heightmap for the collision system.
func CPU_heightmap_create_low(user :Snow_Tile) -> void:
	if !use_thread:
		CPU_heightmap_create_low_synchronous()
		return
	var reduced : PackedFloat32Array = downsample_max_pool(user.snow_map_CPU, CPU_HEIGHTMAP_RESOLUTION, CPU_HEIGHTMAP_RESOLUTION_REDUCED)
	user.CPU_grid_thread_mutex_instance.lock()
	user.snow_map_CPU_reduced = reduced
	user.CPU_grid_thread_mutex_instance.unlock()
	user.CPU_collision_update()
##resets heightmaps to whatever. should be threaded if final.
func TMP_CPU_heightmap_reset(value : float) -> void:
	print("value is ", value)
	value = (SNOW_MAX_HEIGHT/ CPU_HEIGHTMAP_SCALE) * (1.0 - value) * 1
	print("calculated value is ", value)
	if thread_started:
		while WorkerThreadPool.is_task_completed(CPU_workerthread_task_id) == false:
			await get_tree().physics_frame
	collisions_changed = true
	print("resetting CPU array")
	snow_map_CPU.fill(value)
	snow_map_CPU_reduced.fill(value)
	#you need to do it right after.
	CPU_collision_update()
	
##Pushes the current low-res heightmap into the collision shape.
##Synchronous — assumes snow_map_CPU_reduced is already up to date
##(i.e. CPU_create_low_res_heightmap_synchronous already ran this update cycle).
func CPU_collision_update() -> void:
	if !collisions_changed:
		return
	var heightmap : HeightMapShape3D = coliision.shape
	if CPU_grid_thread_mutex_instance.try_lock() == false:
		return #jfc just cancel if it's busy lol unlucky
	heightmap.map_data = snow_map_CPU_reduced
	CPU_grid_thread_mutex_instance.unlock()
	if debug_print:
		print("updated collisions")
	collisions_changed = false

##Converts the world coordinates into UV's for the specified tile.
func world_to_tile_uv(world_position : Vector3) -> Vector2:
	var local_pos: Vector3 = to_local(world_position)
	var u : float = (local_pos.x / TILE_SIZE) + 0.5
	var v : float = (local_pos.z / TILE_SIZE) + 0.5
	
	return Vector2(u, v)

##returns the UV coordinates in the atlas's scope.
func local_to_atlas_uv(local_UV : Vector2) -> Vector2:
	return UV_position + (local_UV * UV_RATIO)

##Calculates the shear vertical offset of any given LOCAL point of the tile.
func apply_shear_to_heightmap(heightmap_reduced: PackedFloat32Array, shear_x: float = x_axis_shear, shear_z: float = z_axis_shear) -> PackedFloat32Array:
	#if debug_print:
		#print("applying shear")
	var grid_res : int = CPU_HEIGHTMAP_RESOLUTION_REDUCED
	var result : PackedFloat32Array = heightmap_reduced.duplicate()
	#the collision is scaled down by 0.75 for better density. sorry!
	var effective_tile_size : float = (TILE_SIZE) / CPU_HEIGHTMAP_SCALE

	for gz in range(grid_res):
		for gx in range(grid_res):
			# convert grid index to local tile-space position, centered on the tile
			var local_u : float = float(gx) / float(grid_res - 1) # 0 to 1
			var local_v : float = float(gz) / float(grid_res - 1) # 0 to 1
			var local_x : float = (local_u - 0.5) * effective_tile_size
			var local_z : float = (local_v - 0.5) * effective_tile_size

			var shear_offset : float = (shear_x * local_x) + (shear_z * local_z)

			var idx : int = gz * grid_res + gx
			result[idx] += shear_offset

	return result

##returns the height of a position on the tile adjusted according to shear.
func shear_height_offset(location : Vector3) -> float:
	return location.y + (x_axis_shear * location.x) + (z_axis_shear * location.z)

func on_player_step(world_position: Vector3, collision_height : float = -999.0, visualonly : bool = false) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	var depth := 0.4
	if collision_height != -999.0:
		var sheared_height : float = shear_height_offset(Vector3(world_position.x, global_position.y, world_position.z))
		#print("sheared height is ", sheared_height)
		depth = clamp((1.0 -((collision_height - sheared_height)) / SNOW_MAX_HEIGHT), 0.0, 1.0)
		#print("position of snow:",global_position.y)
		#printt("height of collider:",collision_height)
		
	GPU_snow_compression_event(local_uv, 0.15, depth) #adjusted with the new proper sizing.
	if !visualonly: CPU_stash_or_use_sce(local_uv, 0.15, depth)
	#print("depth is ", depth)
	return 

func on_player_move(world_position: Vector3, collision_height : float = -999, visualonly : bool = false) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	var depth := 0.4
	if collision_height != -999.0:
		var sheared_height : float = shear_height_offset(Vector3(world_position.x, global_position.y, world_position.z))
		depth = clamp((1.0 -((collision_height - sheared_height)) / SNOW_MAX_HEIGHT), 0.0, 0.5)

		
	GPU_snow_compression_event(local_uv, 1.5, depth)
	if !visualonly: CPU_stash_or_use_sce(local_uv, 1.5, depth * 1.1)
	#print("depth is ", depth)
	return 


##only visual so far. adds snow isntead of removing.
func on_accumulate_snow(world_position: Vector3, visualonly : bool = false) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	var depth := 0.005
	GPU_snow_compression_event(local_uv, 0.11, depth, SnowComputeManager.OP_ACCUMULATE)

##Call this when you have just an "event" which doesn't select depth. instead, depth is derived from how high the event took place at.
func on_compression_event_auto_depth(world_position : Vector3, collision_height : float, radius: float, mode : eventmodes= eventmodes.normal) -> void:
	var depth : float
	var sheared_height : float = shear_height_offset(Vector3(world_position.x, global_position.y, world_position.z))
	depth = clamp((1.0 -((collision_height - sheared_height)) / SNOW_MAX_HEIGHT), 0.0, 1.0)
	on_compression_event(world_position, depth, radius,mode)
	#CPU_stash_or_use_sce(local_uv, )
##Call this when you have an event, where depth is an exact value. a value of 1 means fully compressed snow.
func on_compression_event(world_position: Vector3 , depth: float, radius : float, mode : eventmodes = eventmodes.normal) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	if mode == eventmodes.visual or mode == eventmodes.normal:
		GPU_snow_compression_event(local_uv, radius, depth, false)
	if mode == eventmodes.logic or mode == eventmodes.normal:
		CPU_stash_or_use_sce(local_uv, radius, depth)
	CPU_important_update = true
	print("recorded a compression event.")
	




# Runtime downsample — picks max value per output cell, no per-call float math.
# src: PackedFloat32Array, flattened src_size x src_size grid, index = y * src_size + x
# use_min: set true if your depressions are stored as negative values and you want
#          the deepest point preserved instead of the highest peak
static func downsample_max_pool(src: PackedFloat32Array, src_size: int, dst_size: int, use_min: bool = false) -> PackedFloat32Array:
	
	#lprint("main thread id: ", OS.get_main_thread_id(), " | this thread id: ", OS.get_thread_caller_id())
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
			
		
	elif event.is_action_pressed("ui_left"):
		CPU_collision_update()

func _exit_tree() -> void:
	thread_finished = true
	SnowSurfaceManager.remove_tile(self)


##Creates a 96x96 meter region filled with snow. this is the current largest possible snow region available due to space constraints. 
##Any bigger will cause UV boundary issues and not retain information.
func debug_propagate() -> void:
	if debug_propagate_large_area:
		print("PROPAGATING INTO LARGE AREA")
		var amount := 16
		for x in range(amount):
			for y in range(amount):
				
				await get_tree().physics_frame
				
				var new_tile : Snow_Tile= snow_tile.instantiate()
				new_tile.debug_print = false
				new_tile.debug_propagate_large_area = false
				new_tile.global_position = Vector3.ZERO + Vector3(x - float(amount)/2, 0, y - float(amount)/2) * TILE_SIZE
				get_parent().add_child(new_tile)
				if new_tile.global_position == self.global_position:
					new_tile.queue_free()
