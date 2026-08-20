extends Node
##Manager of snow surfaces in the game.
#class_name Snow_Surface_Manager
signal all_tiles_ready
var tiles_by_id: Dictionary = {}  # String -> Snow_Tile
var Tiles : Array[Snow_Tile]
var snow_mat : ShaderMaterial = preload("../../snow/snow meshes/snow-shader-material.tres")
var blizzard_active : bool = false
var blizzard_accumulation_rate : float = 0.1
enum eventtypes {
	RADIAL, ##Event that has a radius,
	BLIZZARD, ##Event that accumulates every tile.
}
var ticks : int = 0
#
#func _ready() -> void:
	#await get_tree().physics_frame
	#noise_setup()

#func noise_generate_new_seed() -> void:
	#if !is_multiplayer_authority():
		#return
	#seed = randi()
	#noise.set_seed(seed)
	#if multiplayer.has_multiplayer_peer():
		#noise_transfer_new_seed.rpc(seed)
	#noise_setup()
	#

#@rpc("authority", "call_remote","reliable")
#func noise_transfer_new_seed(new_seed : int) -> void:
	#seed = new_seed
	#noise_setup()
#
#@rpc("any_peer", "call_remote", "reliable")
#func request_noise_new_seed() -> void:
	#noise_transfer_new_seed.rpc_id(multiplayer.get_remote_sender_id())
#
###call on new games or different snows.
#func noise_setup() -> void:
	#if seed == -1:
		#noise_generate_new_seed()
	#SnowComputeManager.generate_noise_map(seed, frequency)
	#noise.set_seed(seed)
	#noise.set_frequency(frequency)
		#



func register_tile(tile: Snow_Tile) -> void:
	Tiles.append(tile)
	tiles_by_id[tile.tile_id] = tile

func remove_tile(tile: Snow_Tile) -> void:
	Tiles.erase(tile)
	tiles_by_id.erase(tile.tile_id)

func get_tile_by_id(id: int) -> Snow_Tile:
	return tiles_by_id.get(id, null)
##sets to... whatever you choose here. higher is taller snow.
func reset_all_snow(height: float = 1.0) -> void:
	print("resetting snow")
	height = 1.0 - height
	#height = 
	SnowComputeManager._create_atlas(height)
	for x in Tiles:
		x.TMP_CPU_heightmap_reset(height)

func announce_all_tiles_ready() -> void:
	all_tiles_ready.emit()

#func _input(event: InputEvent) -> void:
	#if event.is_action_pressed("shinify", true):
		#var n : float = snow_mat.get_shader_parameter("ice_glow_strength")
		#snow_mat.set_shader_parameter("ice_glow_strength", n + 0.1)
	#elif event.is_action_pressed("deshinify", true):
		#var n : float = snow_mat.get_shader_parameter("ice_glow_strength")
		#snow_mat.set_shader_parameter("ice_glow_strength", max(n - 0.1, 0.0))


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
	#print("there are ", result.size(), " tiles around the master.")
	return result

func debug_toggle_snow_storm(rate: float = 0.1) -> void:
	if SnowComputeManager.ambient_accumulation_enabled == true:
		deactivate_snow_storm()
	else:
		activate_snow_storm(rate)
##begins slowly accumulating snow.
@rpc("authority", "call_remote", "reliable")
func activate_snow_storm(rate: float = 0.1) -> void:
	print("starting snow blizzard")

	if multiplayer.has_multiplayer_peer() and is_multiplayer_authority():
		activate_snow_storm.rpc(rate)
	
	SnowComputeManager.ambient_accumulation_enabled = true
	blizzard_active = true
	SnowComputeManager.ambient_accumulation_rate = rate
	blizzard_accumulation_rate = rate

@rpc("authority", "call_remote", "reliable")
func deactivate_snow_storm() -> void:
	print("stopping snow blizzard")
	blizzard_active = false
	SnowComputeManager.ambient_accumulation_enabled = false
	if multiplayer.has_multiplayer_peer() and is_multiplayer_authority():
		deactivate_snow_storm.rpc()
		
