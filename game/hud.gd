extends CanvasLayer
## The manager's controls, built in code: clock, weather and figures on top, the AI console on
## the right, the plan and the what-if buttons along the bottom, and a details panel on the left
## for whatever was clicked in the yard. Every control calls the same tools the AI uses.

const Farm := preload("res://game/farm.gd")
const SKY_COLORS := {"clear": "ffd76a", "cloudy": "c5ccd6", "rain": "7fb6ff", "storm": "c69cff"}
const SKY_WORDS := {"clear": "Clear", "cloudy": "Cloudy", "rain": "Rain", "storm": "Storm"}
const HELP := """[b]Console[/b]
Type an order in your own words and press Enter. The steward reads the farm and acts through its tools.
/help  this list
/stop  cancel the steward's current work
/clear  clear the console
/ask on|off  ask before changing the farm
/pause, /speed slow|fast|fastest
/look <place>  overview, prepare, autoclaves, cooling, seeding, incubation, store, lab, sawdust, tank, or a container
/inspect <C3 | worker 2>  open details; click works too
/whatif <steamer | outbreak | humidifier | absent | heat | storm | power | water>
/numbers  where every number comes from
/restart
Keys: Enter types here, Esc leaves; Space pauses; 1 2 3 set the speed; wheel zooms; right-drag moves the view; 0 is the overview."""

var farm: Farm
var main
var steward
var clock: Label
var sky_label: RichTextLabel
var kpi := {}
var alert: Label
var log_box: RichTextLabel
var outlook: Label
var order_edit: LineEdit
var proposal: VBoxContainer
var proposal_text: Label
var busy_label: Label
var ask_toggle: CheckButton
var chart: Control
var spin := {}
var check := {}
var speed_buttons := []
var assume: PanelContainer
var assume_text: RichTextLabel
var inspector: PanelContainer
var insp_title: Label
var insp_body: RichTextLabel
var insp_scroll: ScrollContainer
var insp_rows: VBoxContainer
var insp_note: Label
var insp_what := ""
var insp_sig := ""
var seen_events := 0
var tick := 0.0


func setup(f: Farm, m, s) -> void:
	farm = f
	main = m
	steward = s
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_top(root)
	_build_side(root)
	_build_bottom(root)
	_build_inspector(root)
	_build_assumptions(root)
	steward.said.connect(func(t): say("Steward", t, "8fd694"))
	steward.proposed.connect(_on_proposed)
	steward.acted.connect(func(line, good): say("did" if good else "refused", line, "9fb4c8" if good else "e8a07a"))
	steward.finished.connect(_on_finished)
	say("Farm twin", "Press Enter and give the steward an order, or type /help. Click a container or a worker in the yard for details.", "c8c8c8")
	show_speed(main.speed_i)
	_update()


func _style(alpha := 0.88) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.065, 0.08, 0.1, alpha)
	sb.set_corner_radius_all(10)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.1)
	sb.set_content_margin_all(10)
	return sb


func _panel(root: Control, al: float, at: float, ar: float, ab: float, ol: float, ot: float, o_r: float, ob: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _style())
	p.anchor_left = al
	p.anchor_top = at
	p.anchor_right = ar
	p.anchor_bottom = ab
	p.offset_left = ol
	p.offset_top = ot
	p.offset_right = o_r
	p.offset_bottom = ob
	root.add_child(p)
	return p


func _text(parent: Control, text: String, size := 0, hex := "") -> Label:
	var l := Label.new()
	l.text = text
	if size > 0:
		l.add_theme_font_size_override("font_size", size)
	if hex != "":
		l.add_theme_color_override("font_color", Color(hex))
	parent.add_child(l)
	return l


func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _spin(parent: Control, key: String, text: String, top: int, step: int) -> void:
	_text(parent, text)
	var sb := SpinBox.new()
	sb.min_value = 0
	sb.max_value = top
	sb.step = step
	sb.value_changed.connect(_on_spin.bind(key))
	parent.add_child(sb)
	spin[key] = sb


func _check(parent: Control, key: String, text: String) -> void:
	var cb := CheckBox.new()
	cb.text = text
	cb.focus_mode = Control.FOCUS_NONE
	cb.toggled.connect(_on_check.bind(key))
	parent.add_child(cb)
	check[key] = cb


# ---------------------------------------------------------------- building

func _build_top(root: Control) -> void:
	var p := _panel(root, 0, 0, 1, 0, 8, 8, -8, 56)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 14)
	p.add_child(h)
	_text(h, "OINC Farm Twin", 19, "ffffff")
	clock = _text(h, "", 17, "ffe9a8")
	clock.custom_minimum_size.x = 122
	var names := ["Pause", "Slow", "Fast", "Fastest"]
	for i in names.size():
		var b := _button(h, names[i], main.set_speed.bind(i))
		b.toggle_mode = true
		speed_buttons.append(b)
	sky_label = RichTextLabel.new()
	sky_label.bbcode_enabled = true
	sky_label.fit_content = true
	sky_label.scroll_active = false
	sky_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	sky_label.custom_minimum_size = Vector2(210, 24)
	sky_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sky_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(sky_label)
	for key in ["cash", "picked", "power", "water", "next14"]:
		kpi[key] = _text(h, "")
	alert = Label.new()
	alert.anchor_right = 1.0
	alert.offset_left = 18
	alert.offset_top = 62
	alert.offset_right = -424
	alert.offset_bottom = 88
	alert.add_theme_color_override("font_color", Color(1.0, 0.8, 0.35))
	alert.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	alert.add_theme_constant_override("outline_size", 6)
	alert.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(alert)


func _build_side(root: Control) -> void:
	var p := _panel(root, 1, 0, 1, 1, -412, 64, -8, -122)
	var v := VBoxContainer.new()
	p.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	_text(head, "AI console", 18, "ffffff")
	_text(head, "  Muse Spark 1.3", 13, "8fd694")
	busy_label = _text(head, "", 13, "9ad4ff")
	ask_toggle = CheckButton.new()
	ask_toggle.text = "Ask me before changing the farm"
	ask_toggle.button_pressed = true
	ask_toggle.focus_mode = Control.FOCUS_NONE
	ask_toggle.toggled.connect(func(on): steward.ask_first = on)
	v.add_child(ask_toggle)
	chart = Control.new()
	chart.custom_minimum_size = Vector2(0, 92)
	chart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chart.draw.connect(_draw_chart)
	v.add_child(chart)
	outlook = _text(v, "", 13, "b9c6d6")
	outlook.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.selection_enabled = true
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.add_theme_font_size_override("normal_font_size", 15)
	log_box.add_theme_font_size_override("bold_font_size", 15)
	v.add_child(log_box)
	proposal = VBoxContainer.new()
	proposal.visible = false
	v.add_child(proposal)
	proposal_text = _text(proposal, "", 15, "ffd873")
	proposal_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var pr := HBoxContainer.new()
	proposal.add_child(pr)
	_button(pr, "Approve", _decide.bind(true))
	_button(pr, "Reject", _decide.bind(false))
	order_edit = LineEdit.new()
	order_edit.placeholder_text = "Enter: order the steward, or /help"
	order_edit.text_submitted.connect(_on_order)
	order_edit.gui_input.connect(_on_order_key)
	v.add_child(order_edit)


func _build_bottom(root: Control) -> void:
	var p := _panel(root, 0, 1, 1, 1, 8, -114, -8, -8)
	var v := VBoxContainer.new()
	p.add_child(v)
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 9)
	v.add_child(r1)
	_text(r1, "Plan", 0, "ffe9a8")
	_spin(r1, "target", "Bags a day", 5000, 50)
	_spin(r1, "prepare", "Workers: prepare", 50, 1)
	_spin(r1, "seeding", "seeding", 50, 1)
	_spin(r1, "harvest", "harvest", 50, 1)
	_check(r1, "auto_steam", "Auto steam")
	_check(r1, "auto_move_in", "Auto move-in")
	_button(r1, "Start steam", func(): _tool("start_steam", {}))
	_button(r1, "Order sawdust 5 t", func(): _tool("order_materials", {"sawdust_tonnes": 5}))
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 7)
	v.add_child(r2)
	_text(r2, "What if", 0, "ffe9a8")
	for item in [["Heat wave", "heat"], ["Storm", "storm"], ["Power cut", "power"], ["Water cut", "water"], ["Autoclaves down", "steamer"],
			["Outbreak", "outbreak"], ["Humidifier fails", "humidifier"], ["Workers absent", "absent"]]:
		_button(r2, item[0], _what_if.bind(item[1]))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r2.add_child(gap)
	_button(r2, "Numbers", _show_assumptions)
	_button(r2, "Restart", _restart)


func _build_inspector(root: Control) -> void:
	inspector = _panel(root, 0, 0, 0, 1, 8, 94, 372, -122)
	inspector.visible = false
	var v := VBoxContainer.new()
	inspector.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	insp_title = _text(head, "", 18, "ffffff")
	insp_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(head, "Close", func(): main.select(""))
	insp_body = RichTextLabel.new()
	insp_body.bbcode_enabled = true
	insp_body.fit_content = true
	insp_body.scroll_active = false
	insp_body.add_theme_font_size_override("normal_font_size", 14)
	insp_body.add_theme_font_size_override("bold_font_size", 14)
	v.add_child(insp_body)
	insp_scroll = ScrollContainer.new()
	insp_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	insp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(insp_scroll)
	insp_rows = VBoxContainer.new()
	insp_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	insp_scroll.add_child(insp_rows)
	insp_note = _text(v, "", 12, "8a93a0")
	insp_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART


func _build_assumptions(root: Control) -> void:
	assume = _panel(root, 0.5, 0.5, 0.5, 0.5, -460, -350, 460, 350)
	assume.add_theme_stylebox_override("panel", _style(0.97))
	assume.visible = false
	var v := VBoxContainer.new()
	assume.add_child(v)
	_text(v, "Where every number comes from", 18, "ffffff")
	assume_text = RichTextLabel.new()
	assume_text.bbcode_enabled = true
	assume_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(assume_text)
	_button(v, "Close", func(): assume.visible = false)


# ---------------------------------------------------------------- the console

func say(who: String, text: String, hex: String) -> void:
	log_box.append_text("[color=#%s][b]%s[/b][/color]  %s\n" % [hex, who, text.replace("[", "[lb]")])


func show_speed(i: int) -> void:
	for n in speed_buttons.size():
		speed_buttons[n].set_pressed_no_signal(n == i)


func focus_console(prefix: String) -> void:
	order_edit.grab_focus()
	if prefix != "":
		order_edit.text = prefix
		order_edit.caret_column = prefix.length()


func _on_order_key(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		order_edit.release_focus()


func _on_order(text: String) -> void:
	text = text.strip_edges()
	order_edit.clear()
	if text == "":
		order_edit.release_focus()   # an empty Enter hands the keys back to the yard
		return
	if text.begins_with("/"):
		_command(text)
		return
	say("You", text, "ffffff")
	busy_label.text = "  thinking"
	steward.ask(text)


func _command(text: String) -> void:
	var parts := text.substr(1).split(" ", false)
	var cmd: String = parts[0].to_lower() if parts.size() > 0 else "help"
	var arg: String = " ".join(parts.slice(1)).strip_edges()
	say("You", text, "9aa4b2")
	match cmd:
		"help":
			log_box.append_text(HELP + "\n")
		"clear":
			log_box.clear()
		"stop":
			steward.stop()
			proposal.visible = false
			say("Farm twin", "Stopped.", "c8c8c8")
		"ask":
			ask_toggle.button_pressed = arg.to_lower() != "off"
			say("Farm twin", "The steward %s before changing the farm." % ("asks" if ask_toggle.button_pressed else "does not ask"), "c8c8c8")
		"pause":
			main.set_speed(0)
		"speed", "look", "inspect", "whatif":
			var tool_name: String = {"speed": "set_speed", "look": "look_at", "inspect": "inspect", "whatif": "what_if"}[cmd]
			var arg_name: String = {"speed": "speed", "look": "place", "inspect": "name", "whatif": "kind"}[cmd]
			var out: Dictionary = main.scene_tool(tool_name, {arg_name: arg})
			say("Farm twin", str(out.get("result", out.get("error", ""))), "c8c8c8" if out["ok"] else "e8a07a")
		"numbers":
			_show_assumptions()
		"restart":
			_restart()
		_:
			say("Farm twin", "There is no command /%s. Type /help." % cmd, "e8a07a")


func _on_proposed(lines: Array) -> void:
	proposal_text.text = "The steward wants to:\n- " + "\n- ".join(lines)
	proposal.visible = true
	busy_label.text = "  waiting for you"


func _decide(yes: bool) -> void:
	proposal.visible = false
	busy_label.text = "  working"
	steward.decide(yes)


func _on_finished() -> void:
	busy_label.text = ""
	proposal.visible = false


# ---------------------------------------------------------------- the manager's own buttons

func _tool(tool_name: String, args: Dictionary) -> void:
	var out: Dictionary = farm.call_tool(tool_name, args)
	say("You", steward.plain(tool_name, args) + ": " + str(out.get("result", out.get("error", ""))), "ffffff" if out["ok"] else "e8a07a")
	_update()


func _on_spin(_value: float, key: String) -> void:
	if key == "target":
		_tool("set_target", {"bags": int(spin["target"].value)})
	else:
		_tool("assign_workers", {"prepare": int(spin["prepare"].value), "seeding": int(spin["seeding"].value), "harvest": int(spin["harvest"].value)})


func _on_check(_on: bool, _key: String) -> void:
	_tool("set_policy", {"auto_steam": check["auto_steam"].button_pressed, "auto_move_in": check["auto_move_in"].button_pressed})


func _what_if(kind: String) -> void:
	say("You", farm.fault(kind), "ffd27a")


func _restart() -> void:
	main.restart()
	steward.stop()
	steward.reset()
	log_box.clear()
	seen_events = 0
	show_inspector("")
	say("Farm twin", "Restarted with a full pipeline.", "c8c8c8")


func _show_assumptions() -> void:
	var t := "[b]Layout[/b]: OINC Phase 1 layout drawing, 26 Oct 2026.\n\n[b]Farm settings[/b] (data/farm.json)\n"
	for key in farm.order:
		var m: Dictionary = farm.meta[key]
		var src: String = m["source"]
		var hex := "e0b060" if src.begins_with("assumed") else "8fd694"
		t += "%s: [b]%s[/b]  [color=#%s](%s)[/color]\n" % [m["label"], str(farm.c[key]), hex, src]
	var d: Dictionary = farm.fit["data"]
	t += "\n[b]Fruiting room climate[/b]: daily pattern fitted from %s's sensor log, %s readings, %s to %s. [color=#8fd694](fitted)[/color]\n" % [
		farm.fit["device"], main.num(d["kept_after_cleaning"]), d["from"], d["to"]]
	var ch: Dictionary = farm.fit["check"]
	t += "Checked on days it had not seen: temperature within %.1f C and humidity within %.1f %%RH one hour ahead; %.1f C and %.1f %%RH six hours ahead. CO2 is not predictable from this log.\n" % [
		float(ch["temperature"]["1h"]["model_mae"]), float(ch["humidity"]["1h"]["model_mae"]), float(ch["temperature"]["6h"]["model_mae"]), float(ch["humidity"]["6h"]["model_mae"])]
	t += "\n[b]Weather[/b]: [color=#e0b060](assumed)[/color] A made-up sky for a hot, wet town, not Sibu's records. How weather pushes on rooms, losses and power is assumed too."
	t += "\n[b]What each actuator does to a room[/b]: [color=#e0b060](assumed)[/color] The control log does not record what ran when. A step test at the farm would replace these."
	assume_text.text = t
	assume.visible = true


# ---------------------------------------------------------------- the details panel

func show_inspector(what: String) -> void:
	insp_what = what
	insp_sig = ""
	inspector.visible = what != ""
	_fill_inspector()


func _fill_inspector() -> void:
	if insp_what == "":
		return
	if insp_what.begins_with("worker:"):
		var info: Dictionary = main.worker_info(int(insp_what.substr(7)))
		insp_title.text = info["name"]
		insp_body.text = "[b]Now[/b]: %s\n[b]Job today[/b]: %s\n[b]Shift[/b]: %s, %d hours worked so far\n[b]Output[/b]: %s\n[b]Wage[/b]: RM %.0f a day" % [
			info["doing"], info["job"], info["shift"], int(info["hours"]), info["output"] if info["output"] != "" else "nothing counted yet today", float(info["wage"])]
		insp_note.text = "The simulation tracks jobs, not named people. Output is this worker's share of the station's output today."
		if insp_sig != "worker":
			insp_sig = "worker"
			for child in insp_rows.get_children():
				child.queue_free()
		return
	var k = farm._room(insp_what.substr(5))
	if k == null:
		return
	var c: Dictionary = farm.c
	var on := []
	if float(k["duty"]) > 0.03:
		on.append("humidifier %d%% of the hour" % int(round(float(k["duty"]) * 100.0)))
	if float(k["ac"]) > 0.03:
		on.append("aircond %d%%" % int(round(float(k["ac"]) * 100.0)))
	for a in ["vent1", "vent2", "spray", "light"]:
		if k["act"][a]:
			on.append(a)
	var good: bool = farm.in_range(k)
	var t := "[b]Room now[/b]: %.0f %%RH, %.1f C, CO2 %s ppm  [color=#%s]%s[/color]\n" % [float(k["humidity"]), float(k["temperature"]), main.num(k["CO2"]),
		"8fd694" if good else "f0b060", "in range" if good else "out of range"]
	t += "[b]Running[/b]: %s  (%s)\n" % [", ".join(on) if not on.is_empty() else "nothing", "automation" if k["auto"] else "set by hand"]
	if int(k["fault_hours"]) > 0:
		t += "[color=#ff8a7a][b]Fault[/b]: humidifier failed, %d h to repair[/color]\n" % int(k["fault_hours"])
	t += "[b]Bongkah[/b]: %s of %s, %s kg ripe\n" % [main.num(farm.container_bags(k)), main.num(c["container_capacity"]), main.num(farm.container_ripe(k))]
	var flushes: int = c["flush_yield_g"].size()
	for b in k["batches"]:
		var share: int = 100 if int(b["hours"]) == 0 else int(round(100.0 * float(b["good"]) / float(b["hours"])))
		var next := "spent, leaving soon" if int(b["flush"]) >= flushes else "flush %d of %d on day %d" % [int(b["flush"]) + 1, flushes, int(b["next_flush_day"])]
		t += "  Batch %d: %s bags, in since day %d, %s, in range %d%%%s\n" % [int(b["id"]), main.num(b["bags"]), int(b["day_in"]), next, share,
			"" if float(b["ripe_kg"]) < 0.5 else ", [color=#ffe9a8]%s kg ripe[/color]" % main.num(b["ripe_kg"])]
	insp_title.text = "%s  farm container" % k["name"]
	insp_body.text = t + "[b]Operations log[/b]"
	insp_note.text = "Pictures are drawn views of the simulated racks, not photos."
	# The log rows are rebuilt only when the log changes.
	var log: Array = k["log"]
	var sig := "%s:%d:%d" % [k["name"], log.size(), int(log[-1]["hour"]) if not log.is_empty() else 0]
	if sig == insp_sig:
		return
	insp_sig = sig
	for child in insp_rows.get_children():
		child.queue_free()
	var shown: Array = log.slice(maxi(log.size() - 14, 0))
	shown.reverse()
	for e in shown:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		insp_rows.add_child(row)
		var pic := Control.new()
		pic.custom_minimum_size = Vector2(76, 54)
		pic.draw.connect(_draw_photo.bind(pic, str(e["kind"]), int(e["hour"]) * 31 + str(e["text"]).length()))
		row.add_child(pic)
		var l := _text(row, "%s\n%s: %s" % [farm.stamp(int(e["hour"])), e["kind"], e["text"]], 13)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _draw_photo(pic: Control, kind: String, salt: int) -> void:
	# A drawn view of the simulated racks for one log entry. It is not a photograph.
	var w: float = pic.size.x
	var h: float = pic.size.y
	var r := RandomNumberGenerator.new()
	r.seed = salt
	pic.draw_rect(Rect2(0, 0, w, h), Color(0.13, 0.15, 0.17))
	match kind:
		"Harvest":
			pic.draw_rect(Rect2(w * 0.1, h * 0.48, w * 0.8, h * 0.42), Color(0.24, 0.42, 0.72))
			for i in 10:
				pic.draw_circle(Vector2(w * (0.17 + 0.073 * i), h * (0.42 + r.randf() * 0.14)), h * 0.13, Color(0.84, 0.82, 0.78).darkened(r.randf() * 0.15))
		"Removal":
			for i in 9:
				pic.draw_circle(Vector2(w * (0.12 + 0.095 * i), h * (0.6 + (i % 2) * 0.14)), h * 0.12, Color(0.44, 0.35, 0.25))
		"Fault", "Repair", "Climate":
			pic.draw_rect(Rect2(w * 0.3, h * 0.45, w * 0.4, h * 0.42), Color(0.78, 0.8, 0.84) if kind != "Fault" else Color(0.85, 0.35, 0.3))
			if kind != "Fault":
				for i in 7:
					pic.draw_circle(Vector2(w * (0.36 + r.randf() * 0.28), h * (0.12 + r.randf() * 0.3)), h * 0.06, Color(1, 1, 1, 0.5))
		_:
			for row in 3:
				var y: float = h * (0.22 + row * 0.29)
				pic.draw_line(Vector2(w * 0.05, y + h * 0.12), Vector2(w * 0.95, y + h * 0.12), Color(0.4, 0.42, 0.45), 2.0)
				for col in 7:
					var x: float = w * (0.11 + col * 0.13)
					pic.draw_circle(Vector2(x, y), h * 0.095, Color(0.92, 0.9, 0.82))
					if kind == "Inspection" and r.randf() < 0.6:
						pic.draw_circle(Vector2(x + w * 0.02, y - h * 0.06), h * 0.075, Color(0.62, 0.6, 0.58))
						pic.draw_circle(Vector2(x - w * 0.02, y - h * 0.03), h * 0.06, Color(0.7, 0.68, 0.65))


# ---------------------------------------------------------------- showing

func _process(delta: float) -> void:
	tick += delta
	if tick > 0.25:
		tick = 0.0
		_update()


func _update() -> void:
	clock.text = "Day %d  %02d:00" % [farm.day(), farm.hod()]
	var w: Dictionary = farm.weather
	sky_label.text = "[color=#%s][b]%s[/b][/color]  %.0f C  %.0f%% RH%s" % [SKY_COLORS[w["state"]], SKY_WORDS[w["state"]], float(w["temp"]), float(w["humidity"]),
		"" if float(w["rain_mm"]) <= 0.0 else "  %.0f mm/h" % float(w["rain_mm"])]
	var t: Dictionary = farm.totals
	kpi["cash"].text = "Cash RM %s" % main.num(farm.cash())
	kpi["picked"].text = "Picked %s kg" % main.num(t["kg"])
	kpi["power"].text = "Power %s kWh today" % main.num(farm.today["kwh"])
	kpi["water"].text = "Water %s L today" % main.num(farm.today["water_l"])
	var f14 := 0.0
	for v in farm.forecast(14):
		f14 += float(v)
	kpi["next14"].text = "Next 14 days %s kg" % main.num(f14)
	var b: String = farm.bottleneck()
	var parts := []
	if b != "None":
		parts.append("Bottleneck: " + b)
	for fault in farm.faults():
		parts.append(fault)
	alert.text = "   ".join(parts)
	var looks := []
	for o in farm.weather_outlook():
		var wet: int = int(o["rain_hours"]) + int(o["storm_hours"])
		looks.append("%s: %s, max %.0f C" % [o["when"], "dry" if wet == 0 else ("%d h rain" % wet) + ("" if int(o["storm_hours"]) == 0 else " with storm"), float(o["max_temp"])])
	outlook.text = "Outlook  " + "  |  ".join(looks) + "\nUtilities so far: RM %.2f per kg picked" % farm.utility_cost_per_kg()
	for key in ["prepare", "seeding", "harvest"]:
		if not spin[key].get_line_edit().has_focus():
			spin[key].set_value_no_signal(int(farm.alloc[key]))
	if not spin["target"].get_line_edit().has_focus():
		spin["target"].set_value_no_signal(farm.target)
	check["auto_steam"].set_pressed_no_signal(farm.auto_steam)
	check["auto_move_in"].set_pressed_no_signal(farm.auto_move_in)
	# New farm events go into the console.
	var fresh: int = mini(farm.events_total - seen_events, farm.events.size())
	seen_events = farm.events_total
	for e in farm.events.slice(farm.events.size() - maxi(fresh, 0)):
		log_box.append_text("[color=#8a8f98]%s  %s[/color]\n" % [farm.stamp(int(e["hour"])), str(e["text"]).replace("[", "[lb]")])
	chart.queue_redraw()
	_fill_inspector()


func _draw_chart() -> void:
	var f: Array = farm.forecast(30)
	var w: float = chart.size.x
	var h: float = chart.size.y
	chart.draw_rect(Rect2(0, 0, w, h), Color(1, 1, 1, 0.04))
	var top := 1.0
	for v in f:
		top = maxf(top, float(v))
	var bw: float = (w - 12.0) / f.size()
	for i in f.size():
		var bh: float = (h - 30.0) * float(f[i]) / top
		chart.draw_rect(Rect2(6.0 + i * bw, h - 6.0 - bh, bw - 2.0, bh), Color(0.56, 0.84, 0.47))
	chart.draw_string(ThemeDB.fallback_font, Vector2(8, 17), "Harvest forecast, next 30 days. Peak %d kg a day" % int(top), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(0.85, 0.9, 0.95))
