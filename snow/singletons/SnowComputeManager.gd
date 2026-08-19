extends Node
## Handles all compute related to snow as a singleton.
# every texture here is related to snow, so I will omit that from their names for simplicity
var rd : RenderingDevice

# --- DYNAMIC PATH REFACTOR ---
# Defined as uninitialized properties to prevent static compilation path errors on macOS
var ATLAS_SHADER : RDShaderFile
var SMOOTH_SHADER : RDShaderFile
var MIPMAP_SHADER : RDShaderFile
var NOISE_SHADER_DEPRACATED : RDShaderFile
var ACCUMULATE_SHADER : RDShaderFile
# ------------------------------

var atlas_texture : RID
var atlas_texture_wrapper : Texture2DRD
var displayed_atlas_texture : RID
var displayed_atlas_texture_wrapper : Texture2DRD

var shader : RID
var pipeline : RID
var smoothing_shader : RID
var smoothing_pipeline : RID

var noise_shader: RID
var noise_pipeline: RID
var noise_image_rd: RID
var noise_uniform_set: RID
var noise_texture_rd: Texture2DRD # bridged texture for sampling in snow.gdshader
var current_seed: int = 0
var current_frequency: float = 0.001
var noise_ready : bool = false

var ambient_shader: RID
var ambient_pipeline: RID
var ambient_uniform_set: RID
var ambient_accumulation_enabled: bool = false
var ambient_accumulation_rate: float = 0.001 # per tick, tune to taste

var mipmap_shader : RID
var mipmap_pipeline : RID

var displayed_mip_views : Array[RID] = []

## Cached, stable uniform set for the smoothing pass. Rebuilt only when atlas_texture or
## displayed_atlas_texture RIDs change, instead of every frame, to remove per-frame RD churn.
var smoothing_uniform_set : RID

const ATLAS_RESOLUTION : int = 2048
const SECT_RESOLUTION  : int = 128
## Compression uses max blending.
const OP_MAX_COMPRESS : int = 0
## Snow addition uses Accumulative blending.
const OP_ACCUMULATE : int = 1

## Max retries for a uniform_set_create call before giving up. Retrying in-frame instead of
## skipping means the visual smoothing pass never silently drops a frame.
const UNIFORM_SET_MAX_RETRIES : int = 8

var pending_stamps: Array[Dictionary] = []
## Guards pending_stamps against concurrent access from worker threads (e.g. SnowThreadPool)
## calling request_stamp() while _process() is reading/clearing the array.
var _stamps_mutex := Mutex.new()

var smoothing_speed : float = 0.9
var dampen_factor : float = 15.0  # add near smoothing_speed at top of file

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	# --- CORRECTED DYNAMIC PATH PARSING LOGIC ---
	# 1. Grab the absolute directory location of this exact running script file
	var base_dir : String = get_script().resource_path.get_base_dir()

	# 2. Use path_join() and simplify_path() to safely map the relative '..' syntax
	ATLAS_SHADER = load(base_dir.path_join("../../snow/compute/snow-stamp.glsl").simplify_path())
	SMOOTH_SHADER = load(base_dir.path_join("../../snow/compute/snow-stamp-smooth.glsl").simplify_path())
	MIPMAP_SHADER = load(base_dir.path_join("../../snow/compute/snow-mipmap.glsl").simplify_path())
	NOISE_SHADER_DEPRACATED = load(base_dir.path_join("../../snow/compute/snow-noise-generation.glsl").simplify_path())
	ACCUMULATE_SHADER = load(base_dir.path_join("../../snow/compute/snow-noise-accumulate.glsl").simplify_path())
	# --- CORRECTED LOGIC END ---

	rd = RenderingServer.get_rendering_device()
	_compile_shader()
	_compile_smoothing_shader()
	_compile_mipmap_shader()
	_compile_noise_shader()
	_compile_ambient_shader()
	_create_atlas()
	_create_displayed_atlas()
	_create_noise_image()
	_create_ambient_uniform_set()
	_rebuild_smoothing_uniform_set()

func _compile_shader() -> void:
	var shader_file: RDShaderFile = ATLAS_SHADER
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)

func _compile_smoothing_shader() -> void:
	var shader_file: RDShaderFile = SMOOTH_SHADER
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	smoothing_shader = rd.shader_create_from_spirv(spirv)
	smoothing_pipeline = rd.compute_pipeline_create(smoothing_shader)

func _compile_mipmap_shader() -> void:
	var shader_file : RDShaderFile = MIPMAP_SHADER
	var spirv : RDShaderSPIRV = shader_file.get_spirv()
	mipmap_shader = rd.shader_create_from_spirv(spirv)
	mipmap_pipeline = rd.compute_pipeline_create(mipmap_shader)

func _compile_noise_shader() -> void:
	var shader_file: RDShaderFile = NOISE_SHADER_DEPRACATED
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	noise_shader = rd.shader_create_from_spirv(spirv)
	noise_pipeline = rd.compute_pipeline_create(noise_shader)

func _compile_ambient_shader() -> void:
	var shader_file: RDShaderFile = ACCUMULATE_SHADER
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	ambient_shader = rd.shader_create_from_spirv(spirv)
	ambient_pipeline = rd.compute_pipeline_create(ambient_shader)

## Sets up the atlas texture as a black texture with a resolution specified by the constant above.
func _create_atlas(initial_value: float = 0.0) -> void:
	var fmt := RDTextureFormat.new()
	fmt.width = ATLAS_RESOLUTION
	fmt.height = ATLAS_RESOLUTION
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var view := RDTextureView.new()

	if ambient_uniform_set.is_valid():
		rd.free_rid(ambient_uniform_set)
		ambient_uniform_set = RID()

	# smoothing_uniform_set depends on atlas_texture - freeing atlas_texture below
	# will auto-invalidate it on RD's side. Clear our reference now so
	# _rebuild_smoothing_uniform_set() doesn't try to free an already-dead RID.
	if smoothing_uniform_set.is_valid():
		smoothing_uniform_set = RID()

	if atlas_texture.is_valid():
		rd.free_rid(atlas_texture)

	atlas_texture = rd.texture_create(fmt, view)

	var initial_data := PackedByteArray()
	initial_data.resize(ATLAS_RESOLUTION * ATLAS_RESOLUTION * 4)
	for i in range(0, initial_data.size(), 4):
		initial_data.encode_float(i, initial_value)

	rd.texture_update(atlas_texture, 0, initial_data)

	if atlas_texture_wrapper == null:
		atlas_texture_wrapper = Texture2DRD.new()

	if noise_image_rd.is_valid() and ambient_shader.is_valid():
		_create_ambient_uniform_set()

	if rd:
		_rebuild_smoothing_uniform_set()

func _create_displayed_atlas() -> void:
	var fmt := RDTextureFormat.new()
	fmt.width = ATLAS_RESOLUTION
	fmt.height = ATLAS_RESOLUTION
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM

	fmt.set_mipmaps(7)

	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var view := RDTextureView.new()
	displayed_atlas_texture = rd.texture_create(fmt, view)

	if not displayed_atlas_texture.is_valid():
		push_error("Failed to create displayed atlas texture.")
		return

	var total_size : int = 0
	for mip in 7:
		var resolution := ATLAS_RESOLUTION >> mip
		total_size += resolution * resolution * 1

	var initial_data := PackedByteArray()
	initial_data.resize(total_size)
	initial_data.fill(0.0)

	rd.texture_update(
		displayed_atlas_texture,
		0,
		initial_data
	)

	displayed_atlas_texture_wrapper = Texture2DRD.new()
	displayed_atlas_texture_wrapper.texture_rd_rid = displayed_atlas_texture

	_create_displayed_mip_views()

	# displayed_atlas_texture RID changed, the cached smoothing uniform set is stale.
	if rd:
		_rebuild_smoothing_uniform_set()

func _create_displayed_mip_views() -> void:
	displayed_mip_views.clear()

	if not displayed_atlas_texture.is_valid():
		push_error("Cannot create mip views: displayed atlas texture is invalid.")
		return

	for mip in range(7):
		var view := RDTextureView.new()

		var mip_texture := rd.texture_create_shared_from_slice(
			view,
			displayed_atlas_texture,
			0, # array layer
			mip, # mip level
			1, # mip levels exposed by this view
			RenderingDevice.TEXTURE_SLICE_2D
		)

		if not mip_texture.is_valid():
			push_error("Failed to create displayed mip view %d." % mip)
			continue

		displayed_mip_views.append(mip_texture)

func _create_noise_image() -> void:
	var fmt: RDTextureFormat = RDTextureFormat.new()
	fmt.width = ATLAS_RESOLUTION
	fmt.height = ATLAS_RESOLUTION
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)

	var view: RDTextureView = RDTextureView.new()
	noise_image_rd = rd.texture_create(fmt, view)

	noise_texture_rd = Texture2DRD.new()
	noise_texture_rd.texture_rd_rid = noise_image_rd

func _create_ambient_uniform_set() -> void:
	if ambient_uniform_set.is_valid():
		rd.free_rid(ambient_uniform_set)

	var atlas_uniform_local := RDUniform.new()
	atlas_uniform_local.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	atlas_uniform_local.binding = 0
	atlas_uniform_local.add_id(atlas_texture)

	var noise_uniform_local := RDUniform.new()
	noise_uniform_local.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	noise_uniform_local.binding = 1
	noise_uniform_local.add_id(noise_image_rd)

	ambient_uniform_set = _create_uniform_set_with_retry(
		[atlas_uniform_local, noise_uniform_local],
		ambient_shader,
		"ambient_uniform_set"
	)

## Central helper: attempts uniform_set_create up to UNIFORM_SET_MAX_RETRIES times.
## Ensures no compute pass is ever skipped due to a transient failed creation -
## it will keep retrying within the same call rather than bailing out for the frame.
func _create_uniform_set_with_retry(uniforms: Array, shader_rid: RID, context: String) -> RID:
	var result : RID = rd.uniform_set_create(uniforms, shader_rid, 0)
	var attempts : int = 0
	while not result.is_valid() and attempts < UNIFORM_SET_MAX_RETRIES:
		push_warning("uniform_set_create failed for '%s', retrying (%d/%d)..." % [context, attempts + 1, UNIFORM_SET_MAX_RETRIES])
		result = rd.uniform_set_create(uniforms, shader_rid, 0)
		attempts += 1
	if not result.is_valid():
		push_error("uniform_set_create permanently failed for '%s' after %d retries." % [context, UNIFORM_SET_MAX_RETRIES])
	return result

## Rebuilds the cached smoothing uniform set. Call whenever atlas_texture or
## displayed_atlas_texture RIDs are recreated.
func _rebuild_smoothing_uniform_set() -> void:
	if smoothing_uniform_set.is_valid():
		rd.free_rid(smoothing_uniform_set)
		smoothing_uniform_set = RID()

	if not atlas_texture.is_valid() or not displayed_atlas_texture.is_valid():
		return

	var uniform_target := RDUniform.new()
	uniform_target.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_target.binding = 0
	uniform_target.add_id(atlas_texture)

	var uniform_displayed := RDUniform.new()
	uniform_displayed.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_displayed.binding = 1
	uniform_displayed.add_id(displayed_atlas_texture)

	smoothing_uniform_set = _create_uniform_set_with_retry(
		[uniform_target, uniform_displayed],
		smoothing_shader,
		"smoothing_uniform_set"
	)

func _generate_atlas_mipmaps() -> void:
	if displayed_mip_views.size() != 7:
		push_error("Cannot generate mipmaps: not all mip views were created.")
		return

	if not mipmap_pipeline.is_valid():
		push_error("Mipmap pipeline is invalid.")
		return

	var uniform_sets: Array[RID] = []

	var list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(
		list,
		mipmap_pipeline
	)

	for mip in range(1, 7):
		var source_view: RID = displayed_mip_views[mip - 1]
		var destination_view: RID = displayed_mip_views[mip]

		if not source_view.is_valid() or not destination_view.is_valid():
			push_error("Invalid mip view at mip %d." % mip)
			continue

		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		source_uniform.binding = 0
		source_uniform.add_id(source_view)

		var destination_uniform := RDUniform.new()
		destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		destination_uniform.binding = 1
		destination_uniform.add_id(destination_view)

		var uniform_set := _create_uniform_set_with_retry(
			[source_uniform, destination_uniform],
			mipmap_shader,
			"mipmap_uniform_set_%d" % mip
		)

		if not uniform_set.is_valid():
			# Retries already exhausted and logged inside the helper; skip only this mip level.
			continue

		uniform_sets.append(uniform_set)

		rd.compute_list_bind_uniform_set(
			list,
			uniform_set,
			0
		)

		var size: int = ATLAS_RESOLUTION >> mip
		var groups: int = int(float(size) / 8.0)

		rd.compute_list_dispatch(
			list,
			groups,
			groups,
			1
		)

		# Make the destination mip visible to the next dispatch.
		rd.compute_list_add_barrier(list)

	rd.compute_list_end()

	for uniform_set in uniform_sets:
		if uniform_set.is_valid():
			rd.free_rid(uniform_set)

func generate_noise_map(seed_value: int, frequency: float = 0.01) -> void:
	current_seed = seed_value
	current_frequency = frequency

	var noise_uniform: RDUniform = RDUniform.new()
	noise_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	noise_uniform.binding = 0
	noise_uniform.add_id(noise_image_rd)

	if noise_uniform_set.is_valid():
		rd.free_rid(noise_uniform_set)
	noise_uniform_set = _create_uniform_set_with_retry([noise_uniform], noise_shader, "noise_uniform_set")
	if not noise_uniform_set.is_valid():
		return

	var push_constant: PackedByteArray = PackedByteArray()
	push_constant.resize(16)
	push_constant.encode_s32(0, seed_value)
	push_constant.encode_float(4, frequency)
	push_constant.encode_s32(8, ATLAS_RESOLUTION)
	push_constant.encode_float(12, 0.0)

	var list: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, noise_pipeline)
	rd.compute_list_bind_uniform_set(list, noise_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
	@warning_ignore("integer_division")
	rd.compute_list_dispatch(list, ATLAS_RESOLUTION / 8, ATLAS_RESOLUTION / 8, 1)
	rd.compute_list_end()
	noise_ready = true


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	_stamps_mutex.lock()
	var stamps_snapshot : Array[Dictionary] = pending_stamps.duplicate()
	pending_stamps.clear()
	_stamps_mutex.unlock()

	if stamps_snapshot.is_empty():
		_ambient_accumulate_step(delta)
		_smooth_atlas_step(delta)
		_generate_atlas_mipmaps()
		return

	var stamp_bytes: PackedByteArray = _pack_stamps(stamps_snapshot)
	var stamp_buffer : RID = rd.storage_buffer_create(stamp_bytes.size(), stamp_bytes)

	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	atlas_uniform.binding = 0
	atlas_uniform.add_id(atlas_texture)

	var stamp_uniform := RDUniform.new()
	stamp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	stamp_uniform.binding = 1
	stamp_uniform.add_id(stamp_buffer)

	# Stamp uniform set can't be cached like the smoothing one - stamp_buffer's RID changes
	# every batch since its size depends on how many stamps are queued this frame. Retried
	# instead, so a transient creation failure never drops the dispatch.
	var uniform_set : RID = _create_uniform_set_with_retry(
		[atlas_uniform, stamp_uniform],
		shader,
		"stamp_uniform_set"
	)

	if uniform_set.is_valid():
		var push_constant: PackedByteArray = PackedByteArray()
		push_constant.resize(4)
		push_constant.encode_s32(0, stamps_snapshot.size())

		var list: int = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, pipeline)
		rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
		@warning_ignore("integer_division")
		rd.compute_list_dispatch(list, ATLAS_RESOLUTION / 8, ATLAS_RESOLUTION / 8, 1)
		rd.compute_list_end()

		rd.free_rid(uniform_set)
	else:
		# Retries exhausted and already logged inside the helper. Stamps for this frame are lost -
		# put them back so they're retried next frame rather than silently discarded.
		_stamps_mutex.lock()
		pending_stamps.append_array(stamps_snapshot)
		_stamps_mutex.unlock()

	rd.free_rid(stamp_buffer)

	_ambient_accumulate_step(delta)
	_smooth_atlas_step(delta)
	_generate_atlas_mipmaps()

func _smooth_atlas_step(delta) -> void:
	if not smoothing_uniform_set.is_valid():
		# Should be rare - only happens if the cached set failed to build even after retries
		# during _rebuild_smoothing_uniform_set(). Attempt an immediate rebuild rather than
		# skip the visual update for this frame.
		_rebuild_smoothing_uniform_set()
		if not smoothing_uniform_set.is_valid():
			return

	var frame_speed : float = 1.0 - pow(1.0 - smoothing_speed, delta * 60.0)

	var push_constant := PackedByteArray()
	push_constant.resize(8)
	push_constant.encode_float(0, frame_speed)
	push_constant.encode_float(4, dampen_factor)

	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, smoothing_pipeline)
	rd.compute_list_bind_uniform_set(list, smoothing_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
	@warning_ignore("integer_division")
	rd.compute_list_dispatch(list, ATLAS_RESOLUTION / 8, ATLAS_RESOLUTION / 8, 1)
	rd.compute_list_end()
	# smoothing_uniform_set is cached and reused every frame - not freed here.

func _ambient_accumulate_step(delta: float) -> void:
	if not ambient_accumulation_enabled:
		return
	if not ambient_uniform_set.is_valid():
		push_warning("ambient_uniform_set invalid, attempting rebuild.")
		_create_ambient_uniform_set()
		if not ambient_uniform_set.is_valid():
			return

	var push_constant := PackedByteArray()
	push_constant.resize(16)
	push_constant.encode_float(0, ambient_accumulation_rate * delta)

	var list := rd.compute_list_begin()

	rd.compute_list_bind_compute_pipeline(list, ambient_pipeline)
	rd.compute_list_bind_uniform_set(list, ambient_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push_constant, push_constant.size())

	@warning_ignore("integer_division")
	rd.compute_list_dispatch(
		list,
		ATLAS_RESOLUTION / 8,
		ATLAS_RESOLUTION / 8,
		1
	)

	rd.compute_list_add_barrier(list)
	rd.compute_list_end()


func request_stamp(atlas_uv : Vector2, radius_uv: float, value: float, operation: int = OP_MAX_COMPRESS) -> void:
	_stamps_mutex.lock()
	pending_stamps.append({
		&"uv" : atlas_uv,
		&"radius" : radius_uv,
		&"value" : value,
		&"operation" : operation
	})
	_stamps_mutex.unlock()

func _pack_stamps(stamps: Array[Dictionary]) -> PackedByteArray:
	var bytes : PackedByteArray = PackedByteArray()
	bytes.resize(stamps.size() * 24)
	var offset : int = 0
	for stamp: Dictionary in stamps:
		var uv: Vector2 = stamp[&"uv"]
		bytes.encode_float(offset, uv.x)
		bytes.encode_float(offset + 4, uv.y)
		bytes.encode_float(offset + 8, stamp[&"radius"])
		bytes.encode_float(offset + 12, stamp[&"value"])
		bytes.encode_u32(offset + 16, stamp[&"operation"])
		bytes.encode_u32(offset + 20, 0) #padding lol

		offset += 24
	return bytes

func _exit_tree() -> void:
	if rd:
		rd.free_rid(noise_uniform_set)
		rd.free_rid(noise_image_rd)
		rd.free_rid(noise_pipeline)
		rd.free_rid(noise_shader)
		if smoothing_uniform_set.is_valid():
			rd.free_rid(smoothing_uniform_set)
