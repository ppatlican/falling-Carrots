## Minimal headless test runner (no framework).
## Runs every test_*() method in every res://tests/test_*.gd file.
## Usage: godot --headless --path <project> --script res://tests/run_tests.gd [-- names...]
## With names after --, runs only what they select, in any mix:
##   test_bodies.gd                          a whole file
##   test_cork_pressed_into_wet_sand_rises   one method
##   test_bodies.gd::test_jelly_plank_bends_over_a_gap   one method of one file
##   @soft                                   a group (see below)
## and --list prints what would run (with groups) without running it.
## Which groups to run for a change: docs/agents/testing.md.
##
## Parallel: with more than one test selected, each test runs in its own child Godot process,
## up to -j N at once (default: half the logical cores, at least 1; -j 1 runs them one after
## another in this process). The longest run first, by the times the last runs took
## (user://test_durations.json; a test with no time yet counts as the longest), so the suite
## takes about as long as its slowest test. Each test's output is printed as one block when it
## ends, so the lines of two tests never mix. The CPU reference is deterministic, so a test
## prints the same numbers either way.
##
## Groups: a test file tags its tests with two optional constants,
##   const FILE_GROUPS := ["setup"]                     every test in the file
##   const GROUPS := {"test_name": ["rigid", "quick"]}  per method, added to FILE_GROUPS
## A test the selection names by file, method or any of its groups runs.
## Each test prints its wall time; the slow ones are the body-in-water scenes.
## Exit code 0 when all pass, 1 otherwise.
extends SceneTree

const TEST_DIR := "res://tests/"
const DURATIONS := "user://test_durations.json"
## Lines a child prints around its one test, so the parent drops Godot's banner and addon logs.
const BEGIN := "@@test-begin"
const END := "@@test-end"


func _initialize() -> void:
	var passed := 0
	var failed := 0
	var args := OS.get_cmdline_user_args()
	var list_only := args.has("--list")
	var child := args.has("--child")
	var jobs := maxi(1, OS.get_processor_count() / 2)
	var only := PackedStringArray()
	var k := 0
	while k < args.size():
		var a := args[k]
		if a == "-j" and k + 1 < args.size():
			jobs = maxi(1, args[k + 1].to_int())
			k += 1
		elif a.begins_with("-j") and a.length() > 2:
			jobs = maxi(1, a.substr(2).to_int())
		elif a != "--list" and a != "--child":
			only.append(a)
		k += 1
	var known := {}
	var start_all := Time.get_ticks_msec()
	# [file, name] of every selected test, in file and method order.
	var selected := []
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
			known[file + "::" + name] = true
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
			selected.append([file, name])
	for a in only:
		if not known.has(a):
			print("FAIL no test file, method or group named %s" % a)
			failed += 1
	if list_only:
		print("\n%d tests" % passed)
		quit(0 if failed == 0 else 1)
		return
	if child or jobs == 1 or selected.size() <= 1:
		for t in selected:
			if child:
				print(BEGIN)
			if _run_one(t[0], t[1]):
				passed += 1
			else:
				failed += 1
			if child:
				print(END)
	else:
		var r := _run_parallel(selected, jobs)
		passed += r.x
		failed += r.y
	print("\n%d passed, %d failed in %.0f s" % [passed, failed, (Time.get_ticks_msec() - start_all) / 1000.0])
	quit(0 if failed == 0 and passed > 0 else 1)


## Runs one test method here. Returns whether it passed.
func _run_one(file: String, name: String) -> bool:
	var script: GDScript = load(TEST_DIR + file)
	var start := Time.get_ticks_msec()
	var test = script.new()
	test.call(name)
	var secs := (Time.get_ticks_msec() - start) / 1000.0
	if test.failures.is_empty():
		print("PASS %s::%s (%.1f s)" % [file, name, secs])
		return true
	print("FAIL %s::%s (%.1f s)" % [file, name, secs])
	for f in test.failures:
		print("    " + f)
	return false


## Runs each test in a child process, at most `jobs` at once, longest first. Prints each test's
## output when it ends. Returns Vector2i(passed, failed).
func _run_parallel(selected: Array, jobs: int) -> Vector2i:
	var times := _load_durations()
	var queue := selected.duplicate()
	queue.sort_custom(func(a, b) -> bool:
		return times.get(a[0] + "::" + a[1], INF) > times.get(b[0] + "::" + b[1], INF))
	print("running %d tests in up to %d processes" % [queue.size(), jobs])
	var exe := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var running := []  # { "id", "pid", "stdio", "stderr", "out", "err" }
	var passed := 0
	var failed := 0
	while not queue.is_empty() or not running.is_empty():
		while running.size() < jobs and not queue.is_empty():
			var t: Array = queue.pop_front()
			var id: String = t[0] + "::" + t[1]
			var p := OS.execute_with_pipe(exe, PackedStringArray(["--headless", "--path", project,
					"--script", "res://tests/run_tests.gd", "--", "--child", id]), false)
			if p.is_empty():
				print("FAIL %s: could not start a test process" % id)
				failed += 1
				continue
			running.append({"id": id, "pid": p.pid, "stdio": p.stdio, "stderr": p.stderr,
					"out": PackedByteArray(), "err": PackedByteArray()})
		var still := []
		for c in running:
			# Drained every pass, so a child never blocks on a full pipe.
			c.out.append_array(_drain(c.stdio))
			c.err.append_array(_drain(c.stderr))
			if OS.is_process_running(c.pid):
				still.append(c)
				continue
			c.out.append_array(_drain(c.stdio))
			c.err.append_array(_drain(c.stderr))
			var r := _report_child(c, times)
			passed += r.x
			failed += r.y
		running = still
		if not running.is_empty():
			OS.delay_msec(20)
	_save_durations(times)
	return Vector2i(passed, failed)


## Prints a finished child's test output (the lines between BEGIN and END, then anything it wrote
## to stderr that isn't Godot's or an addon's startup noise) and records its time.
## Returns Vector2i(passed, failed).
func _report_child(c: Dictionary, times: Dictionary) -> Vector2i:
	var lines: PackedStringArray = c.out.get_string_from_utf8().replace("\r", "").split("\n")
	var body := PackedStringArray()
	var inside := false
	var result := ""
	for line in lines:
		if line == BEGIN:
			inside = true
		elif line == END:
			inside = false
		elif inside:
			body.append(line)
			if line.begins_with("PASS ") or line.begins_with("FAIL "):
				result = line
	var errors := _test_errors(c.err.get_string_from_utf8())
	body.append_array(errors)
	if result == "":
		body.insert(0, "FAIL %s (the test process ended without a result)" % c.id)
	# A script error doesn't stop a GDScript test, so it may still have printed PASS.
	var crashed := "\n".join(errors).find("SCRIPT ERROR") >= 0
	if crashed and result.begins_with("PASS "):
		body.append("FAIL %s: it hit a script error (above)" % c.id)
	print("\n".join(body))
	var m := RegEx.create_from_string("\\((\\d+\\.\\d) s\\)$").search(result)
	if m:
		times[c.id] = m.get_string(1).to_float()
	return Vector2i(1, 0) if result.begins_with("PASS ") and not crashed else Vector2i(0, 1)


## A child's stderr without what the MCP toolkit addon (an autoload, so it starts in every
## process) prints: its log lines, and the warnings it raises when many processes start at once
## and race on its registry file. A message is a line and the indented lines under it.
static func _test_errors(err: String) -> PackedStringArray:
	var out := PackedStringArray()
	var block := PackedStringArray()
	for line in (err.replace("\r", "") + "\nend").split("\n"):
		if line != "" and line[0] != " " and line[0] != "\t":
			var text := "\n".join(block)
			if not block.is_empty() and text.find("godot_mcp_toolkit") < 0 and text.find("[MCP") < 0:
				out.append_array(block)
			block = PackedStringArray()
		if line.strip_edges() != "":
			block.append(line)
	return out


## Everything a non-blocking pipe holds now.
static func _drain(f: FileAccess) -> PackedByteArray:
	var out := PackedByteArray()
	while true:
		var b := f.get_buffer(65536)
		if b.is_empty():
			break
		out.append_array(b)
	return out


static func _load_durations() -> Dictionary:
	var data = JSON.parse_string(FileAccess.get_file_as_string(DURATIONS))
	return data if typeof(data) == TYPE_DICTIONARY else {}


static func _save_durations(times: Dictionary) -> void:
	var f := FileAccess.open(DURATIONS, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(times))


func _selected(only: PackedStringArray, file: String, name: String, tags: Array) -> bool:
	if only.has(file) or only.has(name) or only.has(file + "::" + name):
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
