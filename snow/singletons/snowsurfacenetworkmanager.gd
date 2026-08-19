extends Node
enum eventtypes {
	MOVE,
	STEP,
	BOOM,
	ACC_BOOM,
	COMPRESSION,
	ACCUMULATION
}
##Call to relay a snow event per-peer.
func propagate_snow_event(Tile : Snow_Tile, eventtype: Snow_Tile.eventtypes,where: Vector3, depth_or_height: float, radius: float) -> void:
	if multiplayer.has_multiplayer_peer():
		peer_receive_snow_event.rpc(Tile, eventtype, where, depth_or_height, radius)

@rpc("any_peer", "call_remote", "reliable")
func peer_receive_snow_event(Tile : Snow_Tile, eventtype: Snow_Tile.eventtypes,where: Vector3, depth_or_height: float, radius: float) -> void:
	if !Tile:
		return
	match eventtype:
		eventtypes.MOVE: Tile.on_player_move(where,depth_or_height)
		eventtypes.STEP: Tile.on_player_step(where,depth_or_height)
		eventtypes.BOOM: Tile.on_explosion(where, radius, depth_or_height,false)
		eventtypes.ACC_BOOM: Tile.on_accumulative_exposion(where, radius, depth_or_height,false)
		eventtypes.COMPRESSION: Tile.on_compression_event(where,depth_or_height,radius)
		eventtypes.ACCUMULATION: Tile.on_accumulate_event(where, radius, depth_or_height)
