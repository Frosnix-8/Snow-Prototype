extends Node

const NUM_THREADS := 6

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

func enqueue_tile(tile: Snow_Tile) -> void:
	queue_mutex.lock()
	if tile not in job_queue: # avoid duplicate entries if already pending
		job_queue.append(tile)
	queue_mutex.unlock()
	queue_semaphore.post()

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
			Snow_Tile.CPU_workerthread_compute_pending_events(tile)

func shutdown() -> void:
	running = false
	for i in threads.size():
		queue_semaphore.post() # wake threads so they can exit
	for t in threads:
		t.wait_to_finish()
