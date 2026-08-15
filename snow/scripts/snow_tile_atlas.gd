extends StaticBody3D
##Small tile section. samples its snow from the SnowComputeShader singleton. 
class_name Snow_Tile
enum eventmodes {
	normal, ##Event does both a visual and logical deformation of the snow.
	visual, ##Event does a visual deformation of the snow.
	logic   ##Event does a logical deformation of snow.
}
static var instance_count : int = 0
static var instances_updating_collisions_this_frame : int = 0
static var cached_camera : Camera3D
var cached_distance_to_cam : float
const MAX_COLLISION_UPDATES_PER_FRAME : int = 32
const TILE_TEXTURE_RESOLUTION : int = 128
const ATLAS_TEXTURE_RESOLUTION : int = 2048
const CPU_HEIGHTMAP_RESOLUTION : int = 32
const CPU_HEIGHTMAP_RESOLUTION_REDUCED : int = 13
const CPU_HEIGHTMAP_SCALE : float = 0.5

var CPU_grid_thread_mutex_instance_queue : Mutex = Mutex.new()
var CPU_grid_thread_mutex_instance:Mutex = Mutex.new()

const SNOW_MAX_HEIGHT: float = 2.0
@onready var snow_mesh     : MeshInstance3D = $SnowMesh
static var snow_mesh_material : ShaderMaterial = preload("res://snow/snow meshes/snow-shader-material.tres")

var mesh_high : PlaneMesh = preload("res://snow/snow meshes/high-quality-plane.tres")
var mesh_med :  PlaneMesh = preload("res://snow/snow meshes/medium-quality-mesh.tres")
var mesh_low :PlaneMesh = preload("res://snow/snow meshes/low-quality-mesh.tres")
var mesh_lowst :  PlaneMesh = preload("res://snow/snow meshes/lowest-quality-mesh.tres")
var mesh_lowsp : PlaneMesh = preload("res://snow/snow meshes/lowestest-quality-mesh.tres")
var mesh_lowmx : PlaneMesh = preload("res://snow/snow meshes/lowestestest-quality-mesh.tres")


#@onready var snow_curve : CurveTexture = preload("res://snow/snow-compresion-curve-tex.tres")
@onready var snow_tile : PackedScene = preload("res://snow/scenes/snow-texture-redux.tscn")
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

var snow_tile_neightbors : Array[Snow_Tile]
#endregion
#region blizzard
var pending_blizzard_accumulation : float = 0.0
var blizzard_time_offset : int = 0
var time_since_blizzard : int = 0
##ticks before the tile is forced to update its collisions due to blizzards.
const TIME_BEFORE_FORCE_BLIZZARD_UPDATE : int = 120
#endregion
#region LOD data
const LOD_1_DIST : float = 8.0 * 8.0
const LOD_2_DIST : float = 16.0 * 16.0
const LOD_3_DIST : float = 32.0 * 32.0
const LOD_4_DIST : float = 64.0 * 64.0
const LOD_5_DIST : float = 128.0 * 128.0
const LOD_6_DIST : float = 256.0 * 256.0
var resolution_factor : float = 1.0
const FHD_FACTOR : float = 1.0
const QHD_FACTOR : float = 1.0 + 1.0/3.0
const UHD_FACTOR : float = 2.0

#endregion

static var _axis_indices: Array[Array] = [] # _axis_indices[dst_index] = Array[int] of src indices

var pending_position : Vector3 = Vector3(0.0, -99999, 0.0)
var queued_events : Array[Dictionary] = []

#endregion
@export_category("transform")
@export var x_axis_shear : float = 0.0
@export var z_axis_shear : float = 0.0
##should the shear be compensated, that is, the tile is lifted an amount equal to the tile's size multiplied by the shear.
@export var vertical_shear_correction : bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if pending_position.y > -9999:
		global_position = pending_position
	prepare_collisions()
	prepare_CPU_heightmaps()
	instance_count += 1
	prepare_UV_local()
	prepare_material_UV()
	prepare_material_static()
	prepare_LOD_factor()
	SnowSurfaceManager.register_tile(self)

	#checks
	if global_rotation != Vector3.ZERO:
		no_collision = true
	if !debug_step:
		set_process_unhandled_input(false)
	if no_collision:
		push_warning("COLLISIONS DISABLED")
	
	coliision.disabled = false
	debug_propagate()
	prepare_shear_transform()
	

func prepare_LOD_factor() -> void:
	var resolution : Vector2i = DisplayServer.window_get_size(0)
	var render_scale : float = get_viewport().scaling_3d_scale
	match resolution.y * render_scale:
		1080 or 1200:
			resolution_factor = FHD_FACTOR
			return
		1440 or 1600:
			resolution_factor = QHD_FACTOR
			return
		2160 or 2400:
			resolution_factor = UHD_FACTOR
			return
		_:
			var proportion_factor: float = (resolution.y * render_scale) / 1080.0
			resolution_factor = proportion_factor
	

	
	
	#resolution_factor *= resolution_factor
		
			
func _physics_process(delta: float) -> void:
	ticks += 1
	if instances_updating_collisions_this_frame != 0:
		instances_updating_collisions_this_frame = 0
	var has_pending_work : bool = (collisions_changed == true and queued_events.size() > 0) or CPU_important_update 
	if has_pending_work:
		SnowSurfaceThreadManager.enqueue_tile(self)
		CPU_important_update = false

	if ticks % collision_update_ratio == 0 and collisions_changed == true:
		if !use_thread:
			CPU_heightmap_create_low_synchronous()
		var tries : int = 0
		while instances_updating_collisions_this_frame >= MAX_COLLISION_UPDATES_PER_FRAME and tries < 9:
			print("deferring collisions update")
			await get_tree().physics_frame
		
		CPU_collision_update.call_deferred()
	
	if SnowSurfaceManager.blizzard_active:
		var full_height : float = SNOW_MAX_HEIGHT / CPU_HEIGHTMAP_SCALE
		pending_blizzard_accumulation += SnowSurfaceManager.blizzard_accumulation_rate * delta * full_height
	if pending_blizzard_accumulation:
		time_since_blizzard += 1
	
	if ticks % 15 == 0:
		LOD_mesh_update()
	elif (ticks + 1 )% 15 == 0:
		CPU_force_blizzard_collisions_update()
	
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
	#NOTE: snow mesh material must be loaded prior.
	snow_mesh.set_surface_override_material(0, snow_mesh_material)
	snow_mesh.set_instance_shader_parameter("UV_local_coordinates", UV_position)


static var material_setup : bool = false
static func prepare_material_static() -> void:
	if material_setup == false:
		snow_mesh_material.set_shader_parameter("snow_tex", SnowComputeManager.displayed_atlas_texture_wrapper)
		
		snow_mesh_material.set_shader_parameter("max_height", SNOW_MAX_HEIGHT)
		material_setup = true

##Makes a unique heightmap for the tile
func prepare_collisions() -> void:
	var shape := HeightMapShape3D.new()
	shape.map_depth = CPU_HEIGHTMAP_RESOLUTION_REDUCED
	shape.map_width = CPU_HEIGHTMAP_RESOLUTION_REDUCED
	coliision.shape = shape

func prepare_neighbors() -> void:
	var pos : Vector3i = global_position.round()
	for x : Snow_Tile in SnowSurfaceManager.Tiles:
		if x == self:
			continue
		var xpos : Vector3i = x.global_position.round()
		var delta : Vector3i = pos - xpos
		
		var x_neightbor : bool = absi(delta.x) <= 6
		var z_neightbor : bool = absi(delta.z) <= 6
		
		if x_neightbor and z_neightbor:
			snow_tile_neightbors.append(x)
			
	prints(self.name, " found ", snow_tile_neightbors.size(), " neighbors.")


var LOD: int = 0
func LOD_mesh_update() -> void:
	var _LOD : int
	#more than 20m away
	var cam : Camera3D = _get_camera_3d()
	if !cam:
		return
	var distance: float = _get_camera_distance()
	if distance > LOD_5_DIST * resolution_factor:
		_LOD = 5
	elif distance > LOD_4_DIST * resolution_factor:
		_LOD = 4
	elif distance > LOD_3_DIST * resolution_factor:
		_LOD = 3
	elif distance > LOD_2_DIST * resolution_factor:
		_LOD = 2
	elif distance > LOD_1_DIST * resolution_factor:
		_LOD = 1
	else:
		_LOD = 0

	
	if _LOD == LOD:
		return
	LOD = _LOD
	var mesh : PlaneMesh
	match LOD:
		0: mesh = mesh_high #high density mesh for your usual stuff
		1: mesh = mesh_med #medium density mesh when you get farther
		2: mesh = mesh_low #low density mesh when you get far
		3: mesh = mesh_lowst #lower lower density when you're really distant
		4: mesh = mesh_lowsp #almost no quality when you're super far
		5: mesh = mesh_lowmx  #no quality at all.
		#most of the higher LOD values really only exist for low resolution, where having tiny LODs kinda matter when the pixelation makes that you 
		#can't see more than 30 meters in HD.
	snow_mesh.mesh = mesh
	#print("did some LOD stuff")
	snow_mesh.set_instance_shader_parameter("lod_level", LOD)

func GPU_snow_accumulation_event(local_uv : Vector2, radius: float, accumulation_intensity: float = 1.0) -> void:
	GPU_snow_compression_event(local_uv, radius, accumulation_intensity, true)
##Simulates a circular snow event on the GPU. it is recommended to call GPU_snow_accumulation_event instead of setting use_Accumulate to true.
func GPU_snow_compression_event(local_uv : Vector2, radius: float, depth: float = 1.0, use_accumulate : bool = false) -> Error:
	var atlas_uv : Vector2 = local_to_atlas_uv(local_uv)
	var atlas_radius : float = radius * TO_ATLAS_UV_RADIUS_RATIO
	SnowComputeManager.request_stamp(atlas_uv, atlas_radius, depth, int(use_accumulate))
	
	return OK
func CPU_force_blizzard_collisions_update() -> void:
	if pending_blizzard_accumulation == 0.0:
		return
	var final_blizzard_ticks : float = time_since_blizzard
	if blizzard_time_offset == 0:
		blizzard_time_offset = randi_range(-128, 128)
	final_blizzard_ticks += blizzard_time_offset
	var cam_dist : float = _get_camera_distance()
	var time_before_force : float = TIME_BEFORE_FORCE_BLIZZARD_UPDATE
	
	if cam_dist > LOD_3_DIST:
		time_before_force *= 2.0
	elif cam_dist > LOD_2_DIST:
		time_before_force *= 1.5
	elif cam_dist > LOD_1_DIST:
		time_before_force *= 1.2
	
	if final_blizzard_ticks > time_before_force:
		CPU_important_update = true
	
	
	
##to be called by a worker thread.
static func CPU_workerthread_compute_pending_events(user : Snow_Tile) -> void:
	user.CPU_grid_thread_mutex_instance_queue.lock()
	var q : Array[Dictionary] = user.queued_events.duplicate()
	user.queued_events.clear()
	
	user.CPU_grid_thread_mutex_instance_queue.unlock()

	var dirty_min_x : int = CPU_HEIGHTMAP_RESOLUTION
	var dirty_max_x : int = -1
	var dirty_min_y : int = CPU_HEIGHTMAP_RESOLUTION
	var dirty_max_y : int = -1

	for x in q:
		var touched : Rect2i = user.CPU_snow_compression_event_radial(x[&"local_uv"] as Vector2, x[&"radius"] as float, x[&"depth"] as float, x[&"accumulate"] as bool)
		if touched.size.x < 0 or touched.size.y < 0:
			continue
		dirty_min_x = mini(dirty_min_x, touched.position.x)
		dirty_max_x = maxi(dirty_max_x, touched.position.x + touched.size.x)
		dirty_min_y = mini(dirty_min_y, touched.position.y)
		dirty_max_y = maxi(dirty_max_y, touched.position.y + touched.size.y)
	

	var blizzard_offset : float = user.pending_blizzard_accumulation
	var final_reduced : PackedFloat32Array = Snow_Tile.downsample_max_pool_region(
		user.snow_map_CPU,
		CPU_HEIGHTMAP_RESOLUTION,
		CPU_HEIGHTMAP_RESOLUTION_REDUCED,
		user.snow_map_CPU_reduced,
		dirty_min_x, dirty_max_x,
		dirty_min_y, dirty_max_y,
		blizzard_offset
	)
	final_reduced = user.apply_shear_to_heightmap(final_reduced)
	if blizzard_offset:
		user.snow_map_CPU = user.CPU_snow_accumulation_event_blizzard_flush(user.snow_map_CPU)
	
	user.CPU_grid_thread_mutex_instance.lock()
	user.snow_map_CPU_reduced = final_reduced
	user.CPU_grid_thread_mutex_instance.unlock()
	user.collisions_changed = true


##Notes into a queue the pending snow events if threading is enabled. this queue is then handled by dedicated threads and translated into the CPU collision array.
func CPU_queue_event_radial(local_uv : Vector2, radius: float, depth : float, global_pos : Vector3 = Vector3.ZERO,  disable_propagate: bool = false, accumulate : bool = false) -> void:
	
	if use_thread:
		CPU_grid_thread_mutex_instance_queue.lock()
		queued_events.append({
			&"local_uv" : local_uv,
			&"radius" : radius,
			&"depth" : depth,
			&"accumulate" : accumulate,
		})
		collisions_changed = true
		CPU_grid_thread_mutex_instance_queue.unlock()

	else:
		push_warning("WARNING: threading is disabled, collisions may incurr performance costs")
		CPU_snow_compression_event_radial(local_uv, radius, depth)
	#if the radius is too big, tell nearby snow tiles to register as well.
	if disable_propagate:
		#print("canceled propagate.")
		return
	
	if exceeds_current_tile(radius, local_uv):
		#print("tile needs propagation")
		for x : Snow_Tile in snow_tile_neightbors:
			#print("this tile has ", snow_tile_neightbors.size(), " neighbors")
			x._on_neightbor_request_compression(global_pos, depth, radius ,accumulate)
			#print("called neighbor tiles to finish.")

##Call if a neighbor had requested the snow event.
func CPU_neighbor_queue_event(local_uv : Vector2, radius: float, depth : float, global_pos : Vector3, accumulate : bool) -> void:
	#printt("neighbor is computing compression.", local_uv, radius, depth, global_pos, true, accumulate)
	CPU_queue_event_radial(local_uv, radius, depth * 1.6, global_pos, true, accumulate) # depth is exaggerated because imprecision makes neighboring tiles have weaker compute.
	#print("prepared neighbor event successfully")
##Simulates a circular snow event on the CPU side. Set accumulate to true to simulate snow accumulation. TODO: mutex when forcing a snow state change via debugs.
func CPU_snow_compression_event_radial(local_uv : Vector2, radius: float, depth : float, accumulate : bool = false) -> Rect2i:
	if no_collision:
		return Rect2i()
	
	if !use_thread:
		collisions_changed = true
	depth *= 1.2
	var grid_res := CPU_HEIGHTMAP_RESOLUTION
	if radius <= 1.55 and !accumulate:
		radius *= 1.5
	elif accumulate and radius > 2.0:
		print("accumulate snow anti-depth is ", depth)
		depth *= 15.0
	var falloff_radius : float = radius * UV_REDUCTOR_RATIO
	
	var center_x : float = local_uv.x * (grid_res - 1)
	var center_y : float = local_uv.y * (grid_res - 1)
	var cell_radius : float = falloff_radius * (grid_res - 1)
	# checks the boundaries of the snow event.
	var min_x : int = max(0, int(floor(center_x - cell_radius)))
	var max_x : int = min(grid_res - 1, int(ceil(center_x + cell_radius)))
	var min_y : int = max(0, int(floor(center_y - cell_radius)))
	var max_y : int = min(grid_res - 1, int(ceil(center_y + cell_radius)))
	var full_height : float = SNOW_MAX_HEIGHT / CPU_HEIGHTMAP_SCALE
	
	if accumulate: #I added a plus to target height to simulate accumulation.
		for gy in range(min_y, max_y + 1):
			for gx in range(min_x, max_x + 1):
				var grid_uv : Vector2 = Vector2(float(gx), float(gy)) / float(grid_res - 1)
				var dist : float = grid_uv.distance_to(local_uv)
				if dist < falloff_radius:
					var influence : float = smoothstep(0.0, 1.0, 1.0 - (dist / falloff_radius))
					var idx : int = gy * grid_res + gx
					var target_height : float = clamp(snow_map_CPU[idx] + depth * influence, 0.0, full_height)
					snow_map_CPU[idx] = max(snow_map_CPU[idx], target_height)
		return Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)
		
	for gy in range(min_y, max_y + 1):
		for gx in range(min_x, max_x + 1):
			var grid_uv : Vector2 = Vector2(float(gx), float(gy)) / float(grid_res - 1)
			var dist : float = grid_uv.distance_to(local_uv)
			if dist < falloff_radius:
				var influence : float = smoothstep(0.0, 1.0, 1.0 - (dist / falloff_radius))
				var idx : int = gy * grid_res + gx
				var target_height : float = clamp(full_height * (1.0 - depth * influence), 0.0, full_height)
				snow_map_CPU[idx] = min(snow_map_CPU[idx], target_height)

	return Rect2i(min_x, min_y, max_x - min_x, max_y - min_y)

func CPU_snow_accumulation_event_blizzard_flush(snow_map : PackedFloat32Array) -> PackedFloat32Array:
	time_since_blizzard = 0
	blizzard_time_offset = 0
	var blizzard_accumulation : float = pending_blizzard_accumulation
	if blizzard_accumulation == 0.0:
		return snow_map
	var full_height: float = SNOW_MAX_HEIGHT / CPU_HEIGHTMAP_SCALE

	var final_grid : PackedFloat32Array = snow_map
	
	pending_blizzard_accumulation = 0.0
	for x in final_grid.size():
		final_grid[x] = clampf(final_grid[x] + blizzard_accumulation, 0.0, full_height)
	return final_grid


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
	#if thread_started:
		#while WorkerThreadPool.is_task_completed(CPU_workerthread_task_id) == false:
			#await get_tree().physics_frame
	collisions_changed = true
	print("resetting CPU array")
	snow_map_CPU.fill(value)
	pending_blizzard_accumulation = 0.0
	snow_map_CPU_reduced.fill(value)
	#you need to do it right after.
	CPU_collision_update()
	
##Pushes the current low-res heightmap into the collision shape.
##Synchronous — assumes snow_map_CPU_reduced is already up to date
##(i.e. CPU_create_low_res_heightmap_synchronous already ran this update cycle).
func CPU_collision_update() -> void:
	if !collisions_changed:
		return
	instances_updating_collisions_this_frame += 1
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

func exceeds_current_tile(radius: float, local_uv: Vector2) -> bool:
	var rad : float = radius / (TILE_SIZE * 2.0)
	var inside_x : bool = local_uv.x >= rad and local_uv.x <= 1.0 - rad
	var inside_y : bool = local_uv.y >= rad and local_uv.y <= 1.0 - rad
	return not (inside_x and inside_y)
##Calculates the shear vertical offset of any given LOCAL point of the tile.
func apply_shear_to_heightmap(heightmap_reduced: PackedFloat32Array, shear_x: float = x_axis_shear, shear_z: float = z_axis_shear) -> PackedFloat32Array:
	if shear_x == 0.0 and shear_z == 0.0:
		return heightmap_reduced
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

#region preset movement effects

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
	if !visualonly: CPU_queue_event_radial(local_uv, 0.15, depth, world_position)
	#print("depth is ", depth)
	return 

func on_player_move(world_position: Vector3, collision_height : float = -999, visualonly : bool = false) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	var depth := 0.4
	if collision_height != -999.0:
		var sheared_height : float = shear_height_offset(Vector3(world_position.x, global_position.y, world_position.z))
		depth = clamp((1.0 -((collision_height - sheared_height)) / SNOW_MAX_HEIGHT), 0.0, 0.5)
		
	GPU_snow_compression_event(local_uv, 1.5, depth)
	if !visualonly: CPU_queue_event_radial(local_uv, 1.5, depth , world_position)
	#print("depth is ", depth)
	return 

##Large snow events that will consistently exceed multiple tiles. if using autodepth, input the lowest point of the event, not the center.
func on_explosion(world_position: Vector3, radius: float, depth: float, autodepth : bool = false) -> void:
	var mult : float = 1.0 #neighbor tiles lose some height for some reason.
	for tile : Snow_Tile in SnowSurfaceManager.get_tiles_in_radius(world_position, radius):
		mult = 1.0 if tile == self else 1.12
		if !autodepth:
			tile.on_compression_event(world_position, depth * mult, radius, eventmodes.normal, true)
		elif autodepth:
			tile.on_compression_event_auto_depth(world_position, depth * mult, radius, eventmodes.normal, true)
	


##Large snow events that will consistently exceed multiple tiles.
func on_accumulative_exposion(world_position: Vector3, radius: float, accumulation_intensity : float, _autodepth: bool = false) -> void:
	print("initiating accumulative explosion")
	for tile: Snow_Tile in SnowSurfaceManager.get_tiles_in_radius(world_position, radius):
		tile.on_accumulate_event(world_position, radius, accumulation_intensity, false, true)

#endregion

##Call for minor events that accumulate snow rather than compress it. accumulation intensity is the percentage of accumulation on the snow per second.
func on_accumulate_event(world_position: Vector3, radius: float, accumulation_intensity : float = 0.005, visualonly : bool = false, is_large_event : bool = false) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	accumulation_intensity *= get_process_delta_time()
	print("accumulation intensity is ", accumulation_intensity)
	if !visualonly: 
		var full_height : float = SNOW_MAX_HEIGHT / CPU_HEIGHTMAP_SCALE
		var cpu_accumulation_depth : float = accumulation_intensity * full_height
		CPU_queue_event_radial(local_uv, radius, cpu_accumulation_depth, world_position, is_large_event, true)
	GPU_snow_accumulation_event(local_uv, radius, accumulation_intensity)

##Call this when you have just an "event" which doesn't select depth. instead, depth is derived from the lowest point of the event.
func on_compression_event_auto_depth(world_position : Vector3, collision_height : float, radius: float, mode : eventmodes= eventmodes.normal, disable_propagate: bool = false) -> void:
	var depth : float
	var sheared_height : float = shear_height_offset(Vector3(world_position.x, global_position.y, world_position.z))
	depth = clamp((1.0 -((collision_height - sheared_height)) / SNOW_MAX_HEIGHT), 0.0, 1.0)
	on_compression_event(world_position, depth * 1.1, radius,mode, disable_propagate)
	#CPU_stash_or_use_sce(local_uv, )
##Call this when you have an event, where depth is an exact value. a value of 1 means fully compressed snow. enable disable propagate to prevent other tiles from also registering.
##Leave mode empty, and disable propagate too. These are developer settings for internal class functions. Bigger events should call on_explosion.
func on_compression_event(world_position: Vector3 , depth: float, radius : float, mode : eventmodes = eventmodes.normal, disable_propagate : bool = false) -> void:
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	
	if mode == eventmodes.visual or mode == eventmodes.normal:
		GPU_snow_compression_event(local_uv, radius, depth, false)
		
	if mode == eventmodes.logic or mode == eventmodes.normal:
		CPU_queue_event_radial(local_uv, radius, depth, world_position ,disable_propagate)
	#CPU_important_update = true
	#print("recorded a compression event.")


##Called by other tiles if their compression event is too big for just them. only logic.
func _on_neightbor_request_compression(world_position: Vector3, depth : float, radius: float, accumulate : bool ) -> void:
	var demi_rad : float = radius / 2.0
	var max_distance_squared : float = pow(4.24, 2.0) + pow(demi_rad, 2.0)
	if world_position.distance_squared_to(global_position) > max_distance_squared:
		#print("neighbor rejected event, too far")
		return
	#print("neighbor accepted event.")
	var local_uv : Vector2 = world_to_tile_uv(world_position)
	CPU_neighbor_queue_event(local_uv, radius, depth, world_position, accumulate) #true to prevent infinite recursion.
	CPU_important_update = true


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

static func _downsample_max_pool_region(
	src: PackedFloat32Array,
	src_size: int,
	dst_size: int,
	prev_dst: PackedFloat32Array,
	dirty_min_x: int, dirty_max_x: int,
	dirty_min_y: int, dirty_max_y: int,
	use_min: bool = false
) -> PackedFloat32Array:
	if dirty_max_x < dirty_min_x or dirty_max_y < dirty_min_y:
		return prev_dst

	var dst : PackedFloat32Array = prev_dst
	if dst.size() != dst_size * dst_size:
		dst.resize(dst_size * dst_size)

	for dr in dst_size:
		var row_indices : Array[int] = _axis_indices[dr]
		var row_intersects : bool = false
		for sy in row_indices:
			if sy >= dirty_min_y and sy <= dirty_max_y:
				row_intersects = true
				break
		if not row_intersects:
			continue

		for dc in dst_size:
			var col_indices : Array[int] = _axis_indices[dc]
			var col_intersects : bool = false
			for sx in col_indices:
				if sx >= dirty_min_x and sx <= dirty_max_x:
					col_intersects = true
					break
			if not col_intersects:
				continue

			var best : float = INF if use_min else -INF
			for sy in row_indices:
				var row_offset : int = sy * src_size
				for sx in col_indices:
					var v : float = src[row_offset + sx]
					best = minf(best, v) if use_min else maxf(best, v)
			dst[dr * dst_size + dc] = best

	return dst
	
static func downsample_max_pool_region(src: PackedFloat32Array, src_size: int, dst_size: int, prev_dst: PackedFloat32Array, dirty_min_x: int, dirty_max_x: int, dirty_min_y: int, dirty_max_y: int, blizzard_offset: float = 0.0, use_min: bool = false) -> PackedFloat32Array:
	
	if dirty_max_x < dirty_min_x or dirty_max_y < dirty_min_y:
		if blizzard_offset == 0.0:
			return prev_dst

	var dst: PackedFloat32Array = prev_dst

	if dst.size() != dst_size * dst_size:
		dst.resize(dst_size * dst_size)
	var full_height : float = SNOW_MAX_HEIGHT / CPU_HEIGHTMAP_SCALE

	var blizzard_active: bool = blizzard_offset != 0.0

	for dr in dst_size:
		var row_indices: Array[int] = _axis_indices[dr]
		var row_intersects: bool = false

		for sy in row_indices:
			if sy >= dirty_min_y and sy <= dirty_max_y:
				row_intersects = true
				break

		for dc in dst_size:
			var index: int = dr * dst_size + dc

			if !row_intersects:
				if blizzard_active:
					dst[index] += blizzard_offset
					dst[index] = clamp(dst[index], 0.0, full_height)
				continue

			var col_indices: Array[int] = _axis_indices[dc]
			var col_intersects: bool = false

			for sx in col_indices:
				if sx >= dirty_min_x and sx <= dirty_max_x:
					col_intersects = true
					break

			if !col_intersects:
				if blizzard_active:
					dst[index] = clampf(dst[index] + blizzard_offset, 0.0, full_height)
					
				continue

			var best: float = INF if use_min else -INF

			for sy in row_indices:
				var row_offset: int = sy * src_size

				for sx in col_indices:
					var v: float = src[row_offset + sx]

					if use_min:
						best = minf(best, v)
					else:
						best = maxf(best, v)

			dst[index] = clamp(best, 0.0, full_height)

	return dst
	
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):

		on_player_step(Vector3(randf_range(-3,3),0,randf_range(-3,3)))
			
		
	elif event.is_action_pressed("ui_left"):
		CPU_collision_update()

func _exit_tree() -> void:
	push_error("tiles exiting the tree force the snow threads to shut down. this is not intended and is purely debug.")
	SnowSurfaceThreadManager.shutdown()
	SnowSurfaceManager.remove_tile(self)

func _on_all_tiles_ready() -> void:
	print("got tile ready!!!")
	prepare_neighbors()
##Creates a 96x96 meter region filled with snow. this is the current largest possible snow region available due to space constraints. 
##Any bigger will cause UV boundary issues and not retain information.
func debug_propagate() -> void:
	if debug_propagate_large_area:
		print("PROPAGATING INTO LARGE AREA")
		var amount := 16
		for x in range(amount):
			for y in range(amount):
				var new_pos : Vector3 = Vector3.ZERO + Vector3(x - float(amount)/2, 0, y - float(amount)/2) * TILE_SIZE
				if self.global_position == new_pos:
					continue
				
				var new_tile : Snow_Tile= snow_tile.instantiate()
				new_tile.debug_print = false
				new_tile.debug_propagate_large_area = false
				new_tile.pending_position = new_pos
				get_parent().add_child.call_deferred(new_tile)
			await get_tree().process_frame

		await get_tree().physics_frame
		await get_tree().physics_frame
		await get_tree().physics_frame
		SnowSurfaceManager.announce_all_tiles_ready()
	
func _get_camera_3d() -> Camera3D:
	if !cached_camera:
		cached_camera = get_viewport().get_camera_3d()
	return cached_camera
	
##NOTE: this is distance squared.
func _get_camera_distance() -> float:
	cached_distance_to_cam = _get_camera_3d().global_position.distance_squared_to(global_position)
	return cached_distance_to_cam
