extends Node
##Manager of snow surfaces in the game.
#class_name Snow_Surface_Manager
signal all_tiles_ready
var Tiles : Array[Snow_Tile]
var snow_mat : ShaderMaterial = preload("res://snow/snow meshes/snow-shader-material.tres")

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
	if event.is_action_pressed("shinify"):
		var n : float = snow_mat.get_shader_parameter("ice_glow_strength")
		snow_mat.set_shader_parameter("ice_glow_strength", n + 0.05)
	elif event.is_action_pressed("deshinify"):
		var n : float = snow_mat.get_shader_parameter("ice_glow_strength")
		snow_mat.set_shader_parameter("ice_glow_strength", max(n - 0.05, 0.0))


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
