## Minimal headless test runner (no framework).
## Runs every test_*() method in every res://tests/test_*.gd file.
## Usage: godot --headless --path <project> --script res://tests/run_tests.gd
## Exit code 0 when all pass, 1 otherwise.
extends SceneTree

const TEST_DIR := "res://tests/"


func _initialize() -> void:
	var passed := 0
	var failed := 0
	for file in _test_files():
		var script: GDScript = load(TEST_DIR + file)
		if script == null:
			print("FAIL %s: could not load" % file)
			failed += 1
			continue
		for method in script.get_script_method_list():
			var name: String = method.name
			if not name.begins_with("test_"):
				continue
			var test = script.new()
			test.call(name)
			if test.failures.is_empty():
				print("PASS %s::%s" % [file, name])
				passed += 1
			else:
				print("FAIL %s::%s" % [file, name])
				for f in test.failures:
					print("    " + f)
				failed += 1
	print("\n%d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 and passed > 0 else 1)


func _test_files() -> PackedStringArray:
	var out := PackedStringArray()
	for file in DirAccess.get_files_at(TEST_DIR):
		if file.begins_with("test_") and file.ends_with(".gd") and file != "test_case.gd":
			out.append(file)
	out.sort()
	return out
