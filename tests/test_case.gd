## Base class for headless tests. Each test_*() method is one test; it records
## failures with expect()/expect_eq() and keeps running.
extends RefCounted

var failures: PackedStringArray = []


func expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func expect_eq(actual, expected, message: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [message, str(expected), str(actual)])
