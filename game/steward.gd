extends Node
## The AI steward: Muse Spark, acting only through tools.
## Farm tools change the farm (the same ones the manager's buttons call). Scene tools move the
## camera, set the speed, open a container's or worker's details, and start a what-if.
## In "ask first" mode every change to the farm is shown to the manager and waits for a yes.
## Time keeps running while it thinks.

const Farm := preload("res://game/farm.gd")
const URL := "https://api.meta.ai/v1/chat/completions"
const MODEL := "muse-spark-1.3"
const MAX_TURNS := 6
const VIEW_ONLY := ["get_state", "look_at", "set_speed", "inspect"]   # these never need approval

signal said(text: String)
signal proposed(lines: Array)
signal acted(line: String, good: bool)
signal decided(yes: bool)
signal finished

var farm: Farm
var scene           # the main node: scene_tools_spec(), is_scene_tool(), scene_tool()
var ask_first := true
var busy := false
var key := ""
var history := []
var http: HTTPRequest
var run := 0        # bumps on stop(), so a cancelled order does nothing more


func _ready() -> void:
	http = HTTPRequest.new()
	http.timeout = 120.0
	add_child(http)
	# The key comes from the environment, or on a Mac from a Keychain item named meta-model-api.
	key = OS.get_environment("META_API_KEY")
	if key == "" and OS.get_name() == "macOS":
		var out := []
		if OS.execute("security", ["find-generic-password", "-s", "meta-model-api", "-w"], out) == 0 and out.size() > 0:
			key = String(out[0]).strip_edges()


func _system() -> String:
	return "\n".join([
		"You are the steward of a container mushroom farm, working for its manager inside a farm simulator.",
		"Bags (bongkah) flow through these steps: Lab (spawn), Prepare (sawdust, dedak padi and calcium carbonate mixed and bagged), Steam in the autoclaves, Cooling room, Seeding, Incubation, Move In and Open Cap, Harvest in flushes, Removal.",
		"Weather matters: heat raises aircond electricity and incubation losses, rain fills the water tank and makes vents less drying, storms can cut the power.",
		"Every station uses electricity and water. Watch cost as well as yield.",
		"You can change the farm only through the tools. Read the farm state you are given before acting, and call get_state if you need it fresh.",
		"You can also work the manager's view: look_at moves the camera, set_speed changes the clock, inspect opens a container or a worker, what_if starts a rehearsal scenario. Use what_if only when the manager asks for one.",
		"Work out the numbers: capacities, rates, days, kilograms, kWh, litres. Prefer the smallest change that meets the manager's goal.",
		"If a goal cannot be met with what the farm has, say so plainly and say what would be needed.",
		"Many settings are placeholders marked as assumed. Do not present results as real farm figures.",
		"Reply in the language the manager used. Keep it to a few short sentences: what you did or propose, and why.",
	])


func reset() -> void:
	history = []


func stop() -> void:
	# Drop whatever is in flight.
	run += 1
	http.cancel_request()
	if busy:
		busy = false
		decided.emit(false)
		finished.emit()


func decide(yes: bool) -> void:
	decided.emit(yes)


func ask(text: String) -> void:
	if busy:
		said.emit("I am still working on the last order. Type /stop to cancel it.")
		return
	if key == "":
		said.emit("No Meta API key was found. Set META_API_KEY, or add a Keychain item named meta-model-api.")
		finished.emit()
		return
	busy = true
	run += 1
	var mine := run
	if history.is_empty():
		history.append({"role": "system", "content": _system()})
	history.append({"role": "user", "content": text + "\n\nThe farm now:\n" + JSON.stringify(farm.snapshot())})
	for turn in MAX_TURNS:
		var msg = await _post()
		if mine != run:
			return
		if not (msg is Dictionary):
			break
		var calls = msg.get("tool_calls")
		var words := ""
		if msg.get("content") != null:
			words = str(msg.get("content")).strip_edges()
		var keep := {"role": "assistant", "content": words}
		if calls is Array and not calls.is_empty():
			keep["tool_calls"] = calls
		history.append(keep)
		if words != "":
			said.emit(words)
		if not (calls is Array) or calls.is_empty():
			break
		var parsed := []
		var lines := []
		for cl in calls:
			var args = JSON.parse_string(str(cl["function"]["arguments"]))
			if not (args is Dictionary):
				args = {}
			var tool_name := str(cl["function"]["name"])
			parsed.append([cl["id"], tool_name, args])
			if not VIEW_ONLY.has(tool_name):
				lines.append(plain(tool_name, args))
		var yes := true
		if ask_first and not lines.is_empty():
			proposed.emit(lines)
			yes = await decided
			if mine != run:
				return
		for p in parsed:
			var view_only: bool = VIEW_ONLY.has(p[1])
			var out: Dictionary = {"ok": false, "error": "The manager rejected this."}
			if yes or view_only:
				out = scene.scene_tool(p[1], p[2]) if scene != null and scene.is_scene_tool(p[1]) else farm.call_tool(p[1], p[2])
			history.append({"role": "tool", "tool_call_id": p[0], "content": JSON.stringify(out)})
			if p[1] != "get_state" and (yes or view_only):
				acted.emit(plain(p[1], p[2]) + ": " + str(out.get("result", out.get("error", ""))), bool(out["ok"]))
		if not yes:
			said.emit("Understood. Nothing was changed.")
			break
	busy = false
	finished.emit()


func _post():
	var tools: Array = farm.tools_spec()
	if scene != null:
		tools = tools + scene.scene_tools_spec()
	var body := {"model": MODEL, "reasoning_effort": "low", "max_tokens": 2500, "messages": history, "tools": tools}
	var e := http.request(URL, ["Authorization: Bearer " + key, "Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(body))
	if e != OK:
		said.emit("Could not reach the model (error %d)." % e)
		return null
	var r = await http.request_completed
	var text: String = r[3].get_string_from_utf8()
	if r[0] != HTTPRequest.RESULT_SUCCESS or r[1] != 200:
		if r[0] != HTTPRequest.RESULT_SUCCESS and text == "":
			return null   # cancelled
		said.emit("The model call failed (HTTP %d): %s" % [r[1], text.left(240)])
		return null
	var j = JSON.parse_string(text)
	if not (j is Dictionary) or not j.has("choices") or j["choices"].is_empty():
		said.emit("The model sent back something unreadable.")
		return null
	return j["choices"][0]["message"]


func plain(tool_name: String, args: Dictionary) -> String:
	var parts := []
	for k in args:
		var v = args[k]
		if v is float and v == floor(v):
			v = int(v)   # JSON numbers arrive as floats; show 450, not 450.0
		parts.append("%s %s" % [k, str(v)])
	return tool_name.replace("_", " ") + ("" if parts.is_empty() else " (" + ", ".join(parts) + ")")
