## Every compute shader must compile. SPIR-V is produced at import time, so this
## runs headless without a RenderingDevice.
extends "res://tests/test_case.gd"

const ComputeContext = preload("res://gpu/compute_context.gd")


func test_all_compute_shaders_compile() -> void:
	var paths := _glsl_files("res://gpu/shaders")
	expect(not paths.is_empty(), "found no .glsl files")
	for path in paths:
		var errors := PackedStringArray()
		ComputeContext.load_spirv(path, errors)
		for e in errors:
			failures.append(e)


func _glsl_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for sub in DirAccess.get_directories_at(dir):
		out.append_array(_glsl_files(dir + "/" + sub))
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".glsl"):
			out.append(dir + "/" + file)
	return out
