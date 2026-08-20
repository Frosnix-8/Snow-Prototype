extends Node
enum eventtypes {
	MOVE,
	STEP,
	BOOM,
	ACC_BOOM,
	COMPRESSION,
	ACCUMULATION
}
const ID := 0
const TYPE := 1
const POS := 2
const DEPTH := 3
const RAD := 4
var pending_events: Array[Array] = []
var ticks : int = 0
func _physics_process(_delta: float) -> void:
	ticks += 1
	if ticks % 4 == 0:
		relay_snow_events()
	
# Snowsurfacenetworkmanager.gd — use tile_id instead of NodePath
##Call to propagate snow events to other peers.
func propagate_snow_event(Tile: Snow_Tile, eventtype: Snow_Tile.eventtypes, where: Vector3, depth_or_height: float, radius: float) -> void:
	var events: Array = [
		Tile.tile_id,
		eventtype,
		where,
		depth_or_height,
		radius
	]
	pending_events.append(events)

func relay_snow_events() -> void:
	if pending_events.is_empty():
		return
	peer_receive_snow_event.rpc(pending_events)
	pending_events.clear()

@rpc("any_peer", "call_remote", "reliable")
func peer_receive_snow_event(events: Array[Array]) -> void:
	if events.is_empty():
		return
	var missed: int = 0
	for event in events:
		var Tile: Snow_Tile = SnowSurfaceManager.get_tile_by_id(event[ID])
		if !Tile:
			missed += 1
			continue
		match event[TYPE]:
			Snow_Tile.eventtypes.MOVE: Tile.on_player_move(event[POS] as Vector3, event[DEPTH] as float, false, true)
			Snow_Tile.eventtypes.STEP: Tile.on_player_step(event[POS] as Vector3, event[DEPTH] as float, false, true)
			Snow_Tile.eventtypes.BOOM: Tile.on_explosion(event[POS] as Vector3, event[RAD], event[DEPTH] as float, false, true)
			Snow_Tile.eventtypes.ACC_BOOM: Tile.on_accumulative_exposion(event[POS] as Vector3, event[RAD] as float, event[DEPTH] as float, false, true)
			Snow_Tile.eventtypes.COMPRESSION: Tile.on_compression_event(event[POS] as Vector3, event[DEPTH] as float, event[RAD] as float, Snow_Tile.eventmodes.normal, false, true)
			Snow_Tile.eventtypes.ACCUMULATION: Tile.on_accumulate_event(event[POS] as Vector3, event[RAD] as float, event[DEPTH] as float, false, false, true)
	if missed > 0:
		push_warning("dropped %d snow events, tile_id not found on this peer" % missed)
