## Milestone 1 setup: config loading and the project settings the spec depends on.
extends "res://tests/test_case.gd"

const GameConfig = preload("res://core/game_config.gd")


func test_config_file_loads_cleanly() -> void:
	var cfg = GameConfig.load_from_file()
	expect(cfg.errors.is_empty(), "config.json errors: %s" % ", ".join(cfg.errors))
	expect(cfg.particle_cap > 0, "particle_cap > 0")
	expect(cfg.solver_iterations > 0, "solver_iterations > 0")


func test_config_rejects_bad_values() -> void:
	var cfg = GameConfig.new()
	cfg.apply({"particle_cap": 10, "solver_iterations": 2.5})
	expect_eq(cfg.particle_cap, 1024, "particle_cap clamped to minimum")
	expect_eq(cfg.solver_iterations, 4, "fractional iterations fall back to default")
	expect_eq(cfg.errors.size(), 2, "both problems reported")


func test_input_actions_exist() -> void:
	for action in ["draw", "erase", "grab", "pause", "clear", "toggle_debug"]:
		expect(InputMap.has_action(action), "input action '%s'" % action)
	var events := InputMap.action_get_events("toggle_debug")
	expect(events.size() == 1 and events[0] is InputEventKey \
			and events[0].physical_keycode == KEY_F3, "toggle_debug is F3")


func test_renderer_settings() -> void:
	var s := func(key): return ProjectSettings.get_setting(key)
	expect_eq(s.call("rendering/renderer/rendering_method"), "mobile", "rendering_method")
	expect_eq(s.call("rendering/rendering_device/driver.windows"), "vulkan", "windows driver")
	expect_eq(s.call("rendering/rendering_device/fallback_to_opengl3"), false, "no GL fallback")
	expect_eq(s.call("display/window/stretch/aspect"), "keep", "letterboxing")
	expect_eq(s.call("display/window/size/viewport_width"), 640, "base width")
	expect_eq(s.call("display/window/size/viewport_height"), 360, "base height")
	expect_eq(s.call("rendering/textures/canvas_textures/default_texture_filter"), 0, "nearest filter")
