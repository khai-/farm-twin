extends Node3D
## OINC Farm Twin. A manager's simulation of OINC's Sibu factory: the bag production line,
## incubation and fruiting, under weather, with electricity and water, and an AI steward that
## acts only through tools.
## The yard follows OINC's Phase 1 layout drawing of 26 Oct 2026 (metres; x across the page, z down it).
## Every model is made in code, so there are no art files.
## Headless checks: `-- --selftest` runs 120 days and checks the books; `-- --ask "..."` sends one
## order to the steward and prints what it does. `-- --shot file.png` saves a picture of the yard
## (add `--sky rain`, `--hour 21` or `--inspect C3` to set the scene first).

const Farm := preload("res://game/farm.gd")
const Steward := preload("res://game/steward.gd")
const Hud := preload("res://game/hud.gd")

const SPEEDS := [0.0, 2.0, 8.0, 48.0]   # simulated hours per second
const SPEED_NAMES := ["pause", "slow", "fast", "fastest"]
const BAGS_PER_STACK := 108             # as read from the drawing: 864 bongkah on 8 stacks
const INC_ROOMS := [[-11.5, -16.1], [0.3, -16.1], [12.1, -16.1]]   # left and top edge of each incubation room
# The ten farm containers in the drawing's order: x, z, and whether the long side runs across the page.
const FARM_SPOTS := [[-6.9, 4.7, true], [-0.7, 4.7, true], [-8.7, 11.2, false], [-5.4, 11.2, false], [-2.2, 11.2, false],
	[1.1, 11.2, false], [4.4, 11.2, false], [7.7, 11.2, false], [10.9, 11.2, false], [14.1, 11.2, false]]
const HOME := Vector3(7.5, 0.0, 3.0)
const HOME_DIST := 70.0
const PITCH := 55.0
const DAY_SKY := Color(0.56, 0.74, 0.92)
const NIGHT_SKY := Color(0.04, 0.06, 0.12)
const GREY_SKY := Color(0.42, 0.47, 0.52)
const BAG := Color(0.9, 0.86, 0.74)
const STEEL := Color(0.62, 0.66, 0.7)
const SLAB := Color(0.68, 0.68, 0.66)
const JOB_COLORS := {"prepare": Color(0.96, 0.76, 0.2), "seeding": Color(0.36, 0.62, 0.96), "harvest": Color(0.42, 0.82, 0.46), "": Color(0.52, 0.52, 0.58)}

var farm := Farm.new()
var hud
var steward
var speed_i := 1
var acc := 0.0
var cam: Camera3D
var cam_target := HOME
var cam_dist := HOME_DIST
var goal_target := HOME
var goal_dist := HOME_DIST
var dragging := false
var place := {}
var views := {}        # places the camera can look at
var text3d := {}
var roofs := {}
var room_rect := {}    # container name -> [x, z, half x, half z]
var ripe_marks := {}
var mist := {}
var ac_units := {}
var inc_stacks := []
var wait_stacks := []
var cool_stacks := []
var autoclaves := []
var steam := []
var heaps := []
var dedak_sacks := []
var calcium_sacks := []
var tank_water: MeshInstance3D
var crew := []
var carts := []
var fork := {}
var lamps := []
var shadows := []
var rain_light: CPUParticles3D
var rain_heavy: CPUParticles3D
var slab_mats := []
var ring: MeshInstance3D
var picked := ""       # "room:C3" or "worker:2"
var sun: DirectionalLight3D
var env: Environment
var sun_now := 1.0
var flash := 0.0
var clock := 0.0
var tick := 0.0
var shot_path := ""
var shot_wait := 0.0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	farm.load_data("res://data")
	if args.has("--selftest"):
		set_process(false)
		get_tree().quit(_selftest())
		return
	_build_world()
	steward = Steward.new()
	steward.farm = farm
	steward.scene = self
	add_child(steward)
	hud = Hud.new()
	add_child(hud)
	hud.setup(farm, self, steward)
	var i := args.find("--hour")
	if i >= 0 and i + 1 < args.size():
		while farm.hod() != int(args[i + 1]):
			farm.step()
	i = args.find("--sky")
	if i >= 0 and i + 1 < args.size():
		for n in mini(12, farm.sky.size()):
			farm.sky[n] = args[i + 1]
		farm.weather = farm.outside(farm.hour, farm.sky[0])
	i = args.find("--inspect")
	if i >= 0 and i + 1 < args.size():
		scene_tool("inspect", {"name": args[i + 1]})
	i = args.find("--shot")
	if i >= 0 and i + 1 < args.size():
		shot_path = args[i + 1]
		shot_wait = 3.0
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
	fork["queue"] = []
	picked = ""
	_refresh()


# ---------------------------------------------------------------- input: keys, camera, picking

func _unhandled_input(event: InputEvent) -> void:
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
			KEY_ENTER, KEY_KP_ENTER, KEY_SLASH:
				hud.focus_console("/" if event.keycode == KEY_SLASH else "")
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				select("")
			KEY_HOME, KEY_0:
				look_at_place("overview")
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			goal_dist = maxf(goal_dist * 0.88, 16.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			goal_dist = minf(goal_dist * 1.14, 110.0)
		elif event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_pick(event.position)
	elif event is InputEventMouseMotion and dragging:
		var k: float = cam_dist / 900.0
		goal_target += Vector3(-event.relative.x * k, 0.0, -event.relative.y * k * 1.25)
		goal_target.x = clampf(goal_target.x, -40.0, 40.0)
		goal_target.z = clampf(goal_target.z, -30.0, 30.0)
		cam_target = goal_target
	elif event is InputEventMagnifyGesture:
		goal_dist = clampf(goal_dist / event.factor, 16.0, 110.0)
	elif event is InputEventPanGesture:
		goal_dist = clampf(goal_dist * (1.0 + event.delta.y * 0.03), 16.0, 110.0)


func _pick(pos: Vector2) -> void:
	var from := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	# A worker, if the click passes close to one.
	var best := -1
	var best_d := 1.5
	for i in crew.size():
		var node: Node3D = crew[i]["node"]
		if not node.visible:
			continue
		var d: float = (node.position + Vector3(0.0, 1.3, 0.0) - from).cross(dir).length()
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		select("worker:%d" % best)
		return
	# Otherwise a farm container, where the click meets the height of a container's middle.
	if absf(dir.y) > 0.001:
		var hit: Vector3 = from + dir * ((1.5 - from.y) / dir.y)
		for cname in room_rect:
			var r: Array = room_rect[cname]
			if absf(hit.x - float(r[0])) <= float(r[2]) + 0.3 and absf(hit.z - float(r[1])) <= float(r[3]) + 0.3:
				select("room:" + cname)
				return
	select("")


func select(what: String) -> void:
	picked = what
	if hud != null:
		hud.show_inspector(what)


func look_at_place(where: String) -> bool:
	var key := where.to_lower()
	if key == "overview":
		goal_target = HOME
		goal_dist = HOME_DIST
		return true
	for v in views:
		if str(v).to_lower() == key:
			goal_target = views[v] + Vector3(4.0, 0.0, 2.0)
			goal_dist = 46.0
			return true
	return false


func _aim_camera(delta: float) -> void:
	cam_target = cam_target.lerp(goal_target, clampf(delta * 5.0, 0.0, 1.0))
	cam_dist = lerpf(cam_dist, goal_dist, clampf(delta * 5.0, 0.0, 1.0))
	var p := deg_to_rad(PITCH)
	cam.look_at_from_position(cam_target + Vector3(0.0, sin(p), cos(p)) * cam_dist, cam_target, Vector3.UP)


# ---------------------------------------------------------------- scene tools (the AI's hands on the view)

func is_scene_tool(tool_name: String) -> bool:
	return ["set_speed", "look_at", "inspect", "what_if"].has(tool_name)


func scene_tools_spec() -> Array:
	var spots := ["overview"]
	for v in views:
		spots.append(v)
	return [
		{"type": "function", "function": {"name": "set_speed", "description": "Set how fast the simulation clock runs.",
			"parameters": {"type": "object", "properties": {"speed": {"type": "string", "enum": SPEED_NAMES}}, "required": ["speed"]}}},
		{"type": "function", "function": {"name": "look_at", "description": "Move the manager's camera to a place on the farm, or back to the overview.",
			"parameters": {"type": "object", "properties": {"place": {"type": "string", "enum": spots}}, "required": ["place"]}}},
		{"type": "function", "function": {"name": "inspect", "description": "Open the details panel for a farm container (by name, such as C3) or a worker (such as worker 2). An empty name closes it.",
			"parameters": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}}},
		{"type": "function", "function": {"name": "what_if", "description": "Start a rehearsal scenario on the simulated farm. Only when the manager asks for one.",
			"parameters": {"type": "object", "properties": {"kind": {"type": "string", "enum": farm.WHAT_IFS.keys()}}, "required": ["kind"]}}},
	]


func scene_tool(tool_name: String, a: Dictionary) -> Dictionary:
	match tool_name:
		"set_speed":
			var i := SPEED_NAMES.find(str(a.get("speed", "")).to_lower())
			if i < 0:
				return farm.err("speed must be pause, slow, fast or fastest.")
			set_speed(i)
			return farm.ok("The clock is now on %s." % SPEED_NAMES[i])
		"look_at":
			if look_at_place(str(a.get("place", ""))):
				return farm.ok("The camera is on %s." % str(a.get("place", "")))
			return farm.err("There is no place with that name.")
		"inspect":
			var what := str(a.get("name", "")).strip_edges()
			if what == "":
				select("")
				return farm.ok("Closed.")
			if what.to_lower().begins_with("worker"):
				var n := int(what.to_lower().replace("worker", "").strip_edges())
				if n < 1 or n > crew.size():
					return farm.err("There are %d workers." % crew.size())
				select("worker:%d" % (n - 1))
				goal_target = crew[n - 1]["node"].position + Vector3(4.0, 0.0, 2.0)
				goal_dist = 46.0
				return farm.ok("Showing worker %d." % n)
			for k in farm.containers:
				if str(k["name"]).to_lower() == what.to_lower():
					select("room:" + str(k["name"]))
					look_at_place(str(k["name"]))
					return farm.ok("Showing %s." % k["name"])
			return farm.err("There is no container or worker with that name.")
		"what_if":
			var text: String = farm.fault(str(a.get("kind", "")))
			if text == "":
				return farm.err("There is no what-if with that name.")
			return farm.ok(text)
	return farm.err("There is no tool called %s." % tool_name)


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
	clock += delta
	_aim_camera(delta)
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
	m.roughness = 0.85
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _mesh(mesh: Mesh, pos: Vector3, color: Color, alpha := 1.0, parent: Node = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat(color, alpha)
	mi.position = pos
	(parent if parent != null else self).add_child(mi)
	return mi


func _box(size: Vector3, pos: Vector3, color: Color, alpha := 1.0, parent: Node = null) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	return _mesh(bm, pos, color, alpha, parent)


func _block(size: Vector3, x: float, z: float, color: Color, alpha := 1.0) -> MeshInstance3D:
	# A box standing on the ground at x, z.
	return _box(size, Vector3(x, size.y / 2.0 + 0.1, z), color, alpha)


func _ball(radius: float, pos: Vector3, color: Color, alpha := 1.0, parent: Node = null) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	return _mesh(sm, pos, color, alpha, parent)


func _pipe(radius: float, height: float, pos: Vector3, color: Color, alpha := 1.0) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = height
	return _mesh(cm, pos, color, alpha)


func _label(key: String, pos: Vector3, text := "", font := 58) -> Label3D:
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
	var wall := Color(0.86, 0.88, 0.9)
	_box(Vector3(sx, 1.3, 0.16), Vector3(cx, 0.75, cz - sz / 2.0), wall)
	_box(Vector3(0.16, 1.3, sz), Vector3(cx - sx / 2.0, 0.75, cz), wall)
	_box(Vector3(0.16, 1.3, sz), Vector3(cx + sx / 2.0, 0.75, cz), wall)


func _puffs(pos: Vector3, amount: int, size: float, rise: float) -> CPUParticles3D:
	# Soft white puffs rising: mist from a humidifier, steam from an autoclave.
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = 1.8
	p.direction = Vector3.UP
	p.spread = 22.0
	p.gravity = Vector3.ZERO
	p.initial_velocity_min = rise * 0.7
	p.initial_velocity_max = rise
	p.scale_amount_min = 0.5
	p.scale_amount_max = 1.0
	var sm := SphereMesh.new()
	sm.radius = size
	sm.height = size * 2.0
	var m := _mat(Color(1, 1, 1), 0.3)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.material = m
	p.mesh = sm
	p.position = pos
	p.emitting = false
	add_child(p)
	return p


func _rain(amount: int) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = amount
	p.lifetime = 0.9
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(46.0, 0.5, 34.0)
	p.direction = Vector3(0.12, -1.0, 0.05)
	p.spread = 2.0
	p.gravity = Vector3(0.0, -20.0, 0.0)
	p.initial_velocity_min = 26.0
	p.initial_velocity_max = 32.0
	var bm := BoxMesh.new()
	bm.size = Vector3(0.05, 1.1, 0.05)
	var m := _mat(Color(0.78, 0.86, 1.0), 0.5)
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.material = m
	p.mesh = bm
	p.position = Vector3(2.0, 26.0, 2.0)
	p.emitting = false
	add_child(p)
	return p


func _sacks(x: float, z: float, count: int, color: Color) -> Array:
	# Guni stacked on a pallet, two by two, as high as needed.
	_box(Vector3(2.0, 0.14, 1.4), Vector3(x, 0.2, z), Color(0.5, 0.38, 0.24))
	var out := []
	for i in count:
		var s := _box(Vector3(0.9, 0.24, 0.6), Vector3(x - 0.48 + (i % 2) * 0.96, 0.4 + (i / 4) * 0.25, z - 0.33 + ((i / 2) % 2) * 0.66), color)
		out.append(s)
	return out


func _build_world() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = DAY_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.78, 0.82, 0.9)
	env.ambient_light_energy = 0.7
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.ssao_enabled = true
	env.ssao_intensity = 2.2
	env.glow_enabled = true
	env.glow_intensity = 0.5
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 160.0
	add_child(sun)
	cam = Camera3D.new()
	cam.fov = 40.0
	add_child(cam)
	cam.current = true
	_aim_camera(1.0)

	# Ground: grass land, a road, the building's floor slab and the roofed strip along the bottom of the drawing.
	_box(Vector3(220.0, 0.1, 170.0), Vector3(0.0, -0.05, 0.0), Color(0.27, 0.42, 0.24))
	_box(Vector3(220.0, 0.06, 7.0), Vector3(0.0, 0.02, 30.5), Color(0.22, 0.23, 0.25))
	for i in 22:
		_box(Vector3(2.2, 0.02, 0.22), Vector3(-104.0 + i * 10.0, 0.07, 30.5), Color(0.85, 0.82, 0.6))
	slab_mats.append(_box(Vector3(47.6, 0.1, 31.5), Vector3(0.1, 0.05, -0.35), SLAB).material_override)
	slab_mats.append(_box(Vector3(49.0, 0.1, 6.0), Vector3(-0.6, 0.05, 18.4), SLAB.darkened(0.08)).material_override)
	_box(Vector3(10.0, 0.06, 7.0), Vector3(22.0, 0.03, 24.5), Color(0.5, 0.5, 0.5))   # driveway
	# The shed's frame: posts along the edges and beams across the top, so the building reads as a building.
	var frame := Color(0.3, 0.33, 0.37)
	for px in [-23.7, -11.8, 0.1, 12.0, 23.9]:
		_box(Vector3(0.3, 6.4, 0.3), Vector3(px, 3.2, -16.1), frame)
		_box(Vector3(0.3, 6.4, 0.3), Vector3(px, 3.2, 21.4), frame)
	_box(Vector3(47.9, 0.25, 0.25), Vector3(0.1, 6.4, -16.1), frame)
	_box(Vector3(47.9, 0.25, 0.25), Vector3(0.1, 6.4, 21.4), frame)
	_box(Vector3(0.25, 0.25, 37.5), Vector3(-23.7, 6.4, 2.65), frame)
	_box(Vector3(0.25, 0.25, 37.5), Vector3(23.9, 6.4, 2.65), frame)

	# Trees on the grass land around the site.
	var tree_rng := RandomNumberGenerator.new()
	tree_rng.seed = 3
	for spot in [[-36, -24], [-28, -27], [-18, -25], [-6, -27], [6, -24], [16, -27], [27, -25], [38, -26], [-38, -10], [-37, 4],
			[-39, 18], [31, -12], [36, 2], [33, 14], [40, 22], [-33, -17], [44, -8], [46, 10]]:
		var hgt: float = tree_rng.randf_range(3.0, 5.2)
		_pipe(0.28, hgt, Vector3(spot[0], hgt / 2.0, spot[1]), Color(0.36, 0.26, 0.17))
		_ball(tree_rng.randf_range(1.8, 2.7), Vector3(spot[0], hgt + 1.0, spot[1]), Color(0.16, 0.36, 0.17).lightened(tree_rng.randf() * 0.14))

	# Top of the drawing: the store room and three incubation rooms of bongkah stacks.
	_room(-17.65, -12.15, 11.9, 7.9, Color(0.6, 0.62, 0.68))
	for i in 6:
		_box(Vector3(1.2, 0.5, 0.8), Vector3(-21.6 + (i % 3) * 1.5, 0.45 + (i / 3) * 0.55, -14.6), Color(0.3, 0.5, 0.78))   # crates
	_label("packing", Vector3(-17.65, 2.8, -12.4))
	for r in INC_ROOMS.size():
		_room(float(INC_ROOMS[r][0]) + 5.8, -12.15, 11.6, 7.9, Color(0.48, 0.54, 0.5))
		for row in 5:
			for col in 6:
				var x: float = float(INC_ROOMS[r][0]) + 1.36 + col * 1.7
				var z: float = float(INC_ROOMS[r][1]) + 1.0 + row * 1.35
				for level in 2:
					var s := _box(Vector3(1.4, 1.4, 1.05), Vector3(x, 0.85 + level * 1.45, z), BAG.lightened(0.1 * level))
					s.visible = false
					inc_stacks.append(s)
	_label("incubation", Vector3(6.1, 5.2, -12.8))

	# Middle: the two-floor cooling room (Type A) joined to the seeding room (Type B).
	_block(Vector3(6.0, 5.6, 6.0), -6.9, -0.1, Color(0.7, 0.86, 0.98), 0.26)
	for i in 8:
		var s := _box(Vector3(1.05, 1.4, 1.4), Vector3(-9.1 + (i % 4) * 1.35, 0.85 + (i / 4) * 1.45, 1.8), BAG)
		s.visible = false
		cool_stacks.append(s)
	_label("cooling", Vector3(-6.9, 7.2, -0.8))
	_block(Vector3(6.0, 2.8, 6.0), -0.9, -0.1, Color(0.95, 0.95, 0.88), 0.4)
	_block(Vector3(3.2, 0.9, 1.0), -0.9, 1.4, Color(0.8, 0.84, 0.88))   # seeding bench
	_label("seeding", Vector3(-0.9, 4.4, -0.8))

	# The farm containers (Type C and Type D), 6 m by 3 m, each with its aircond compressor.
	for i in farm.containers.size():
		var spot: Array = FARM_SPOTS[i % FARM_SPOTS.size()]
		var along_x: bool = spot[2]
		var size := Vector3(6.0, 2.8, 3.0) if along_x else Vector3(3.0, 2.8, 6.0)
		var cname: String = farm.containers[i]["name"]
		var stripe := Color(0.25, 0.5, 0.85) if cname.begins_with("C") else Color(0.92, 0.55, 0.2)
		_block(size, spot[0], spot[1], Color(0.93, 0.93, 0.9))
		_box(Vector3(size.x + 0.04, 0.5, size.z + 0.04), Vector3(spot[0], 2.3, spot[1]), stripe)
		var door_pos := Vector3(spot[0], 1.15, spot[1] + size.z / 2.0) if along_x else Vector3(spot[0], 1.15, spot[1] - size.z / 2.0)
		_box(Vector3(1.0, 2.1, 0.08), door_pos, Color(0.3, 0.33, 0.38))
		var roof := _box(Vector3(size.x - 0.3, 0.14, size.z - 0.3), Vector3(spot[0], 2.98, spot[1]), Color(0.5, 0.5, 0.5))
		roof.material_override.emission_enabled = true
		roof.material_override.emission_energy_multiplier = 0.35
		roofs[cname] = roof
		ripe_marks[cname] = []
		for n in 5:   # mushroom clusters that appear on the roof when a flush is ripe
			var cap := _ball(0.42, Vector3(spot[0] + (n - 2) * (0.9 if along_x else 0.0), 3.25, spot[1] + (n - 2) * (0.0 if along_x else 0.9)), Color(0.86, 0.84, 0.8))
			cap.scale = Vector3(1.0, 0.55, 1.0)
			cap.visible = false
			ripe_marks[cname].append(cap)
		var ac_pos := Vector3(spot[0] + size.x / 2.0 - 0.6, 0.5, spot[1] - size.z / 2.0 - 0.3) if along_x else Vector3(spot[0] + size.x / 2.0 - 0.5, 0.5, spot[1] + size.z / 2.0 + 0.3)
		ac_units[cname] = _box(Vector3(0.8, 0.7, 0.4), ac_pos, Color(0.8, 0.82, 0.84))
		mist[cname] = _puffs(Vector3(spot[0], 3.1, spot[1]), 7, 0.34, 1.4)
		_label(cname, Vector3(spot[0], 4.8, spot[1]), "", 56)
		place[cname] = Vector3(spot[0], 0.0, 6.95 if along_x else 7.6)
		views[cname] = Vector3(spot[0], 0.0, spot[1])
		room_rect[cname] = [spot[0], spot[1], size.x / 2.0, size.z / 2.0]

	# Left: two autoclaves on a track, with the steam generator.
	autoclaves.append(_block(Vector3(2.16, 1.86, 8.84), -20.1, 2.7, STEEL))
	autoclaves.append(_block(Vector3(2.16, 1.86, 4.88), -15.5, 4.4, STEEL))
	_box(Vector3(0.12, 0.06, 9.0), Vector3(-20.7, 0.13, 11.6), Color(0.25, 0.25, 0.27))
	_box(Vector3(0.12, 0.06, 9.0), Vector3(-19.5, 0.13, 11.6), Color(0.25, 0.25, 0.27))
	_block(Vector3(1.5, 2.3, 2.23), -17.9, 0.6, Color(0.78, 0.38, 0.28))
	_pipe(0.16, 2.2, Vector3(-17.9, 3.5, 0.2), Color(0.4, 0.4, 0.42))
	steam.append(_puffs(Vector3(-20.1, 2.1, -1.4), 22, 0.6, 2.6))
	steam.append(_puffs(Vector3(-15.5, 2.1, 2.2), 16, 0.55, 2.4))
	for i in 8:
		var s := _box(Vector3(1.05, 1.4, 1.4), Vector3(-20.1 + (i / 4) * 1.9, 0.85, 8.6 + (i % 4) * 1.7), BAG)
		s.visible = false
		wait_stacks.append(s)
	_label("steamer", Vector3(-18.6, 4.2, 2.0))

	# Bottom, under the roof: sawdust piles, the guni, mixers, and the robotic arm with bagger.
	_box(Vector3(24.5, 0.05, 5.5), Vector3(8.3, 0.13, 18.6), Color(0.72, 0.6, 0.42))
	for hx in [3.5, 10.0, 16.5]:
		var heap := _ball(2.9, Vector3(hx, 0.1, 18.6), Color(0.74, 0.58, 0.36))
		heaps.append(heap)
	_label("sawdust", Vector3(10.0, 3.4, 19.2), "", 50)
	dedak_sacks = _sacks(-2.4, 17.1, 40, Color(0.82, 0.72, 0.5))
	calcium_sacks = _sacks(-2.4, 19.9, 20, Color(0.95, 0.95, 0.93))
	_label("guni", Vector3(-2.4, 3.2, 18.6), "", 40)
	_block(Vector3(1.08, 1.0, 2.6), -8.7, 18.3, Color(0.36, 0.5, 0.7))
	_block(Vector3(1.08, 1.0, 2.6), -6.7, 18.3, Color(0.36, 0.5, 0.7))
	_block(Vector3(1.8, 0.9, 0.9), -7.9, 20.4, Color(0.3, 0.42, 0.6))
	_block(Vector3(2.7, 1.21, 1.22), -13.4, 17.5, Color(0.93, 0.77, 0.2))
	_box(Vector3(0.25, 1.6, 0.25), Vector3(-12.4, 2.0, 17.5), Color(0.93, 0.77, 0.2))
	_box(Vector3(1.6, 0.22, 0.22), Vector3(-13.1, 2.8, 17.5), Color(0.93, 0.77, 0.2))
	_block(Vector3(1.6, 1.5, 1.4), -23.6, 16.6, STEEL)   # the existing steamer
	_label("prepare", Vector3(-11.4, 3.8, 19.6))

	# Around: temporary lab and office, the worker quarter, toilets, the water tank.
	_block(Vector3(5.9, 2.8, 2.35), 12.4, 1.6, Color(0.56, 0.72, 0.92))
	_block(Vector3(5.9, 2.8, 2.35), 12.4, 3.95, Color(0.62, 0.66, 0.76))
	_label("lab", Vector3(12.4, 4.4, 1.2))
	_block(Vector3(2.35, 2.8, 5.9), -27.2, 10.5, Color(0.7, 0.63, 0.52))
	_block(Vector3(1.1, 2.8, 1.3), -27.7, 1.3, Color(0.82, 0.82, 0.84))
	_block(Vector3(1.1, 2.8, 1.3), -27.7, 5.5, Color(0.82, 0.82, 0.84))
	_pipe(1.6, 3.0, Vector3(-22.7, 1.5, -20.6), Color(0.75, 0.85, 0.95), 0.3)
	tank_water = _pipe(1.45, 2.8, Vector3(-22.7, 1.5, -20.6), Color(0.2, 0.5, 0.85))
	_label("tank", Vector3(-22.7, 4.6, -20.6), "", 46)
	_label("power", Vector3(-27.6, 4.8, -6.0), "", 50)
	_block(Vector3(0.9, 1.8, 0.5), -27.6, -6.0, Color(0.55, 0.57, 0.6))   # the meter board
	_pipe(0.12, 7.0, Vector3(-28.6, 3.5, -6.0), Color(0.35, 0.3, 0.25))

	# Night lamps, lit when it is dark and the power is on.
	for spot in [[-6.0, 8.0], [7.0, 8.0], [-17.0, 6.0], [-9.0, 17.5], [1.0, -8.5], [14.0, -8.5], [12.0, 5.5]]:
		var lamp := OmniLight3D.new()
		lamp.position = Vector3(spot[0], 5.2, spot[1])
		lamp.omni_range = 15.0
		lamp.light_color = Color(1.0, 0.86, 0.62)
		lamp.light_energy = 0.0
		add_child(lamp)
		lamps.append(lamp)

	# Cloud shadows that drift over the site, and the rain.
	for i in 6:
		var cm := CylinderMesh.new()
		cm.top_radius = 9.0 + i * 1.6
		cm.bottom_radius = cm.top_radius
		cm.height = 0.02
		var sh := _mesh(cm, Vector3(-60.0 + i * 24.0, 7.2, -18.0 + (i * 13) % 34), Color(0.05, 0.07, 0.1), 0.0)
		sh.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		sh.scale = Vector3(1.5, 1.0, 0.8)
		shadows.append(sh)
	rain_light = _rain(700)
	rain_heavy = _rain(2200)

	# The forklift, which moves steamed loads and matured batches.
	var fk := Node3D.new()
	_box(Vector3(1.2, 1.1, 2.0), Vector3(0.0, 0.75, 0.0), Color(0.88, 0.28, 0.2), 1.0, fk)
	_box(Vector3(1.0, 0.9, 0.9), Vector3(0.0, 1.7, 0.35), Color(0.2, 0.22, 0.25), 1.0, fk)
	_box(Vector3(0.12, 2.6, 0.12), Vector3(-0.45, 1.4, -1.05), Color(0.2, 0.2, 0.22), 1.0, fk)
	_box(Vector3(0.12, 2.6, 0.12), Vector3(0.45, 1.4, -1.05), Color(0.2, 0.2, 0.22), 1.0, fk)
	var load_box := _box(Vector3(1.05, 1.4, 1.4), Vector3(0.0, 1.0, -1.9), BAG, 1.0, fk)
	load_box.visible = false
	fk.position = Vector3(-13.2, 0.1, 8.0)
	add_child(fk)
	fork = {"node": fk, "load": load_box, "queue": [], "phase": 0, "a": Vector3.ZERO, "b": Vector3.ZERO, "home": Vector3(-13.2, 0.1, 8.0)}

	# The ring that marks what the manager clicked.
	var tm := TorusMesh.new()
	tm.inner_radius = 1.0
	tm.outer_radius = 1.1
	ring = _mesh(tm, Vector3.ZERO, Color(1.0, 0.85, 0.2))
	ring.material_override.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring.material_override.no_depth_test = true
	ring.visible = false

	place["sawdust"] = Vector3(-1.0, 0.0, 17.8)
	place["prepare"] = Vector3(-10.6, 0.0, 16.6)
	place["steamer"] = Vector3(-17.8, 0.0, 9.6)
	place["cooling"] = Vector3(-6.9, 0.0, -4.0)
	place["seeding"] = Vector3(-0.9, 0.0, -4.0)
	place["lab"] = Vector3(8.6, 0.0, 1.6)
	place["incubation"] = Vector3(0.0, 0.0, -7.2)
	place["packing"] = Vector3(-17.6, 0.0, -7.2)
	place["rest"] = Vector3(-24.6, 0.0, 10.5)
	views["prepare"] = Vector3(-10.0, 0.0, 18.0)
	views["sawdust"] = Vector3(8.0, 0.0, 18.0)
	views["autoclaves"] = Vector3(-18.0, 0.0, 4.0)
	views["cooling"] = Vector3(-6.9, 0.0, 0.0)
	views["seeding"] = Vector3(-0.9, 0.0, 0.0)
	views["incubation"] = Vector3(6.0, 0.0, -11.0)
	views["store"] = Vector3(-17.6, 0.0, -11.0)
	views["lab"] = Vector3(12.4, 0.0, 2.5)
	views["tank"] = Vector3(-22.7, 0.0, -18.0)

	for i in int(farm.c["workers"]):
		var n := Node3D.new()
		var cm2 := CapsuleMesh.new()
		cm2.radius = 0.42
		cm2.height = 1.9
		var body := _mesh(cm2, Vector3(0.0, 1.05, 0.0), JOB_COLORS[""], 1.0, n)
		_ball(0.36, Vector3(0.0, 2.25, 0.0), Color(0.95, 0.8, 0.65), 1.0, n)
		var hat := _pipe(0.44, 0.12, Vector3.ZERO, Color(0.95, 0.92, 0.8))
		hat.reparent(n)
		hat.position = Vector3(0.0, 2.55, 0.0)
		n.position = place["rest"] + Vector3(0.0, 0.0, i * 1.1 - 2.0)
		n.scale = Vector3.ONE * 1.5
		add_child(n)
		crew.append({"node": n, "body": body, "job": "", "doing": "Off shift, in the worker quarter", "seed": i * 1.7})


# ---------------------------------------------------------------- keeping the yard in step with the farm

func _animate(delta: float) -> void:
	var w: Dictionary = farm.weather
	var state: String = w["state"]
	var wet: bool = state == "rain" or state == "storm"
	var power: bool = farm.power_cut_hours == 0
	# Sky, sun and lamps follow the hour and the weather.
	var h: float = farm.hod() + acc
	var light: float = clampf(sin((h - 6.0) / 12.0 * PI), 0.0, 1.0)
	sun_now = lerpf(sun_now, float(w["sun"]), clampf(delta * 1.5, 0.0, 1.0))
	var sky_day := DAY_SKY.lerp(GREY_SKY, clampf(1.3 - sun_now * 1.3, 0.0, 1.0))
	if farm.heat_days > 0:
		sky_day = sky_day.lerp(Color(0.95, 0.8, 0.55), 0.25)
	env.background_color = NIGHT_SKY.lerp(sky_day, light)
	if state == "storm" and randf() < delta * 0.5:
		flash = 0.18
	flash = maxf(flash - delta, 0.0)
	var bolt: float = 2.2 if flash > 0.0 else 0.0
	env.ambient_light_energy = 0.28 + 0.5 * light * (0.55 + 0.45 * sun_now) + bolt * 0.5
	env.ambient_light_color = Color(0.78, 0.82, 0.9).lerp(Color(1.0, 0.9, 0.75), 0.4 if farm.heat_days > 0 else 0.0)
	sun.light_energy = 0.06 + 1.15 * light * sun_now + bolt
	sun.rotation_degrees = Vector3(-18.0 - 46.0 * light, -70.0 + h * 3.0, 0.0)
	var dark: float = clampf(1.0 - light * 3.0, 0.0, 1.0) if power else 0.0
	for lamp in lamps:
		lamp.light_energy = lerpf(lamp.light_energy, 2.4 * dark, clampf(delta * 3.0, 0.0, 1.0))
	rain_light.emitting = state == "rain"
	rain_heavy.emitting = state == "storm"
	var slab_now := SLAB.darkened(0.3 if wet else 0.0)
	for m in slab_mats:
		m.albedo_color = m.albedo_color.lerp(slab_now, clampf(delta * 0.8, 0.0, 1.0))
		m.roughness = 0.35 if wet else 0.85
	var cover: float = {"clear": 0.1, "cloudy": 0.22, "rain": 0.3, "storm": 0.42}[state] * light
	for i in shadows.size():
		var sh: MeshInstance3D = shadows[i]
		sh.position.x += delta * (2.0 + i * 0.4) * (3.0 if state == "storm" else 1.0)
		if sh.position.x > 75.0:
			sh.position.x = -75.0
		var m2: StandardMaterial3D = sh.material_override
		m2.albedo_color.a = lerpf(m2.albedo_color.a, cover if (i < 2 or state != "clear") else 0.0, clampf(delta, 0.0, 1.0))

	# Workers walk to their jobs in working hours and to the quarter after.
	var jobs := []
	if farm.is_work_hour():
		var st: Dictionary = farm.staff()
		for job in ["prepare", "seeding", "harvest"]:
			for n in int(st[job]):
				jobs.append(job)
	var ripe_names := []
	for k in farm.containers:
		if farm.container_ripe(k) > 0.5:
			ripe_names.append(k["name"])
	var present: int = int(farm.c["workers"]) - farm.absent
	for i in crew.size():
		var cw: Dictionary = crew[i]
		var node: Node3D = cw["node"]
		var goal: Vector3 = place["rest"] + Vector3(0.0, 0.0, i * 1.1 - 2.0)
		cw["job"] = ""
		cw["doing"] = "Off shift, in the worker quarter"
		if i >= present:
			cw["doing"] = "Absent"
		elif i < jobs.size():
			cw["job"] = jobs[i]
			match jobs[i]:
				"prepare":
					goal = place["prepare"] + Vector3(i * 1.5 - 1.5, 0.0, 0.0)
					cw["doing"] = "Mixing and bagging at the bagger" if power else "Waiting at the bagger: the power is out"
				"seeding":
					goal = place["seeding"] + Vector3(i * 0.9 - 2.5, 0.0, 0.8)
					cw["doing"] = "Seeding cooled bags" if farm.q_cooled > 0 else "At the seeding room, waiting for cooled bags"
				"harvest":
					goal = place["packing"] + Vector3(i * 0.9 - 3.0, 0.0, 0.0)
					cw["doing"] = "At the store room: nothing is ripe"
					if not ripe_names.is_empty():
						var at: String = ripe_names[i % ripe_names.size()]
						goal = place[at] + Vector3((i % 2) * 0.9 - 0.45, 0.0, 0.0)
						cw["doing"] = "Picking at %s" % at
		elif farm.is_work_hour():
			cw["doing"] = "On site, not assigned to a job"
		node.visible = i < present
		var before: Vector3 = node.position
		node.position = node.position.move_toward(goal, delta * 13.0)
		var moving: bool = before.distance_to(node.position) > 0.001
		node.position.y = 0.1 + (absf(sin(clock * 11.0 + float(cw["seed"]))) * 0.22 if moving else 0.0)
		if moving:
			node.rotation.y = atan2(goal.x - before.x, goal.z - before.z)
		cw["body"].material_override.albedo_color = JOB_COLORS[cw["job"]]

	# Bags and crates on the move; big moves go by forklift.
	for f in farm.flows:
		if not place.has(f[0]) or not place.has(f[1]):
			continue
		if (f[0] == "steamer" and f[1] == "cooling") or f[0] == "incubation":
			if fork["queue"].size() < 4:
				fork["queue"].append([place[f[0]], place[f[1]]])
			continue
		if carts.size() >= 18:
			continue
		var busy := false
		for cart in carts:
			if cart["key"] == str(f) and float(cart["t"]) < 0.3:
				busy = true
		if busy:
			continue
		var color := BAG
		if f[1] == "packing":
			color = Color(0.3, 0.5, 0.78)
		elif f[0] == "sawdust":
			color = Color(0.74, 0.58, 0.36)
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
	_drive_forklift(delta)

	# Mist over a container whose humidifier is running; steam over a running autoclave.
	for k in farm.containers:
		mist[k["name"]].emitting = float(k["duty"]) > 0.05
		var unit: MeshInstance3D = ac_units[k["name"]]
		unit.material_override.albedo_color = Color(0.35, 0.75, 1.0) if float(k["ac"]) > 0.05 else Color(0.8, 0.82, 0.84)
	var hot: bool = int(farm.steamer["hours_left"]) > 0 and int(farm.steamer["down_hours"]) == 0 and power
	for s in steam:
		s.emitting = hot

	# The ring on whatever is selected.
	ring.visible = picked != ""
	if picked.begins_with("worker:"):
		var n2 := int(picked.substr(7))
		ring.position = crew[n2]["node"].position + Vector3(0.0, 0.25, 0.0)
		ring.scale = Vector3.ONE * (1.0 + 0.08 * sin(clock * 5.0))
	elif picked.begins_with("room:"):
		var r: Array = room_rect[picked.substr(5)]
		ring.position = Vector3(r[0], 3.4, r[1])
		ring.scale = Vector3(float(r[2]) * 1.05, 1.0, float(r[3]) * 1.05) * (1.0 + 0.04 * sin(clock * 5.0))


func _drive_forklift(delta: float) -> void:
	var node: Node3D = fork["node"]
	var goal: Vector3 = fork["home"]
	match int(fork["phase"]):
		0:
			if not fork["queue"].is_empty():
				var job: Array = fork["queue"].pop_front()
				fork["a"] = job[0]
				fork["b"] = job[1]
				fork["phase"] = 1
		1:
			goal = fork["a"]
		2:
			goal = fork["b"]
	goal.y = 0.1
	var before: Vector3 = node.position
	node.position = node.position.move_toward(goal, delta * 16.0)
	if before.distance_to(node.position) > 0.001:
		node.rotation.y = atan2(before.x - goal.x, before.z - goal.z)
	elif int(fork["phase"]) == 1:
		fork["phase"] = 2
		fork["load"].visible = true
	elif int(fork["phase"]) == 2:
		fork["phase"] = 0
		fork["load"].visible = false


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


func _show_count(nodes: Array, count: int) -> void:
	for i in nodes.size():
		nodes[i].visible = i < count


func _refresh() -> void:
	if text3d.is_empty():
		return
	var c: Dictionary = farm.c
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
	text3d["incubation"].text = "Incubation\n%s / %s bags%s" % [num(farm.incubation_bags()), num(c["incubation_capacity"]),
		"" if ready == 0 else "\n%s ready to move in" % num(ready)]
	text3d["packing"].text = "Store room\n%s kg picked today" % num(farm.today["kg"])
	text3d["sawdust"].text = "Sawdust %.1f t" % (float(farm.stock["sawdust_kg"]) / 1000.0)
	var dedak: float = float(farm.stock["dedak_kg"]) / float(c["dedak_guni_kg"])
	var calcium: float = float(farm.stock["calcium_kg"]) / float(c["calcium_guni_kg"])
	text3d["guni"].text = "Dedak padi %d guni\nCalcium carbonate %d guni" % [int(ceil(dedak)), int(ceil(calcium))]
	text3d["tank"].text = "Water tank\n%s L" % num(farm.tank_l)
	text3d["power"].text = "Power\nOUT" if farm.power_cut_hours > 0 else "Power\n%.0f kW" % farm.kwh_now
	text3d["power"].modulate = Color(1.0, 0.4, 0.3) if farm.power_cut_hours > 0 else Color(1.0, 0.95, 0.6)
	var level: float = clampf(farm.tank_l / float(c["tank_capacity_l"]), 0.02, 1.0)
	tank_water.scale.y = level
	tank_water.position.y = 0.1 + 1.4 * level
	var pile: float = clampf(float(farm.stock["sawdust_kg"]) / float(c["sawdust_capacity_kg"]), 0.0, 1.0)
	for i in heaps.size():
		var part: float = clampf(pile * 3.0 - i, 0.0, 1.0)
		heaps[i].visible = part > 0.02
		heaps[i].scale = Vector3(0.5 + 0.5 * part, 0.15 + 0.5 * part, 0.45 + 0.4 * part)
	_show_count(dedak_sacks, int(ceil(dedak)))
	_show_count(calcium_sacks, int(ceil(calcium)))
	for k in farm.containers:
		var cname: String = k["name"]
		var bags: int = farm.container_bags(k)
		var ripe: float = farm.container_ripe(k)
		text3d[cname].text = "%s\n%d%%" % [cname, int(round(float(k["humidity"])))]
		var color := Color(0.5, 0.5, 0.5)
		if int(k["fault_hours"]) > 0 or farm.power_cut_hours > 0:
			color = Color(0.92, 0.24, 0.2)
		elif bags > 0:
			color = Color(0.3, 0.76, 0.4) if farm.in_range(k) else Color(0.96, 0.68, 0.2)
		roofs[cname].material_override.albedo_color = color
		roofs[cname].material_override.emission = color
		_show_count(ripe_marks[cname], 0 if ripe < 0.5 else clampi(1 + int(ripe / 12.0), 1, 5))
	_show_count(inc_stacks, mini(int(ceil(farm.incubation_bags() / float(BAGS_PER_STACK))), inc_stacks.size()))
	_show_count(wait_stacks, mini(int(ceil(farm.q_prepared / float(BAGS_PER_STACK))), wait_stacks.size()))
	_show_count(cool_stacks, mini(int(ceil((int(farm.cooling["load"]) + farm.q_cooled) / float(BAGS_PER_STACK))), cool_stacks.size()))
	var hot: bool = int(s["hours_left"]) > 0 and int(s["down_hours"]) == 0
	for a in autoclaves:
		var m: StandardMaterial3D = a.material_override
		m.emission_enabled = hot
		m.emission = Color(1.0, 0.45, 0.1)
		m.emission_energy_multiplier = 0.9
		m.albedo_color = Color(0.9, 0.22, 0.18) if int(s["down_hours"]) > 0 else STEEL


func worker_info(i: int) -> Dictionary:
	# What the manager sees when a worker is clicked. The simulation tracks jobs, not people,
	# so a worker's output is their share of their station's output today.
	var cw: Dictionary = crew[i]
	var st: Dictionary = farm.staff()
	var job: String = cw["job"]
	var share := ""
	if job == "prepare" and int(st["prepare"]) > 0:
		share = "%s bags prepared today (share of %s)" % [num(float(farm.today["prepared"]) / int(st["prepare"])), num(farm.today["prepared"])]
	elif job == "seeding" and int(st["seeding"]) > 0:
		share = "%s bags seeded today (share of %s)" % [num(float(farm.today["seeded"]) / int(st["seeding"])), num(farm.today["seeded"])]
	elif job == "harvest" and int(st["harvest"]) > 0:
		share = "%s kg picked today (share of %s)" % [num(float(farm.today["kg"]) / int(st["harvest"])), num(farm.today["kg"])]
	var hours: int = clampi(farm.hod() - int(farm.c["work_start"]), 0, int(farm.c["work_end"]) - int(farm.c["work_start"]))
	return {"name": "Worker %d" % (i + 1), "job": job if job != "" else "none", "doing": cw["doing"], "output": share,
		"hours": hours, "shift": "%02d:00 to %02d:00" % [int(farm.c["work_start"]), int(farm.c["work_end"])], "wage": float(farm.c["wage_per_day"])}


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
	print("electricity %.0f kWh/day (RM %.0f in all), water %.0f L/day of which mains %.0f L/day, rain caught %.0f L/day; utilities RM %.2f per kg" % [
		float(t["kwh"]) / days, float(t["power_rm"]), float(t["water_l"]) / days, float(t["mains_l"]) / days, float(t["rain_l"]) / days, farm.utility_cost_per_kg()])
	var skies := {"clear": 0, "cloudy": 0, "rain": 0, "storm": 0}
	var rain_mm := 0.0
	for r in farm.daily:
		rain_mm += float(r["rain_mm"])
	for i in 24 * 30:
		farm.step()
		skies[farm.weather["state"]] += 1
	print("weather over the next 30 days (hours): %s; rain in the first 120 days: %.0f mm; materials left make %d bags" % [str(skies), rain_mm, farm.bags_of_materials()])
	var in_range_now := 0
	for k in farm.containers:
		if farm.in_range(k):
			in_range_now += 1
	print("containers in range now: %d of %d; forecast next 14 days: %.0f kg" % [in_range_now, farm.containers.size(), _sum(farm.forecast(14))])
	var checks := {
		"bags are seeded every day": int(t["seeded"]) > 100 * 120,
		"removals are near the set rate": removed_share > 0.03 and removed_share < 0.2,
		"mushrooms are harvested": float(t["kg"]) > 1000.0,
		"electricity and water are used": float(t["kwh"]) > 1000.0 and float(t["water_l"]) > 1000.0,
		"incubation stays within capacity": farm.incubation_bags() <= int(farm.c["incubation_capacity"]),
		"containers stay within capacity": farm.fruiting_bags() <= int(farm.c["container_capacity"]) * farm.containers.size(),
		"too many workers is refused": not farm.call_tool("assign_workers", {"prepare": 9, "seeding": 9, "harvest": 9})["ok"],
		"a target is accepted": farm.call_tool("set_target", {"bags": 300})["ok"],
		"an unknown tool is refused": not farm.call_tool("fly", {})["ok"],
		"climate can be set by hand": farm.call_tool("set_climate", {"container": "C1", "spray": true})["ok"] and not farm.containers[0]["auto"],
		"materials can be ordered": farm.call_tool("order_materials", {"sawdust_tonnes": 5, "dedak_guni": 10})["ok"],
		"targets can be set": farm.call_tool("set_fruiting_targets", {"temp_limit": 32})["ok"],
		"the snapshot is valid JSON": JSON.parse_string(JSON.stringify(farm.snapshot())) is Dictionary,
		"the container log is kept": farm.containers[0]["log"].size() > 0,
	}
	for name in checks:
		if not checks[name]:
			bad += 1
		print(("ok    " if checks[name] else "FAIL  ") + name)
	for kind in farm.WHAT_IFS:
		farm.fault(kind)
	for i in 24 * 20:
		farm.step()
	print("after 20 days of every what-if at once: faults left %s; bottleneck: %s" % [str(farm.faults()), farm.bottleneck()])
	print("SELFTEST %s" % ("PASSED" if bad == 0 else "FAILED (%d)" % bad))
	return bad


func _sum(a: Array) -> float:
	var x := 0.0
	for v in a:
		x += float(v)
	return x
