## Every compute shader must compile. SPIR-V is produced at import time, so this
## runs headless without a RenderingDevice.
extends "res://tests/test_case.gd"

## Test groups for run_tests.gd (-- @name); which to run for a change: docs/agents/testing.md.
const FILE_GROUPS := ["setup", "quick"]

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


## A shader edited after its import is refused (ComputeContext.import_is_stale), so the game
## shows an error instead of running the old SPIR-V; a fresh one, and one with no import
## record (an export), load. Fake import files in user://.
func test_stale_shader_import_is_refused() -> void:
	var src := "user://stale_probe.glsl"
	_write(src, "#[compute]\n#version 450\n// v2\n")
	_write(src + ".import", "[remap]\n\npath=\"user://stale_probe.glsl-0.res\"\n")
	_write("user://stale_probe.glsl-0.md5", "source_md5=\"%s\"\ndest_md5=\"0\"\n" % "#[compute]\n#version 450\n// v1\n".md5_text())
	expect(ComputeContext.import_is_stale(src), "a source changed since its import reads as stale")
	_write("user://stale_probe.glsl-0.md5", "source_md5=\"%s\"\ndest_md5=\"0\"\n" % FileAccess.get_md5(src))
	expect(not ComputeContext.import_is_stale(src), "a source matching its import reads as fresh")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://stale_probe.glsl-0.md5"))
	expect(not ComputeContext.import_is_stale(src), "no import record (an export): not stale")
	for f in [src, src + ".import"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))
	var errors := PackedStringArray(["shader a.glsl " + ComputeContext.STALE, "shader b.glsl " + ComputeContext.STALE])
	var text := ComputeContext.join_errors(errors)
	expect(text.begins_with(ComputeContext.STALE_FIX) and text.count(ComputeContext.STALE_FIX) == 1,
			"the fix for stale shaders is shown once, first: %s" % text)


func _write(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _glsl_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for sub in DirAccess.get_directories_at(dir):
		out.append_array(_glsl_files(dir + "/" + sub))
	for file in DirAccess.get_files_at(dir):
		if file.ends_with(".glsl"):
			out.append(dir + "/" + file)
	return out
