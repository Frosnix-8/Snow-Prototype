extends Node
##Manager of snow surfaces in the game.
#class_name Snow_Surface_Manager
signal all_tiles_ready
var Tiles : Array[Snow_Tile]
var snow_mat : ShaderMaterial = preload("res://snow/snow meshes/snow-shader-material.tres")
var noise : FastNoiseLite = FastNoiseLite.new()
var seed : int


func noise_generate_new_seed() -> void:
	if !is_multiplayer_authority():
		return
	seed = randi()
	noise.set_seed(seed)
	if multiplayer.has_multiplayer_peer():
		noise_transfer_new_seed.rpc(seed)
	
@rpc("authority", "call_local","reliable")
func noise_transfer_new_seed(new_seed : int) -> void:
	seed = new_seed
	noise.set_seed(seed)

func noise_setup() -> void:
	pass
		

func register_tile(tile : Snow_Tile) -> void:
	Tiles.append(tile)
	all_tiles_ready.connect(tile._on_all_tiles_ready)

func remove_tile(tile : Snow_Tile) -> void:
	Tiles.erase(tile)

##sets to... whatever you choose here. higher is taller snow.
func reset_all_snow(height: float = 1.0) -> void:
	print("resetting snow")
	height = 1.0 - height
	
	SnowComputeManager._create_atlas(height)
	for x in Tiles:
		x.TMP_CPU_heightmap_reset(height)

func announce_all_tiles_ready() -> void:
	all_tiles_ready.emit()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("shinify", true):
		var n : float = snow_mat.get_shader_parameter("ice_glow_strength")
		snow_mat.set_shader_parameter("ice_glow_strength", n + 0.1)
	elif event.is_action_pressed("deshinify", true):
		var n : float = snow_mat.get_shader_parameter("ice_glow_strength")
		snow_mat.set_shader_parameter("ice_glow_strength", max(n - 0.1, 0.0))


func get_tiles_in_radius(world_position: Vector3, radius: float) -> Array[Snow_Tile]:
	var result : Array[Snow_Tile] = []
	#radius *= 1.0 #padding
	var half_size : float = Snow_Tile.TILE_SIZE * 0.5

	for tile : Snow_Tile in Tiles:
		var closest_x : float = clampf(world_position.x, tile.global_position.x - half_size, tile.global_position.x + half_size)
		var closest_z : float = clampf(world_position.z, tile.global_position.z - half_size, tile.global_position.z + half_size)
		var dx : float = world_position.x - closest_x
		var dz : float = world_position.z - closest_z
		if (dx * dx + dz * dz) <= radius * radius:
			result.append(tile)
	print("there are ", result.size(), " tiles around the master.")
	return result
	
	
