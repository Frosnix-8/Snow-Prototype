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

## High precision source atlas (R32F, no mips). Stamps write here.
var atlas_texture : RID
## 8-bit mipmapped texture the snow material samples. It interpolates towards the atlas.
var displayed_atlas_texture : RID
## Created once and never replaced, so materials holding it stay valid.
var displayed_atlas_texture_wrapper : Texture2DRD = Texture2DRD.new()

var shader : RID
var pipeline : RID
var smoothing_shader : RID
var smoothing_pipeline : RID
var smoothing_uniform_set : RID

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
## mip_uniform_sets[i] downsamples mip i into mip i + 1. Built once, since the views never change.
var mip_uniform_sets : Array[RID] = []

const ATLAS_RESOLUTION : int = 2048 # keep whatever value you are using now
const SECT_RESOLUTION  : int = 128
const MIP_LEVELS : int = 7
## Compression uses max blending.
const OP_MAX_COMPRESS : int = 0
## Snow addition uses Accumulative blending.
const OP_ACCUMULATE : int = 1
## Frames the smoothing and mip passes keep running after the last change, so the display can converge.
## Raise it if the displayed snow stops short of the atlas, lower it to save more GPU time.
const SETTLE_FRAMES : int = 1

var pending_stamps: Array[Dictionary] = []
var settle_frames_left : int = 0

var smoothing_speed : float = 1.0
var dampen_factor : float = 15.0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	var base_dir : String = get_script().resource_path.get_base_dir()

	ATLAS_SHADER = load(base_dir.path_join("../../snow/compute/snow-stamp.glsl").simplify_path())
	SMOOTH_SHADER = load(base_dir.path_join("../../snow/compute/snow-stamp-smooth.glsl").simplify_path())
	MIPMAP_SHADER = load(base_dir.path_join("../../snow/compute/snow-mipmap.glsl").simplify_path())
	NOISE_SHADER_DEPRACATED = load(base_dir.path_join("../../snow/compute/snow-noise-generation.glsl").simplify_path())
	ACCUMULATE_SHADER = load(base_dir.path_join("../../snow/compute/snow-noise-accumulate.glsl").simplify_path())

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

## Returns the texture the snow material should sample.
func get_snow_display_texture() -> Texture2DRD:
	return displayed_atlas_texture_wrapper

func _compile_shader() -> void:
	var spirv: RDShaderSPIRV = ATLAS_SHADER.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)

func _compile_smoothing_shader() -> void:
	var spirv: RDShaderSPIRV = SMOOTH_SHADER.get_spirv()
	smoothing_shader = rd.shader_create_from_spirv(spirv)
	smoothing_pipeline = rd.compute_pipeline_create(smoothing_shader)

func _compile_mipmap_shader() -> void:
	var spirv : RDShaderSPIRV = MIPMAP_SHADER.get_spirv()
	mipmap_shader = rd.shader_create_from_spirv(spirv)
	mipmap_pipeline = rd.compute_pipeline_create(mipmap_shader)

func _compile_noise_shader() -> void:
	var spirv: RDShaderSPIRV = NOISE_SHADER_DEPRACATED.get_spirv()
	noise_shader = rd.shader_create_from_spirv(spirv)
	noise_pipeline = rd.compute_pipeline_create(noise_shader)

func _compile_ambient_shader() -> void:
	var spirv: RDShaderSPIRV = ACCUMULATE_SHADER.get_spirv()
	ambient_shader = rd.shader_create_from_spirv(spirv)
	ambient_pipeline = rd.compute_pipeline_create(ambient_shader)

## Sets up the source atlas as a black R32F texture. Also safe to call again to reset the snow.
func _create_atlas(initial_value: float = 0.0) -> void:
	# Free uniform sets that reference the old atlas BEFORE freeing the atlas itself.
	if ambient_uniform_set.is_valid():
		rd.free_rid(ambient_uniform_set)
		ambient_uniform_set = RID()
	if smoothing_uniform_set.is_valid():
		rd.free_rid(smoothing_uniform_set)
		smoothing_uniform_set = RID()
	if atlas_texture.is_valid():
		rd.free_rid(atlas_texture)

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
	atlas_texture = rd.texture_create(fmt, view)

	var initial_data := PackedByteArray()
	initial_data.resize(ATLAS_RESOLUTION * ATLAS_RESOLUTION * 4) # 4 bytes/pixel. resize() already zero-fills.
	if initial_value != 0.0:
		for i in range(0, initial_data.size(), 4):
			initial_data.encode_float(i, initial_value)

	rd.texture_update(atlas_texture, 0, initial_data)

	# Rebuild everything that references the new atlas.
	if noise_image_rd.is_valid() and ambient_shader.is_valid():
		_create_ambient_uniform_set()
	if displayed_atlas_texture.is_valid():
		_create_smoothing_uniform_set()

	# The display must catch up with the new atlas contents.
	settle_frames_left = SETTLE_FRAMES

## Sets up the 8-bit mipmapped texture the material samples. Created once.
func _create_displayed_atlas() -> void:
	var fmt := RDTextureFormat.new()
	fmt.width = ATLAS_RESOLUTION
	fmt.height = ATLAS_RESOLUTION
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	fmt.set_mipmaps(MIP_LEVELS)
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
	for mip in MIP_LEVELS:
		var resolution : int = ATLAS_RESOLUTION >> mip
		total_size += resolution * resolution

	var initial_data := PackedByteArray()
	initial_data.resize(total_size) # zero-filled
	rd.texture_update(displayed_atlas_texture, 0, initial_data)

	displayed_atlas_texture_wrapper.texture_rd_rid = displayed_atlas_texture

	_create_displayed_mip_views()
	_create_mip_uniform_sets()
	_create_smoothing_uniform_set()

func _create_displayed_mip_views() -> void:
	displayed_mip_views.clear()

	for mip in range(MIP_LEVELS):
		var view := RDTextureView.new()
		var mip_texture : RID = rd.texture_create_shared_from_slice(
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

## One uniform set per mip step (mip N-1 -> mip N), built once and reused every frame.
func _create_mip_uniform_sets() -> void:
	mip_uniform_sets.clear()
	if displayed_mip_views.size() != MIP_LEVELS:
		push_error("Cannot create mip uniform sets: not all mip views were created.")
		return

	for mip in range(1, MIP_LEVELS):
		var source_uniform := RDUniform.new()
		source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		source_uniform.binding = 0
		source_uniform.add_id(displayed_mip_views[mip - 1])

		var destination_uniform := RDUniform.new()
		destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		destination_uniform.binding = 1
		destination_uniform.add_id(displayed_mip_views[mip])

		mip_uniform_sets.append(rd.uniform_set_create([source_uniform, destination_uniform], mipmap_shader, 0))

## Binds atlas (binding 0) and displayed texture (binding 1) for the smoothing pass.
## Must be rebuilt whenever the atlas is recreated.
func _create_smoothing_uniform_set() -> void:
	if smoothing_uniform_set.is_valid():
		rd.free_rid(smoothing_uniform_set)

	var uniform_target := RDUniform.new()
	uniform_target.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_target.binding = 0
	uniform_target.add_id(atlas_texture)

	var uniform_displayed := RDUniform.new()
	uniform_displayed.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_displayed.binding = 1
	uniform_displayed.add_id(displayed_atlas_texture)

	smoothing_uniform_set = rd.uniform_set_create([uniform_target, uniform_displayed], smoothing_shader, 0)

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

	ambient_uniform_set = rd.uniform_set_create(
		[atlas_uniform_local, noise_uniform_local],
		ambient_shader,
		0
	)

## Downsamples mip N-1 into mip N of the displayed texture, using the cached uniform sets.
func _generate_atlas_mipmaps() -> void:
	if mip_uniform_sets.size() != MIP_LEVELS - 1:
		push_error("Cannot generate mipmaps: mip uniform sets were not created.")
		return

	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, mipmap_pipeline)

	for mip in range(1, MIP_LEVELS):
		rd.compute_list_bind_uniform_set(list, mip_uniform_sets[mip - 1], 0)

		@warning_ignore("integer_division")
		var groups: int = (ATLAS_RESOLUTION >> mip) / 8
		rd.compute_list_dispatch(list, groups, groups, 1)

		# Make the destination mip visible to the next dispatch.
		rd.compute_list_add_barrier(list)

	rd.compute_list_end()

func generate_noise_map(seed_value: int, frequency: float = 0.01) -> void:
	current_seed = seed_value
	current_frequency = frequency

	var noise_uniform: RDUniform = RDUniform.new()
	noise_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	noise_uniform.binding = 0
	noise_uniform.add_id(noise_image_rd)

	if noise_uniform_set.is_valid():
		rd.free_rid(noise_uniform_set)
	noise_uniform_set = rd.uniform_set_create([noise_uniform], noise_shader, 0)

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
	if not pending_stamps.is_empty():
		_apply_pending_stamps()
		settle_frames_left = SETTLE_FRAMES

	_ambient_accumulate_step(delta)
	if ambient_accumulation_enabled:
		settle_frames_left = SETTLE_FRAMES

	# Idle and settled: the displayed texture already matches the atlas, so skip both passes.
	if settle_frames_left <= 0:
		return
	settle_frames_left -= 1

	_smooth_atlas_step(delta)
	_generate_atlas_mipmaps()

## Uploads all pending stamps once, then runs one small dispatch per stamp over its bounding box.
func _apply_pending_stamps() -> void:
	var stamp_bytes: PackedByteArray = _pack_stamps(pending_stamps)
	var stamp_buffer: RID = rd.storage_buffer_create(stamp_bytes.size(), stamp_bytes)

	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	atlas_uniform.binding = 0
	atlas_uniform.add_id(atlas_texture)

	var stamp_uniform := RDUniform.new()
	stamp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	stamp_uniform.binding = 1
	stamp_uniform.add_id(stamp_buffer)

	var uniform_set: RID = rd.uniform_set_create([atlas_uniform, stamp_uniform], shader, 0)

	var list: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)

	for i: int in pending_stamps.size():
		var stamp: Dictionary = pending_stamps[i]
		var uv: Vector2 = stamp[&"uv"]
		var radius_px: float = stamp[&"radius"] * float(ATLAS_RESOLUTION)
		var center_px: Vector2 = uv * float(ATLAS_RESOLUTION)

		# Bounding box in pixels, clamped to the atlas.
		var min_x: int = maxi(0, int(floor(center_px.x - radius_px)))
		var min_y: int = maxi(0, int(floor(center_px.y - radius_px)))
		var max_x: int = mini(ATLAS_RESOLUTION - 1, int(ceil(center_px.x + radius_px)))
		var max_y: int = mini(ATLAS_RESOLUTION - 1, int(ceil(center_px.y + radius_px)))

		var width: int = max_x - min_x + 1
		var height: int = max_y - min_y + 1
		if width <= 0 or height <= 0:
			continue # stamp is entirely outside the atlas

		var push_constant: PackedByteArray = PackedByteArray()
		push_constant.resize(16)
		push_constant.encode_s32(0, min_x)
		push_constant.encode_s32(4, min_y)
		push_constant.encode_s32(8, i)
		push_constant.encode_s32(12, 0)
		rd.compute_list_set_push_constant(list, push_constant, push_constant.size())

		# Round up to whole 8x8 groups. The shader guards the overshoot.
		@warning_ignore("integer_division")
		rd.compute_list_dispatch(list, (width + 7) / 8, (height + 7) / 8, 1)

		# Make this stamp's writes visible before the next stamp reads the same pixels.
		rd.compute_list_add_barrier(list)

	rd.compute_list_end()

	rd.free_rid(uniform_set)
	rd.free_rid(stamp_buffer)
	pending_stamps.clear()

## Interpolates the displayed texture towards the atlas, using the cached uniform set.
func _smooth_atlas_step(delta: float) -> void:
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

func _ambient_accumulate_step(delta: float) -> void:
	if not ambient_accumulation_enabled:
		return
	if not ambient_uniform_set.is_valid():
		push_warning("ambient_uniform_set invalid, skipping accumulate step.")
		return

	var push_constant := PackedByteArray()
	push_constant.resize(16)
	push_constant.encode_float(0, ambient_accumulation_rate * delta)

	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, ambient_pipeline)
	rd.compute_list_bind_uniform_set(list, ambient_uniform_set, 0)
	rd.compute_list_set_push_constant(list, push_constant, push_constant.size())

	@warning_ignore("integer_division")
	rd.compute_list_dispatch(list, ATLAS_RESOLUTION / 8, ATLAS_RESOLUTION / 8, 1)

	rd.compute_list_add_barrier(list)
	rd.compute_list_end()

func request_stamp(atlas_uv : Vector2, radius_uv: float, value: float, operation: int = OP_MAX_COMPRESS) -> void:
	pending_stamps.append({
		&"uv" : atlas_uv,
		&"radius" : radius_uv,
		&"value" : value,
		&"operation" : operation
	})

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
		bytes.encode_u32(offset + 20, 0) # padding
		offset += 24
	return bytes

func _exit_tree() -> void:
	if rd:
		rd.free_rid(noise_uniform_set)
		rd.free_rid(noise_image_rd)
		rd.free_rid(noise_pipeline)
		rd.free_rid(noise_shader)
