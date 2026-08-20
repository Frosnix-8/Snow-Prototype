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
func _physics_process(_delta: float) -> void:
	ticks += 1
	if ticks % 3 == 0:
		relay_snow_events()
	
# Snowsurfacenetworkmanager.gd — use tile_id instead of NodePath
##Call to propagate snow events to other peers.
func propagate_snow_event(Tile: Snow_Tile, eventtype: Snow_Tile.eventtypes, where: Vector3, depth_or_height: float, radius: float) -> void:
	var events: Dictionary = {
		&"tile_id": Tile.tile_id,
		&"eventtype": eventtype,
		&"where": where,
		&"depth_or_height": depth_or_height,
		&"radius": radius
	}
	pending_events.append(events)

func relay_snow_events() -> void:
	if pending_events.is_empty():
		return
	peer_receive_snow_event.rpc(pending_events)
	pending_events.clear()

@rpc("any_peer", "call_remote", "reliable")
func peer_receive_snow_event(events: Array[Dictionary]) -> void:
	if events.is_empty():
		return
	var missed: int = 0
	for event in events:
		var Tile: Snow_Tile = SnowSurfaceManager.get_tile_by_id(event[&"tile_id"])
		if !Tile:
			missed += 1
			continue
		match event[&"eventtype"]:
			Snow_Tile.eventtypes.MOVE: Tile.on_player_move(event[&"where"], event[&"depth_or_height"])
			Snow_Tile.eventtypes.STEP: Tile.on_player_step(event[&"where"], event[&"depth_or_height"])
			Snow_Tile.eventtypes.BOOM: Tile.on_explosion(event[&"where"], event[&"radius"], event[&"depth_or_height"], false)
			Snow_Tile.eventtypes.ACC_BOOM: Tile.on_accumulative_exposion(event[&"where"], event[&"radius"], event[&"depth_or_height"], false)
			Snow_Tile.eventtypes.COMPRESSION: Tile.on_compression_event(event[&"where"], event[&"depth_or_height"], event[&"radius"])
			Snow_Tile.eventtypes.ACCUMULATION: Tile.on_accumulate_event(event[&"where"], event[&"radius"], event[&"depth_or_height"])
	if missed > 0:
		push_warning("dropped %d snow events, tile_id not found on this peer" % missed)
