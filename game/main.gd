extends Node3D
## OINC Farm Twin. A manager's simulation of OINC's Sibu factory: the bag production line,
## incubation and fruiting, with an AI steward that acts only through the farm's tools.
## The yard follows OINC's Phase 1 layout drawing of 26 Oct 2026 (metres; x across the page, z down it).
## Every model is made in code, so there are no art files.
## Headless checks: `-- --selftest` runs 120 days and checks the books; `-- --ask "..."` sends one
## order to the steward and prints what it does. `-- --shot file.png` saves a picture of the yard.

const Farm := preload("res://game/farm.gd")
const Steward := preload("res://game/steward.gd")
const Hud := preload("res://game/hud.gd")

const SPEEDS := [0.0, 2.0, 8.0, 48.0]   # simulated hours per second
const BAGS_PER_STACK := 108             # as read from the drawing: 864 bongkah on 8 stacks
const INC_ROOMS := [[-11.5, -16.1], [0.3, -16.1], [12.1, -16.1]]   # left and top edge of each incubation room
# The ten farm containers in the drawing's order: x, z, and whether the long side runs across the page.
const FARM_SPOTS := [[-6.9, 4.7, true], [-0.7, 4.7, true], [-8.7, 11.2, false], [-5.4, 11.2, false], [-2.2, 11.2, false],
	[1.1, 11.2, false], [4.4, 11.2, false], [7.7, 11.2, false], [10.9, 11.2, false], [14.1, 11.2, false]]
const DAY_SKY := Color(0.56, 0.74, 0.92)
const NIGHT_SKY := Color(0.05, 0.07, 0.14)
const BAG := Color(0.88, 0.83, 0.7)

var farm := Farm.new()
var hud
var steward
var speed_i := 1
var acc := 0.0
var place := {}
var text3d := {}
var roofs := {}
var ripe_marks := {}
var inc_stacks := []
var wait_stacks := []
var cool_stacks := []
var autoclaves := []
var crew := []
var carts := []
var sun: DirectionalLight3D
var env: Environment
var tick := 0.0
var shot_path := ""
var shot_wait := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	farm.load_data("res://data")
	if args.has("--selftest"):
		get_tree().quit(_selftest())
		return
	_build_world()
	steward = Steward.new()
	steward.farm = farm
	add_child(steward)
	hud = Hud.new()
	add_child(hud)
	hud.setup(farm, self, steward)
	var i := args.find("--shot")
	if i >= 0 and i + 1 < args.size():
		shot_path = args[i + 1]
		shot_wait = 2.5
	i = args.find("--ask")
	if i >= 0 and i + 1 < args.size():
		steward.ask_first = false
		steward.said.connect(func(t): print("STEWARD: ", t))
		steward.acted.connect(func(line, good): print("  did: " if good else "  refused: ", line))
		steward.finished.connect(func(): get_tree().quit())
		steward.ask(args[i + 1])
	_refresh()


func set_speed(i: int) -> void:
	speed_i = clampi(i, 0, SPEEDS.size() - 1)
	if hud != null:
		hud.show_speed(speed_i)


func restart() -> void:
	farm.reset()
	acc = 0.0
	for cart in carts:
		cart["node"].queue_free()
	carts = []
	_refresh()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				set_speed(1 if speed_i == 0 else 0)
			KEY_1:
				set_speed(1)
			KEY_2:
				set_speed(2)
			KEY_3:
				set_speed(3)


func _process(delta: float) -> void:
	var speed: float = SPEEDS[speed_i]
	if speed > 0.0:
		acc += delta * speed
		var n := 0
		while acc >= 1.0 and n < 60:
			farm.step()
			acc -= 1.0
			n += 1
		if n == 60:
			acc = 0.0
	_animate(delta)
	tick += delta
	if tick > 0.2:
		tick = 0.0
		_refresh()
	if shot_path != "":
		shot_wait -= delta
		if shot_wait <= 0.0:
			get_viewport().get_texture().get_image().save_png(shot_path)
			shot_path = ""
			get_tree().quit()


# ---------------------------------------------------------------- building the yard

func _mat(color: Color, alpha := 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color.r, color.g, color.b, alpha)
	m.roughness = 0.9
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _box(size: Vector3, pos: Vector3, color: Color, alpha := 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = _mat(color, alpha)
	mi.position = pos
	add_child(mi)
	return mi


func _block(size: Vector3, x: float, z: float, color: Color, alpha := 1.0) -> MeshInstance3D:
	# A box standing on the ground at x, z.
	return _box(size, Vector3(x, size.y / 2.0 + 0.1, z), color, alpha)


func _label(key: String, pos: Vector3, text := "", font := 52) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font
	l.pixel_size = 0.0135
	l.outline_size = 14
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = true
	l.outline_modulate = Color(0, 0, 0, 0.9)
	l.position = pos
	add_child(l)
	text3d[key] = l
	return l


func _room(cx: float, cz: float, sx: float, sz: float, color: Color) -> void:
	# A room seen from above: tinted floor and low walls, open toward the yard.
	_box(Vector3(sx, 0.06, sz), Vector3(cx, 0.13, cz), color)
	var wall := Color(0.84, 0.86, 0.88)
	_box(Vector3(sx, 1.2, 0.15), Vector3(cx, 0.7, cz - sz / 2.0), wall)
	_box(Vector3(0.15, 1.2, sz), Vector3(cx - sx / 2.0, 0.7, cz), wall)
	_box(Vector3(0.15, 1.2, sz), Vector3(cx + sx / 2.0, 0.7, cz), wall)


func _build_world() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = DAY_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.82, 0.9)
	env.ambient_light_energy = 0.7
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-58.0, -32.0, 0.0)
	sun.shadow_enabled = true
	add_child(sun)
	var cam := Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	cam.look_at_from_position(Vector3(9.0, 49.0, 39.5), Vector3(9.0, 0.0, 1.5), Vector3.UP)
	cam.current = true

	# Ground: grass land, the building's floor slab, and the roofed strip along the bottom of the drawing.
	_box(Vector3(170.0, 0.1, 130.0), Vector3(0.0, -0.05, 0.0), Color(0.3, 0.44, 0.26))
	_box(Vector3(47.6, 0.1, 31.5), Vector3(0.1, 0.05, -0.35), Color(0.66, 0.66, 0.64))
	_box(Vector3(49.0, 0.1, 6.0), Vector3(-0.6, 0.05, 18.4), Color(0.58, 0.57, 0.54))

	# Top of the drawing: the store room and three incubation rooms of bongkah stacks.
	_room(-17.65, -12.15, 11.9, 7.9, Color(0.6, 0.62, 0.66))
	_label("packing", Vector3(-17.65, 2.6, -12.4))
	for r in INC_ROOMS.size():
		_room(float(INC_ROOMS[r][0]) + 5.8, -12.15, 11.6, 7.9, Color(0.5, 0.56, 0.5))
		for row in 5:
			for col in 6:
				var x: float = float(INC_ROOMS[r][0]) + 1.36 + col * 1.7
				var z: float = float(INC_ROOMS[r][1]) + 1.0 + row * 1.35
				for level in 2:
					var s := _box(Vector3(1.4, 1.4, 1.05), Vector3(x, 0.85 + level * 1.45, z), BAG.lightened(0.08 * level))
					s.visible = false
					inc_stacks.append(s)
	_label("incubation", Vector3(6.1, 5.0, -12.6))

	# Middle: the two-floor cooling room (Type A) joined to the seeding room (Type B).
	_block(Vector3(6.0, 5.6, 6.0), -6.9, -0.1, Color(0.72, 0.86, 0.96), 0.28)
	for i in 8:
		var s := _box(Vector3(1.05, 1.4, 1.4), Vector3(-9.1 + (i % 4) * 1.35, 0.85 + (i / 4) * 1.45, 1.8), BAG)
		s.visible = false
		cool_stacks.append(s)
	_label("cooling", Vector3(-6.9, 7.0, -0.6))
	_block(Vector3(6.0, 2.8, 6.0), -0.9, -0.1, Color(0.93, 0.93, 0.86), 0.45)
	_label("seeding", Vector3(-0.9, 4.2, -0.6))

	# The farm containers (Type C and Type D), 6 m by 3 m.
	for i in farm.containers.size():
		var spot: Array = FARM_SPOTS[i % FARM_SPOTS.size()]
		var along_x: bool = spot[2]
		var size := Vector3(6.0, 2.8, 3.0) if along_x else Vector3(3.0, 2.8, 6.0)
		var cname: String = farm.containers[i]["name"]
		_block(size, spot[0], spot[1], Color(0.9, 0.9, 0.88))
		roofs[cname] = _box(Vector3(size.x - 0.3, 0.12, size.z - 0.3), Vector3(spot[0], 2.97, spot[1]), Color(0.5, 0.5, 0.5))
		var mark := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 0.7
		mark.mesh = sm
		mark.material_override = _mat(Color(0.97, 0.96, 0.92))
		mark.position = Vector3(spot[0], 3.3, spot[1])
		mark.visible = false
		add_child(mark)
		ripe_marks[cname] = mark
		_label(cname, Vector3(spot[0], 4.3, spot[1]), "", 38)
		place[cname] = Vector3(spot[0], 0.0, 6.95 if along_x else 7.6)

	# Left: two autoclaves on a track, with the steam generator.
	var steel := Color(0.62, 0.66, 0.7)
	autoclaves.append(_block(Vector3(2.16, 1.86, 8.84), -20.1, 2.7, steel))
	autoclaves.append(_block(Vector3(2.16, 1.86, 4.88), -15.5, 4.4, steel))
	_box(Vector3(1.6, 0.05, 8.2), Vector3(-20.1, 0.13, 11.3), Color(0.3, 0.3, 0.32))
	_block(Vector3(1.5, 2.3, 2.23), -17.9, 0.6, Color(0.76, 0.38, 0.28))
	for i in 8:
		var s := _box(Vector3(1.05, 1.4, 1.4), Vector3(-20.1 + (i / 4) * 1.9, 0.85, 8.6 + (i % 4) * 1.7), BAG)
		s.visible = false
		wait_stacks.append(s)
	_label("steamer", Vector3(-18.6, 4.0, 2.4))
	_block(Vector3(1.2, 1.4, 2.2), -13.2, 8.0, Color(0.86, 0.26, 0.2))   # forklift

	# Bottom, under the roof: sawdust, mixers, and the robotic arm with bagger.
	_box(Vector3(24.5, 0.05, 5.5), Vector3(8.3, 0.13, 18.6), Color(0.74, 0.62, 0.42))
	for hx in [1.0, 8.0, 15.5]:
		var heap := MeshInstance3D.new()
		var hm := SphereMesh.new()
		hm.radius = 2.6
		hm.height = 2.6
		heap.mesh = hm
		heap.material_override = _mat(Color(0.7, 0.56, 0.36))
		heap.position = Vector3(hx, 0.1, 18.6)
		add_child(heap)
	_label("sawdust", Vector3(8.3, 2.6, 18.9), "Sawdust refill area\n25 tonnes", 40)
	_block(Vector3(1.08, 1.0, 2.6), -8.7, 18.3, Color(0.36, 0.5, 0.7))
	_block(Vector3(1.08, 1.0, 2.6), -6.7, 18.3, Color(0.36, 0.5, 0.7))
	_block(Vector3(1.8, 0.9, 0.9), -7.9, 20.4, Color(0.3, 0.42, 0.6))
	_block(Vector3(2.7, 1.21, 1.22), -13.4, 17.5, Color(0.92, 0.76, 0.2))
	_box(Vector3(0.25, 1.6, 0.25), Vector3(-12.4, 2.0, 17.5), Color(0.92, 0.76, 0.2))
	_box(Vector3(1.6, 0.22, 0.22), Vector3(-13.1, 2.8, 17.5), Color(0.92, 0.76, 0.2))
	_block(Vector3(1.6, 1.5, 1.4), -23.6, 16.6, steel)   # the existing steamer
	_label("prepare", Vector3(-11.4, 3.6, 19.4))

	# Around: temporary lab and office, the worker quarter, toilets, the water tank.
	_block(Vector3(5.9, 2.8, 2.35), 12.4, 1.6, Color(0.56, 0.72, 0.92))
	_block(Vector3(5.9, 2.8, 2.35), 12.4, 3.95, Color(0.62, 0.66, 0.76))
	_label("lab", Vector3(12.4, 4.2, 1.4))
	_block(Vector3(2.35, 2.8, 5.9), -27.2, 10.5, Color(0.68, 0.62, 0.52))
	_block(Vector3(1.1, 2.8, 1.3), -27.7, 1.3, Color(0.8, 0.8, 0.82))
	_block(Vector3(1.1, 2.8, 1.3), -27.7, 5.5, Color(0.8, 0.8, 0.82))
	var tank := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = 1.5
	tm.bottom_radius = 1.5
	tm.height = 2.6
	tank.mesh = tm
	tank.material_override = _mat(Color(0.3, 0.45, 0.6))
	tank.position = Vector3(-22.7, 1.4, -20.6)
	add_child(tank)

	place["prepare"] = Vector3(-10.6, 0.0, 16.6)
	place["steamer"] = Vector3(-17.8, 0.0, 9.6)
	place["cooling"] = Vector3(-6.9, 0.0, -4.0)
	place["seeding"] = Vector3(-0.9, 0.0, -4.0)
	place["lab"] = Vector3(8.6, 0.0, 1.6)
	place["incubation"] = Vector3(0.0, 0.0, -7.2)
	place["packing"] = Vector3(-17.6, 0.0, -7.2)
	place["rest"] = Vector3(-24.6, 0.0, 10.5)

	for i in int(farm.c["workers"]):
		var n := Node3D.new()
		var body := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.42
		cm.height = 1.9
		body.mesh = cm
		body.material_override = _mat(Color(0.5, 0.5, 0.55))
		body.position.y = 1.05
		n.add_child(body)
		var head := MeshInstance3D.new()
		var hm2 := SphereMesh.new()
		hm2.radius = 0.36
		hm2.height = 0.72
		head.mesh = hm2
		head.material_override = _mat(Color(0.95, 0.8, 0.65))
		head.position.y = 2.25
		n.add_child(head)
		n.position = place["rest"] + Vector3(0.0, 0.0, i * 1.1 - 2.0)
		add_child(n)
		crew.append({"node": n, "body": body})


# ---------------------------------------------------------------- keeping the yard in step with the farm

func _animate(delta: float) -> void:
	# Sky and sun follow the hour.
	var h: float = farm.hod() + acc
	var light: float = clampf(sin((h - 6.0) / 12.0 * PI), 0.0, 1.0)
	env.background_color = NIGHT_SKY.lerp(DAY_SKY, light)
	env.ambient_light_energy = 0.3 + 0.45 * light
	sun.light_energy = 0.1 + 1.1 * light

	# Workers walk to their jobs in working hours and to the quarter after.
	var jobs := []
	if farm.is_work_hour():
		var st: Dictionary = farm.staff()
		for job in ["prepare", "seeding", "harvest"]:
			for n in int(st[job]):
				jobs.append(job)
	var ripe_spots := []
	for k in farm.containers:
		if farm.container_ripe(k) > 0.5:
			ripe_spots.append(place[k["name"]])
	var present: int = int(farm.c["workers"]) - farm.absent
	for i in crew.size():
		var node: Node3D = crew[i]["node"]
		var goal: Vector3 = place["rest"] + Vector3(0.0, 0.0, i * 1.1 - 2.0)
		var color := Color(0.5, 0.5, 0.55)
		if i < jobs.size():
			match jobs[i]:
				"prepare":
					goal = place["prepare"] + Vector3(i * 1.5 - 1.5, 0.0, 0.0)
					color = Color(0.95, 0.75, 0.2)
				"seeding":
					goal = place["seeding"] + Vector3(i * 0.9 - 2.5, 0.0, 0.8)
					color = Color(0.35, 0.6, 0.95)
				"harvest":
					goal = place["packing"] + Vector3(i * 0.9 - 3.0, 0.0, 0.0)
					if not ripe_spots.is_empty():
						goal = ripe_spots[i % ripe_spots.size()] + Vector3((i % 2) * 0.9 - 0.45, 0.0, 0.0)
					color = Color(0.4, 0.8, 0.45)
		node.visible = i < present
		node.position = node.position.move_toward(goal, delta * 14.0)
		crew[i]["body"].material_override.albedo_color = color

	# Bags and crates on the move.
	for f in farm.flows:
		if carts.size() >= 18 or not place.has(f[0]) or not place.has(f[1]):
			continue
		var busy := false
		for cart in carts:
			if cart["key"] == str(f) and float(cart["t"]) < 0.3:
				busy = true
		if busy:
			continue
		var color := Color(0.98, 0.97, 0.93) if f[1] == "packing" else BAG
		var m := _box(Vector3(0.9, 0.9, 0.9), place[f[0]], color)
		carts.append({"node": m, "a": place[f[0]], "b": place[f[1]], "t": 0.0, "key": str(f)})
	farm.flows.clear()
	for cart in carts.duplicate():
		cart["t"] = float(cart["t"]) + delta * 1.1
		var t: float = cart["t"]
		if t >= 1.0:
			cart["node"].queue_free()
			carts.erase(cart)
		else:
			var a: Vector3 = cart["a"]
			var b: Vector3 = cart["b"]
			cart["node"].position = a.lerp(b, t) + Vector3(0.0, 0.7 + sin(t * PI) * 1.6, 0.0)


func num(v) -> String:
	# 12345 -> 12,345
	var s := str(int(round(float(v))))
	var neg := s.begins_with("-")
	if neg:
		s = s.substr(1)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if neg else "") + s + out


func _show_stacks(nodes: Array, bags: int) -> void:
	var shown: int = mini(int(ceil(bags / float(BAGS_PER_STACK))), nodes.size())
	for i in nodes.size():
		nodes[i].visible = i < shown


func _refresh() -> void:
	if text3d.is_empty():
		return
	var s: Dictionary = farm.steamer
	var state := "idle"
	if int(s["down_hours"]) > 0:
		state = "DOWN, %d h" % int(s["down_hours"])
	elif int(s["hours_left"]) > 0:
		state = "%s bags, %d h left" % [num(s["load"]), int(s["hours_left"])]
	elif int(s["load"]) > 0:
		state = "%s bags done, cooling room full" % num(s["load"])
	text3d["prepare"].text = "Prepare\n%s / %s bags today" % [num(farm.prepared_today), num(farm.target)]
	text3d["steamer"].text = "Autoclaves\n%s\n%s bags waiting" % [state, num(farm.q_prepared)]
	var cool := "empty"
	if int(farm.cooling["hours_left"]) > 0:
		cool = "%s cooling, %d h" % [num(farm.cooling["load"]), int(farm.cooling["hours_left"])]
	elif farm.q_cooled > 0:
		cool = "%s ready for seeding" % num(farm.q_cooled)
	text3d["cooling"].text = "Cooling room\n%s" % cool
	text3d["seeding"].text = "Seeding\n%s bags today" % num(farm.today["seeded"])
	text3d["lab"].text = "Lab\n%s spawn units" % num(farm.spawn)
	var ready: int = farm.ready_bags()
	text3d["incubation"].text = "Incubation\n%s / %s bags%s" % [num(farm.incubation_bags()), num(farm.c["incubation_capacity"]),
		"" if ready == 0 else "\n%s ready to move in" % num(ready)]
	text3d["packing"].text = "Store room\n%s kg picked today" % num(farm.today["kg"])
	for k in farm.containers:
		var cname: String = k["name"]
		var bags: int = farm.container_bags(k)
		var ripe: float = farm.container_ripe(k)
		text3d[cname].text = "%s  %d%%\nCO2 %s\n%s bags%s" % [cname, int(round(float(k["humidity"]))), num(k["CO2"]), num(bags),
			"" if ripe < 0.5 else "\n%s kg ripe" % num(ripe)]
		var color := Color(0.5, 0.5, 0.5)
		if int(k["fault_hours"]) > 0:
			color = Color(0.9, 0.22, 0.18)
		elif bags > 0:
			color = Color(0.3, 0.75, 0.38) if farm.in_range(k) else Color(0.95, 0.68, 0.2)
		roofs[cname].material_override.albedo_color = color
		ripe_marks[cname].visible = ripe >= 0.5
		ripe_marks[cname].scale = Vector3.ONE * clampf(0.6 + ripe / 60.0, 0.6, 2.2)
	_show_stacks(inc_stacks, farm.incubation_bags())
	_show_stacks(wait_stacks, farm.q_prepared)
	_show_stacks(cool_stacks, int(farm.cooling["load"]) + farm.q_cooled)
	var hot: bool = int(s["hours_left"]) > 0 and int(s["down_hours"]) == 0
	for a in autoclaves:
		var m: StandardMaterial3D = a.material_override
		m.emission_enabled = hot
		m.emission = Color(1.0, 0.45, 0.1)
		m.emission_energy_multiplier = 0.9
		m.albedo_color = Color(0.9, 0.22, 0.18) if int(s["down_hours"]) > 0 else Color(0.62, 0.66, 0.7)


# ---------------------------------------------------------------- headless check

func _selftest() -> int:
	var bad := 0
	farm.reset()
	var start_inc: int = farm.incubation_bags()
	var start_fruit: int = farm.fruiting_bags()
	for i in 24 * 120:
		farm.step()
	var t: Dictionary = farm.totals
	var days := 120.0
	var removed_share: float = float(t["removed"]) / maxf(float(t["seeded"]), 1.0)
	var kg_month_per_container: float = float(t["kg"]) / days * 30.0 / farm.containers.size()
	print("start: %d incubating, %d fruiting" % [start_inc, start_fruit])
	print("120 days: prepared %d, seeded %d, removed %d (%.1f%%), spent %d" % [int(t["prepared"]), int(t["seeded"]), int(t["removed"]), removed_share * 100.0, int(t["spent"])])
	print("harvest %.0f kg (%.0f kg/day, %.0f kg per container per month), spoiled %.0f kg" % [float(t["kg"]), float(t["kg"]) / days, kg_month_per_container, float(t["lost_kg"])])
	print("cash RM %.0f (revenue %.0f, cost %.0f); now %d incubating, %d fruiting; bottleneck: %s" % [farm.cash(), float(t["revenue"]), float(t["cost"]), farm.incubation_bags(), farm.fruiting_bags(), farm.bottleneck()])
	var in_range_now := 0
	for k in farm.containers:
		if farm.in_range(k):
			in_range_now += 1
	print("containers in range now: %d of %d; forecast next 14 days: %.0f kg" % [in_range_now, farm.containers.size(), _sum(farm.forecast(14))])
	var checks := {
		"bags are seeded every day": int(t["seeded"]) > 100 * 120,
		"removals are near the set rate": removed_share > 0.03 and removed_share < 0.15,
		"mushrooms are harvested": float(t["kg"]) > 1000.0,
		"incubation stays within capacity": farm.incubation_bags() <= int(farm.c["incubation_capacity"]),
		"containers stay within capacity": farm.fruiting_bags() <= int(farm.c["container_capacity"]) * farm.containers.size(),
		"too many workers is refused": not farm.call_tool("assign_workers", {"prepare": 9, "seeding": 9, "harvest": 9})["ok"],
		"a target is accepted": farm.call_tool("set_target", {"bags": 300})["ok"],
		"an unknown tool is refused": not farm.call_tool("fly", {})["ok"],
		"climate can be set by hand": farm.call_tool("set_climate", {"container": "C1", "spray": true})["ok"] and not farm.containers[0]["auto"],
		"the snapshot is valid JSON": JSON.parse_string(JSON.stringify(farm.snapshot())) is Dictionary,
	}
	for name in checks:
		if not checks[name]:
			bad += 1
		print(("ok    " if checks[name] else "FAIL  ") + name)
	farm.fault("steamer")
	farm.fault("outbreak")
	farm.fault("humidifier")
	farm.fault("absent")
	for i in 24 * 20:
		farm.step()
	print("after 20 days of all four what-ifs: faults left %s; bottleneck: %s" % [str(farm.faults()), farm.bottleneck()])
	print("SELFTEST %s" % ("PASSED" if bad == 0 else "FAILED (%d)" % bad))
	return bad


func _sum(a: Array) -> float:
	var x := 0.0
	for v in a:
		x += float(v)
	return x
