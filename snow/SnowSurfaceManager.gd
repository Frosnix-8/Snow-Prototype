extends Node
##Manager of snow surfaces in the game.
#class_name Snow_Surface_Manager
var Tiles : Array[Snow_Tile]

func register_tile(tile : Snow_Tile) -> void:
	Tiles.append(tile)

func remove_tile(tile : Snow_Tile) -> void:
	Tiles.erase(tile)

##sets to... whatever you choose here. higher is taller snow.
func reset_all_snow(height: float = 1.0) -> void:
	print("resetting snow")
	height = 1.0 - height
	
	SnowComputeManager._create_atlas(height)
	for x in Tiles:
		x.TMP_CPU_heightmap_reset(height)
