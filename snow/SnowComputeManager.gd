extends Node
##Handles all compute related to snow as a singleton.
#every texture here is related to snow, so I will omit that from their names for simplicity


var atlas_texture : RID
var atlas_texture_wrapper : Texture2DRD
var displayed_atlas_texture : RID
var displayed_atlas_texture_wrapper : Texture2DRD


var rd : RenderingDevice
var shader : RID
var pipeline : RID
var smoothing_shader : RID
var smoothing_pipeline : RID

const ATLAS_RESOLUTION : int = 2048
const SECT_RESOLUTION  : int = 128
##Compression uses max blending.
const OP_MAX_COMPRESS : int = 0
##Snow addition uses Accumulative blending.
const OP_ACCUMULATE : int = 1

var pending_stamps: Array[Dictionary] = []

var smoothing_speed : float = 0.9
var dampen_factor : float = 15.0  # add near smoothing_speed at top of file
# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	rd = RenderingServer.get_rendering_device()
	_compile_shader()
	_compile_smoothing_shader()
	_create_atlas()
	_create_displayed_atlas()

func _compile_shader() -> void:
	var shader_file: RDShaderFile = load("res://snow/compute/snow-stamp.glsl")
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	shader = rd.shader_create_from_spirv(spirv)
	pipeline = rd.compute_pipeline_create(shader)
	
func _compile_smoothing_shader() -> void:
	var shader_file: RDShaderFile = load("res://snow/compute/snow-stamp-smooth.glsl")
	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	smoothing_shader = rd.shader_create_from_spirv(spirv)
	smoothing_pipeline = rd.compute_pipeline_create(smoothing_shader)

##Sets up the atlas texture as a black texture with a resolution specified by the constant above.
func _create_atlas(initial_value : float = 0.0) -> void:
	var fmt : RDTextureFormat = RDTextureFormat.new()
	fmt.width = ATLAS_RESOLUTION
	fmt.height = ATLAS_RESOLUTION
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	
	var view : RDTextureView = RDTextureView.new()
	atlas_texture = rd.texture_create(fmt, view)
	
	var initial_data := PackedByteArray()
	initial_data.resize(ATLAS_RESOLUTION * ATLAS_RESOLUTION)
	initial_data.fill(int(initial_value * 255))
	rd.texture_update(atlas_texture, 0, initial_data)
	
	atlas_texture_wrapper = Texture2DRD.new()
	atlas_texture_wrapper.texture_rd_rid = atlas_texture

func _create_displayed_atlas() -> void:
	var fmt : RDTextureFormat = RDTextureFormat.new()
	fmt.width = ATLAS_RESOLUTION
	fmt.height = ATLAS_RESOLUTION
	fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	#fmt.set_mipmaps(6)
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	var view : RDTextureView = RDTextureView.new()
	displayed_atlas_texture = rd.texture_create(fmt, view)

	var initial_data := PackedByteArray()
	initial_data.resize(ATLAS_RESOLUTION * ATLAS_RESOLUTION)
	initial_data.fill(0)
	
	rd.texture_update(displayed_atlas_texture, 0, initial_data)

	displayed_atlas_texture_wrapper = Texture2DRD.new()
	displayed_atlas_texture_wrapper.texture_rd_rid = displayed_atlas_texture

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	if pending_stamps.is_empty():
		_smooth_atlas_step(delta)
		return
	
	var stamp_bytes: PackedByteArray = _pack_stamps(pending_stamps)
	var stamp_buffer : RID = rd.storage_buffer_create(stamp_bytes.size(), stamp_bytes)
	
	var atlas_uniform := RDUniform.new()
	atlas_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	atlas_uniform.binding = 0
	atlas_uniform.add_id(atlas_texture)
	
	var stamp_uniform := RDUniform.new()
	stamp_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	stamp_uniform.binding = 1
	stamp_uniform.add_id(stamp_buffer)
	
	var uniform_set : RID = rd.uniform_set_create([atlas_uniform, stamp_uniform], shader, 0)
	
	var push_constant: PackedByteArray = PackedByteArray()
	push_constant.resize(4)
	push_constant.encode_s32(0, pending_stamps.size())
	
	var list: int = rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
	#print("snow computer is dispatching the compute shader.")
	@warning_ignore("integer_division")
	rd.compute_list_dispatch(list, ATLAS_RESOLUTION / 8, ATLAS_RESOLUTION / 8, 1)
	rd.compute_list_end()
	
	rd.free_rid(uniform_set)
	rd.free_rid(stamp_buffer)
	pending_stamps.clear()
	
	_smooth_atlas_step(delta)
	
func _smooth_atlas_step(delta) -> void:
	var uniform_target := RDUniform.new()
	uniform_target.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_target.binding = 0
	uniform_target.add_id(atlas_texture)

	var uniform_displayed := RDUniform.new()
	uniform_displayed.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform_displayed.binding = 1
	uniform_displayed.add_id(displayed_atlas_texture)

	var uniform_set : RID = rd.uniform_set_create([uniform_target, uniform_displayed], smoothing_shader, 0)

	var frame_speed : float = 1.0 - pow(1.0 - smoothing_speed, delta * 60.0)

	var push_constant := PackedByteArray()
	push_constant.resize(8)
	push_constant.encode_float(0, frame_speed)
	push_constant.encode_float(4, dampen_factor)

	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, smoothing_pipeline)
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
	@warning_ignore("integer_division")
	rd.compute_list_dispatch(list, ATLAS_RESOLUTION / 8, ATLAS_RESOLUTION / 8, 1)
	rd.compute_list_end()

	rd.free_rid(uniform_set)
	

func request_stamp(atlas_uv : Vector2, radius_uv: float, value: float, operation: int = OP_MAX_COMPRESS) -> void:
	pending_stamps.append({
		&"uv" : atlas_uv,
		&"radius" : radius_uv,
		&"value" : value,
		&"operation" : operation
	})
	#if operation == OP_ACCUMULATE:
		#print("for some reason we need to accumulate")
	#print("snow computer received request for a stamp from snow.")
	
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
	#print("snow computer is packing stamps into a byte array.")
	return bytes
	
	
	
