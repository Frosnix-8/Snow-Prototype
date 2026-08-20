extends Node
enum eventtypes {
	MOVE,
	STEP,
	BOOM,
	ACC_BOOM,
	COMPRESSION,
	ACCUMULATION
}
var pending_events: Array[Dictionary]
var ticks : int = 0
func _physics_process(delta: float) -> void:
	ticks += 1
	if ticks % 2 == 0:
		relay_snow_events()
	
##Call to relay a snow event per-peer.
func propagate_snow_event(Tile : Snow_Tile, eventtype: Snow_Tile.eventtypes,where: Vector3, depth_or_height: float, radius: float) -> void:
	var events: Dictionary = {
		&"Tile_path": Tile.get_path(),
		&"eventtype": eventtype,
		&"where" : where,
		&"depth_or_height": depth_or_height,
		&"radius" : radius
	}
	pending_events.append(events)

func relay_snow_events() -> void:
	peer_receive_snow_event.rpc(pending_events)
	pending_events.clear()

@rpc("any_peer", "call_remote", "reliable")
func peer_receive_snow_event(events: Array[Dictionary]) -> void:
	
	if events.is_empty():
		return
	for event in events:
		var Tile = get_node_or_null(event[&"Tile_path"])
		match event[&"eventtype"]:
			eventtypes.MOVE: Tile.on_player_move(event[&"where"],event[&"depth_or_height"])
			eventtypes.STEP: Tile.on_player_step(event[&"where"],event[&"depth_or_height"])
			eventtypes.BOOM: Tile.on_explosion(event[&"where"], event[&"radius"], event[&"depth_or_height"],false)
			eventtypes.ACC_BOOM: Tile.on_accumulative_exposion(event[&"where"], event[&"radius"], event[&"depth_or_height"],false)
			eventtypes.COMPRESSION: Tile.on_compression_event(event[&"where"],event[&"depth_or_height"],event[&"radius"])
			eventtypes.ACCUMULATION: Tile.on_accumulate_event(event[&"where"], event[&"radius"], event[&"depth_or_height"])
