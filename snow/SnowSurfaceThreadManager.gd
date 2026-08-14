extends Node
const MAX_THREADS : int = 3
var NUM_THREADS : int = clampi(OS.get_processor_count(), 1, MAX_THREADS) 

var threads : Array[Thread] = []
var job_queue : Array[Snow_Tile] = []
var queue_mutex : Mutex = Mutex.new()
var queue_semaphore : Semaphore = Semaphore.new()
var running : bool = true

func _init() -> void:
	for i in NUM_THREADS:
		var t := Thread.new()
		t.start(_worker_loop)
		threads.append(t)
	print("initiated SNOWSURFACETHREADMANAGER with ", NUM_THREADS, " threads.")

func enqueue_tile(tile: Snow_Tile) -> void:
	queue_mutex.lock()
	if tile not in job_queue: # avoid duplicate entries if already pending
		job_queue.append(tile)
	queue_mutex.unlock()
	queue_semaphore.post()

func enqueue_tiles(tiles : Array[Snow_Tile]) -> void:
	queue_mutex.lock()
	for x in tiles.size():
		if tiles[x] not in job_queue:
			job_queue.append(tiles[x])
	queue_mutex.unlock()
	queue_semaphore.post(tiles.size())
	print("queued a bunch of tiles")
	
#func _process(delta: float) -> void:
	#if SnowSurfaceManager.blizzard_active:
		#queue_semaphore.post()

func _worker_loop() -> void:
	while running:
		queue_semaphore.wait() # blocks until work is posted, no busy-spin
		queue_mutex.lock()
		if job_queue.is_empty():
			queue_mutex.unlock()
			continue
		var tile : Snow_Tile = job_queue.pop_front()
		queue_mutex.unlock()
		if is_instance_valid(tile):
			#print("intiating some thread stuff")
			Snow_Tile.CPU_workerthread_compute_pending_events(tile)
		else:
			push_warning("attempted to access invalid tile ", tile)

func shutdown() -> void:
	running = false
	for i in threads.size():
		queue_semaphore.post() # wake threads so they can exit
	for t in threads:
		t.wait_to_finish()
