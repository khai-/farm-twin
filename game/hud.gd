extends CanvasLayer
## The manager's controls, built in code: clock and figures on top, the steward on the right,
## the plan and the what-if buttons along the bottom. Every control calls the same tools the AI uses.

const Farm := preload("res://game/farm.gd")

var farm: Farm
var main
var steward
var clock: Label
var kpi := {}
var alert: Label
var log_box: RichTextLabel
var order_edit: LineEdit
var proposal: VBoxContainer
var proposal_text: Label
var busy_label: Label
var chart: Control
var spin := {}
var check := {}
var speed_buttons := []
var assume: PanelContainer
var assume_text: RichTextLabel
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
	_build_chart(root)
	_build_assumptions(root)
	steward.said.connect(func(t): say("Steward", t, "8fd694"))
	steward.proposed.connect(_on_proposed)
	steward.acted.connect(func(line, good): say("did" if good else "refused", line, "9fb4c8" if good else "e8a07a"))
	steward.finished.connect(func(): busy_label.text = "")
	say("Farm twin", "Type an order for the steward below, or use the plan controls. Space pauses; 1, 2 and 3 set the speed.", "c8c8c8")
	show_speed(main.speed_i)
	_update()


func _place(n: Control, al: float, at: float, ar: float, ab: float, ol: float, ot: float, o_r: float, ob: float) -> void:
	n.anchor_left = al
	n.anchor_top = at
	n.anchor_right = ar
	n.anchor_bottom = ab
	n.offset_left = ol
	n.offset_top = ot
	n.offset_right = o_r
	n.offset_bottom = ob


func _text(parent: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
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
	var p := PanelContainer.new()
	_place(p, 0, 0, 1, 0, 8, 8, -8, 50)
	root.add_child(p)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	p.add_child(h)
	var title := _text(h, "  OINC Farm Twin")
	title.add_theme_font_size_override("font_size", 18)
	clock = _text(h, "")
	clock.custom_minimum_size.x = 118
	var names := ["Pause", "Slow", "Fast", "Fastest"]
	for i in names.size():
		var b := _button(h, names[i], main.set_speed.bind(i))
		b.toggle_mode = true
		speed_buttons.append(b)
	for key in ["cash", "picked", "incubating", "fruiting", "removed", "next14"]:
		kpi[key] = _text(h, "")
	alert = Label.new()
	_place(alert, 0, 0, 1, 0, 18, 58, -420, 84)
	alert.add_theme_color_override("font_color", Color(1.0, 0.8, 0.35))
	alert.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	alert.add_theme_constant_override("outline_size", 6)
	root.add_child(alert)


func _build_side(root: Control) -> void:
	var p := PanelContainer.new()
	_place(p, 1, 0, 1, 1, -408, 58, -8, -8)
	root.add_child(p)
	var v := VBoxContainer.new()
	p.add_child(v)
	var title := _text(v, "Steward (Muse Spark 1.3)")
	title.add_theme_font_size_override("font_size", 17)
	var row := HBoxContainer.new()
	v.add_child(row)
	var ask := CheckButton.new()
	ask.text = "Ask me before changing anything"
	ask.button_pressed = true
	ask.focus_mode = Control.FOCUS_NONE
	ask.toggled.connect(func(on): steward.ask_first = on)
	row.add_child(ask)
	busy_label = _text(row, "")
	busy_label.add_theme_color_override("font_color", Color(0.6, 0.85, 1.0))
	log_box = RichTextLabel.new()
	log_box.bbcode_enabled = true
	log_box.scroll_following = true
	log_box.selection_enabled = true
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(log_box)
	proposal = VBoxContainer.new()
	proposal.visible = false
	v.add_child(proposal)
	proposal_text = _text(proposal, "")
	proposal_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	proposal_text.add_theme_color_override("font_color", Color(1.0, 0.85, 0.45))
	var pr := HBoxContainer.new()
	proposal.add_child(pr)
	_button(pr, "Approve", _decide.bind(true))
	_button(pr, "Reject", _decide.bind(false))
	order_edit = LineEdit.new()
	order_edit.placeholder_text = "Order the steward, e.g. we need 120 kg a day"
	order_edit.text_submitted.connect(_on_order)
	v.add_child(order_edit)


func _build_bottom(root: Control) -> void:
	var p := PanelContainer.new()
	_place(p, 0, 1, 1, 1, 8, -96, -416, -8)
	root.add_child(p)
	var v := VBoxContainer.new()
	p.add_child(v)
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 10)
	v.add_child(r1)
	_text(r1, " Plan:")
	_spin(r1, "target", "Bags per day", 5000, 50)
	_spin(r1, "prepare", "Workers on prepare", 50, 1)
	_spin(r1, "seeding", "seeding", 50, 1)
	_spin(r1, "harvest", "harvest", 50, 1)
	_check(r1, "auto_steam", "Auto steam")
	_check(r1, "auto_move_in", "Auto move-in")
	_button(r1, "Start steam", func(): _tool("start_steam", {}))
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 10)
	v.add_child(r2)
	_text(r2, " What if:")
	_button(r2, "Autoclaves break down", func(): _what_if("steamer"))
	_button(r2, "Contamination outbreak", func(): _what_if("outbreak"))
	_button(r2, "C1 humidifier fails", func(): _what_if("humidifier"))
	_button(r2, "Two workers absent", func(): _what_if("absent"))
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r2.add_child(gap)
	_button(r2, "Where the numbers come from", _show_assumptions)
	_button(r2, "Restart", _restart)


func _build_chart(root: Control) -> void:
	chart = Control.new()
	_place(chart, 0, 1, 0, 1, 8, -236, 396, -104)
	chart.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chart.draw.connect(_draw_chart)
	root.add_child(chart)


func _build_assumptions(root: Control) -> void:
	assume = PanelContainer.new()
	_place(assume, 0.5, 0.5, 0.5, 0.5, -450, -340, 450, 340)
	assume.visible = false
	root.add_child(assume)
	var v := VBoxContainer.new()
	assume.add_child(v)
	var t := _text(v, "Where every number comes from")
	t.add_theme_font_size_override("font_size", 18)
	assume_text = RichTextLabel.new()
	assume_text.bbcode_enabled = true
	assume_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(assume_text)
	_button(v, "Close", func(): assume.visible = false)


# ---------------------------------------------------------------- acting

func say(who: String, text: String, hex: String) -> void:
	log_box.append_text("[color=#%s][b]%s[/b][/color]  %s\n" % [hex, who, text.replace("[", "[lb]")])


func show_speed(i: int) -> void:
	for n in speed_buttons.size():
		speed_buttons[n].set_pressed_no_signal(n == i)


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
	steward.reset()
	log_box.clear()
	seen_events = 0
	say("Farm twin", "Restarted with a full pipeline.", "c8c8c8")


func _on_order(text: String) -> void:
	if text.strip_edges() == "":
		return
	order_edit.clear()
	say("You", text, "ffffff")
	busy_label.text = "thinking"
	steward.ask(text)


func _on_proposed(lines: Array) -> void:
	proposal_text.text = "The steward wants to:\n- " + "\n- ".join(lines)
	proposal.visible = true
	busy_label.text = "waiting for you"


func _decide(yes: bool) -> void:
	proposal.visible = false
	busy_label.text = "working"
	steward.decide(yes)


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
	t += "\n[b]What each actuator does to a room[/b]: [color=#e0b060](assumed)[/color] The control log does not record what ran when. A step test at the farm would replace these."
	assume_text.text = t
	assume.visible = true


# ---------------------------------------------------------------- showing

func _process(delta: float) -> void:
	tick += delta
	if tick > 0.25:
		tick = 0.0
		_update()


func _update() -> void:
	clock.text = "Day %d  %02d:00" % [farm.day(), farm.hod()]
	var t: Dictionary = farm.totals
	kpi["cash"].text = "Cash RM %s" % main.num(farm.cash())
	kpi["picked"].text = "Picked %s kg" % main.num(t["kg"])
	kpi["incubating"].text = "Incubating %s" % main.num(farm.incubation_bags())
	kpi["fruiting"].text = "Fruiting %s" % main.num(farm.fruiting_bags())
	kpi["removed"].text = "Removed %.1f%%" % (100.0 * float(t["removed"]) / maxf(float(t["seeded"]), 1.0))
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
	for key in ["prepare", "seeding", "harvest"]:
		if not spin[key].get_line_edit().has_focus():
			spin[key].set_value_no_signal(int(farm.alloc[key]))
	if not spin["target"].get_line_edit().has_focus():
		spin["target"].set_value_no_signal(farm.target)
	check["auto_steam"].set_pressed_no_signal(farm.auto_steam)
	check["auto_move_in"].set_pressed_no_signal(farm.auto_move_in)
	# New farm events go into the log.
	var fresh: int = mini(farm.events_total - seen_events, farm.events.size())
	seen_events = farm.events_total
	for e in farm.events.slice(farm.events.size() - maxi(fresh, 0)):
		log_box.append_text("[color=#8a8f98]%s  %s[/color]\n" % [farm.stamp(int(e["hour"])), str(e["text"]).replace("[", "[lb]")])
	chart.queue_redraw()


func _draw_chart() -> void:
	var f: Array = farm.forecast(30)
	var w: float = chart.size.x
	var h: float = chart.size.y
	chart.draw_rect(Rect2(0, 0, w, h), Color(0.08, 0.09, 0.11, 0.78))
	var top := 1.0
	for v in f:
		top = maxf(top, float(v))
	var bw: float = (w - 16.0) / f.size()
	for i in f.size():
		var bh: float = (h - 36.0) * float(f[i]) / top
		chart.draw_rect(Rect2(8.0 + i * bw, h - 8.0 - bh, bw - 2.0, bh), Color(0.56, 0.84, 0.47))
	chart.draw_string(ThemeDB.fallback_font, Vector2(10, 19), "Harvest forecast, next 30 days. Peak %d kg a day" % int(top), HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
