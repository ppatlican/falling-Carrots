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


## Godot re-imports a .glsl only when that file changes, not when a .glslinc it
## includes changes. A stale import compiles fine but has the old bindings, so
## fail when any include in a shader's folder is newer than the shader's import.
## Fix: in the editor FileSystem dock select the .glsl files > Reimport, or delete
## .godot/imported/*.glsl-* and re-open the project (touching the files does not help:
## Godot compares content hashes).
func test_shader_imports_newer_than_includes() -> void:
	for path in _glsl_files("res://gpu/shaders"):
		var dir := path.get_base_dir()
		var config := ConfigFile.new()
		if config.load(path + ".import") != OK:
			failures.append("%s has no .import file" % path)
			continue
		var imported_time := FileAccess.get_modified_time(config.get_value("remap", "path"))
		for file in DirAccess.get_files_at(dir):
			if file.ends_with(".glslinc") and FileAccess.get_modified_time(dir + "/" + file) > imported_time:
				failures.append("%s is older than %s: re-import the shaders" % [path, file])


func _glsl_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for sub in DirAccess.get_directories_at(dir):
		out.append_array(_glsl_files(dir + "/" + sub))
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".glsl"):
			out.append(dir + "/" + file)
	return out
