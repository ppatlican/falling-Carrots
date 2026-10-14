## Minimal headless test runner (no framework).
## Runs every test_*() method in every res://tests/test_*.gd file.
## Usage: godot --headless --path <project> --script res://tests/run_tests.gd [-- names...]
## With names after --, runs only what they select, in any mix:
##   test_bodies.gd                          a whole file
##   test_cork_pressed_into_wet_sand_rises   one method
##   @soft                                   a group (see below)
## and --list prints what would run (with groups) without running it.
## Which groups to run for a change: docs/agents/testing.md.
##
## Groups: a test file tags its tests with two optional constants,
##   const FILE_GROUPS := ["setup"]                     every test in the file
##   const GROUPS := {"test_name": ["rigid", "quick"]}  per method, added to FILE_GROUPS
## A test the selection names by file, method or any of its groups runs.
## Each test prints its wall time; the slow ones are the body-in-water scenes.
## Exit code 0 when all pass, 1 otherwise.
extends SceneTree

const TEST_DIR := "res://tests/"


func _initialize() -> void:
	var passed := 0
	var failed := 0
	var args := OS.get_cmdline_user_args()
	var list_only := args.has("--list")
	var only := PackedStringArray()
	for a in args:
		if a != "--list":
			only.append(a)
	var known := {}
	var start_all := Time.get_ticks_msec()
	for file in _test_files():
		var script: GDScript = load(TEST_DIR + file)
		if script == null or not script.can_instantiate():
			print("FAIL %s: could not load" % file)
			failed += 1
			continue
		var consts := script.get_script_constant_map()
		var file_groups: Array = consts.get("FILE_GROUPS", [])
		var groups: Dictionary = consts.get("GROUPS", {})
		known[file] = true
		var methods := {}
		for method in script.get_script_method_list():
			methods[method.name] = true
		for name in groups:
			if not methods.has(name):
				print("FAIL %s: GROUPS names %s, which is not a test in it" % [file, name])
				failed += 1
		for method in script.get_script_method_list():
			var name: String = method.name
			if not name.begins_with("test_"):
				continue
			known[name] = true
			var tags: Array = file_groups + groups.get(name, [])
			if tags.is_empty():
				print("FAIL %s::%s has no group: add it to GROUPS or FILE_GROUPS" % [file, name])
				failed += 1
			for t in tags:
				known["@" + t] = true
			if not only.is_empty() and not _selected(only, file, name, tags):
				continue
			if list_only:
				print("%s::%s  %s" % [file, name, " ".join(tags.map(func(t): return "@" + t))])
				passed += 1
				continue
			var start := Time.get_ticks_msec()
			var test = script.new()
			test.call(name)
			var secs := (Time.get_ticks_msec() - start) / 1000.0
			if test.failures.is_empty():
				print("PASS %s::%s (%.1f s)" % [file, name, secs])
				passed += 1
			else:
				print("FAIL %s::%s (%.1f s)" % [file, name, secs])
				for f in test.failures:
					print("    " + f)
				failed += 1
	for a in only:
		if not known.has(a):
			print("FAIL no test file, method or group named %s" % a)
			failed += 1
	if list_only:
		print("\n%d tests" % passed)
		quit(0 if failed == 0 else 1)
		return
	print("\n%d passed, %d failed in %.0f s" % [passed, failed, (Time.get_ticks_msec() - start_all) / 1000.0])
	quit(0 if failed == 0 and passed > 0 else 1)


func _selected(only: PackedStringArray, file: String, name: String, tags: Array) -> bool:
	if only.has(file) or only.has(name):
		return true
	for t in tags:
		if only.has("@" + t):
			return true
	return false


func _test_files() -> PackedStringArray:
	var out := PackedStringArray()
	for file in DirAccess.get_files_at(TEST_DIR):
		if file.begins_with("test_") and file.ends_with(".gd") and file != "test_case.gd":
			out.append(file)
	out.sort()
	return out
