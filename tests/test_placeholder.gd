## Placeholder so the runner has something to run before real cpu_ref tests exist.
extends "res://tests/test_case.gd"


func test_runner_works() -> void:
	expect_eq(1 + 1, 2, "arithmetic")
