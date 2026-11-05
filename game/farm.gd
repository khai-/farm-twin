extends RefCounted
## The farm simulation. Bags flow through OINC's own steps:
##   Lab (spawn) -> Prepare -> Steam -> Cooling -> Seeding -> Incubation -> Move In / Open Cap -> Harvest -> Removal
## One step is one hour. Weather passes overhead and pushes on everything; every station draws
## electricity and water. Everything a manager or the AI steward can change goes through
## call_tool(), so the AI can do what the manager's buttons can do and nothing more.
##
## Numbers come from data/farm.json (each one labelled with its source; most are assumed) and from
## data/params.json (the daily climate fitted from a real container's sensor log).

const VARS := ["temperature", "humidity", "CO2"]
const ACTUATORS := ["humidifier", "spray", "vent1", "vent2", "aircond", "light"]
const JOBS := ["prepare", "seeding", "harvest"]
const SKIES := ["clear", "cloudy", "rain", "storm"]
# How the sky changes every three hours (assumed; shaped on a hot, wet equatorial town).
const SKY_NEXT := {"clear": [0.72, 0.23, 0.04, 0.01], "cloudy": [0.40, 0.41, 0.16, 0.03], "rain": [0.16, 0.52, 0.27, 0.05], "storm": [0.0, 0.42, 0.47, 0.11]}
const SUN := {"clear": 1.0, "cloudy": 0.6, "rain": 0.35, "storm": 0.2}
const PLAN_FACTOR := 0.85   # yield factor assumed for bags that have not fruited yet, in the forecast

var c := {}          # settings by key
var meta := {}       # key -> {label, source, value}
var order := []      # setting keys in file order
var fit := {}        # the whole fitted-climate file
var climate := {}
var fx := {}         # assumed actuator effects
var rng := RandomNumberGenerator.new()

var hour := 0        # hours since day 0, 00:00
var target := 0
var alloc := {"prepare": 2, "seeding": 1, "harvest": 2}
var absent := 0
var absent_hours := 0
var prepared_today := 0
var q_prepared := 0  # bags waiting for the autoclaves
var q_cooled := 0    # sterilised bags waiting in the cooling room for seeding
var steamer := {"load": 0, "hours_left": 0, "down_hours": 0}   # the two autoclaves, loaded together
var cooling := {"load": 0, "hours_left": 0}                    # the cooling room holds one steamed load
var spawn := 0.0
var incubation := [] # batches: {id, bags, day0, ready}
var containers := []
var auto_steam := true
var auto_move_in := true
var outbreak_days := 0
var next_id := 1

var sky := []        # the sky for each coming hour; sky[0] is now
var weather := {}    # outside now: {state, temp, humidity, rain_mm, sun, typical}
var drift := 0.0     # slow day-to-day temperature drift
var heat_days := 0
var power_cut_hours := 0
var water_cut_hours := 0
var tank_l := 0.0
var today_max := 0.0
var yesterday_max := 30.0
var kwh_now := 0.0   # electricity used in the current hour
var water_now := 0.0 # water used in the current hour
var stock := {"sawdust_kg": 0.0, "dedak_kg": 0.0, "calcium_kg": 0.0}   # raw materials on site
var deliveries := []  # materials on order: {day, sawdust_kg, dedak_kg, calcium_kg}

var totals := {}
var today := {}
var daily := []      # one record per finished day
var events := []     # [{hour, text}]
var events_total := 0
var flows := []      # [from, to] pairs since the last frame, for the yard view
var quiet := false


func load_data(dir: String) -> void:
	var cfg = JSON.parse_string(FileAccess.get_file_as_string(dir + "/farm.json"))
	for item in cfg["settings"]:
		c[item["key"]] = item["value"]
		meta[item["key"]] = item
		order.append(item["key"])
	fit = JSON.parse_string(FileAccess.get_file_as_string(dir + "/params.json"))
	climate = fit["climate"]
	fx = fit["actuators"]
	reset()


func reset(warm_days: int = 140) -> void:
	rng.seed = 7
	hour = 0
	target = int(c["daily_target"])
	var w := int(c["workers"])
	alloc = {"prepare": maxi(1, w - 3), "seeding": 1 if w >= 2 else 0, "harvest": 2 if w >= 4 else maxi(0, w - 2)}
	absent = 0
	absent_hours = 0
	prepared_today = 0
	q_prepared = 0
	q_cooled = 0
	steamer = {"load": 0, "hours_left": 0, "down_hours": 0}
	cooling = {"load": 0, "hours_left": 0}
	spawn = float(c["lab_capacity"]) * 0.5
	incubation = []
	containers = []
	var names: Array = c.get("container_names", [])
	for i in int(c["containers"]):
		var act := {}
		for a in ACTUATORS:
			act[a] = false
		containers.append({"name": str(names[i]) if i < names.size() else "C%d" % (i + 1), "batches": [],
			"d": {"temperature": 0.0, "humidity": 0.0, "CO2": 0.0}, "temperature": 28.0, "humidity": 88.0, "CO2": 700.0,
			"act": act, "auto": true, "fault_hours": 0, "duty": 0.0, "ac": 0.0, "log": [], "picked_today": 0.0})
	auto_steam = true
	auto_move_in = true
	outbreak_days = 0
	next_id = 1
	sky = ["clear"]
	drift = 0.0
	heat_days = 0
	power_cut_hours = 0
	water_cut_hours = 0
	tank_l = float(c["tank_capacity_l"]) * 0.6
	_fill_stock()
	deliveries = []
	today_max = 0.0
	yesterday_max = 30.0
	_extend_sky()
	weather = outside(hour, sky[0])
	_blank_books()
	# Warm start: run the farm quietly so the manager begins with a full pipeline, then call that day 0.
	quiet = true
	for i in warm_days * 24:
		step()
	hour = 0
	for b in incubation:
		b["day0"] = int(b["day0"]) - warm_days
	for k in containers:
		k["fault_hours"] = 0
		for b in k["batches"]:
			b["day_in"] = int(b["day_in"]) - warm_days
			b["next_flush_day"] = int(b["next_flush_day"]) - warm_days
			b["ripe_hour"] = int(b["ripe_hour"]) - warm_days * 24
	power_cut_hours = 0
	water_cut_hours = 0
	for i in 7:
		step()
	quiet = false
	_fill_stock()
	for k in containers:
		k["log"] = []
		k["picked_today"] = 0.0
		for b in k["batches"]:
			_room_log(k, "Inspection", "Batch %d: %d bags, flush %d of %d next." % [int(b["id"]), int(b["bags"]), mini(int(b["flush"]) + 1, c["flush_yield_g"].size()), c["flush_yield_g"].size()])
	_blank_books()
	flows = []
	events = []
	events_total = 0
	_log("The farm is running. %d bags are incubating and %d are fruiting." % [incubation_bags(), fruiting_bags()])


func _fill_stock() -> void:
	stock = {"sawdust_kg": float(c["sawdust_start_kg"]), "dedak_kg": float(c["dedak_start_guni"]) * float(c["dedak_guni_kg"]),
		"calcium_kg": float(c["calcium_start_guni"]) * float(c["calcium_guni_kg"])}


func _room_log(k: Dictionary, kind: String, text: String) -> void:
	# The operations log of one container, in the words of OINC's plantation log.
	if quiet:
		return
	k["log"].append({"hour": hour, "kind": kind, "text": text})
	if k["log"].size() > 60:
		k["log"].pop_front()


func bags_of_materials() -> int:
	# How many more bags the materials on site can make.
	return mini(int(float(stock["sawdust_kg"]) / float(c["sawdust_kg_per_bag"])),
		mini(int(float(stock["dedak_kg"]) / float(c["dedak_kg_per_bag"])), int(float(stock["calcium_kg"]) / float(c["calcium_kg_per_bag"]))))


func _blank_books() -> void:
	totals = {"prepared": 0, "seeded": 0, "removed": 0, "spent": 0, "kg": 0.0, "lost_kg": 0.0, "revenue": 0.0, "cost": 0.0,
		"kwh": 0.0, "power_rm": 0.0, "water_l": 0.0, "mains_l": 0.0, "rain_l": 0.0, "water_rm": 0.0}
	today = _blank_day()
	daily = []


func _blank_day() -> Dictionary:
	return {"day": day(), "prepared": 0, "seeded": 0, "removed": 0, "kg": 0.0, "lost_kg": 0.0, "kwh": 0.0, "water_l": 0.0, "rain_mm": 0.0}


# ---------------------------------------------------------------- small helpers

func day() -> int:
	return int(floor(hour / 24.0))


func hod() -> int:
	return posmod(hour, 24)


func cash() -> float:
	return float(totals["revenue"]) - float(totals["cost"])


func is_work_hour() -> bool:
	return hod() >= int(c["work_start"]) and hod() < int(c["work_end"])


func incubation_bags() -> int:
	var n := 0
	for b in incubation:
		n += int(b["bags"])
	return n


func ready_bags() -> int:
	var n := 0
	for b in incubation:
		if b["ready"]:
			n += int(b["bags"])
	return n


func container_bags(k: Dictionary) -> int:
	var n := 0
	for b in k["batches"]:
		n += int(b["bags"])
	return n


func container_ripe(k: Dictionary) -> float:
	var kg := 0.0
	for b in k["batches"]:
		kg += float(b["ripe_kg"])
	return kg


func container_free(k: Dictionary) -> int:
	return int(c["container_capacity"]) - container_bags(k)


func fruiting_bags() -> int:
	var n := 0
	for k in containers:
		n += container_bags(k)
	return n


func ripe_kg() -> float:
	var kg := 0.0
	for k in containers:
		kg += container_ripe(k)
	return kg


func in_range(k: Dictionary) -> bool:
	return float(k["humidity"]) >= float(c["humidity_low"]) and float(k["humidity"]) <= float(c["humidity_high"]) \
		and float(k["CO2"]) <= float(c["co2_limit"]) and float(k["temperature"]) <= float(c["temp_limit"])


func staff() -> Dictionary:
	# Ripe mushrooms cannot wait, so harvest is staffed first when people are missing.
	var left: int = int(c["workers"]) - absent
	var out := {}
	for job in ["harvest", "seeding", "prepare"]:
		var n: int = mini(int(alloc[job]), maxi(left, 0))
		out[job] = n
		left -= n
	return out


func usual(v: String, h: float) -> float:
	# The room's usual level at this time of day, fitted from the real sensor log.
	var coef: Array = climate[v]["daily_coef"]
	var x: float = coef[0]
	var n := 1
	while 2 * n < coef.size():
		var w: float = TAU * n * h / 24.0
		x += float(coef[2 * n - 1]) * sin(w) + float(coef[2 * n]) * cos(w)
		n += 1
	return x


func _log(text: String) -> void:
	if quiet:
		return
	events.append({"hour": hour, "text": text})
	events_total += 1
	if events.size() > 300:
		events.pop_front()


func _spend(rm: float) -> void:
	totals["cost"] = float(totals["cost"]) + rm


func stamp(h: int) -> String:
	return "Day %d %02d:00" % [int(floor(h / 24.0)), posmod(h, 24)]


# ---------------------------------------------------------------- weather (assumed generator)

func _extend_sky() -> void:
	# Keep 72 hours of sky ahead. The sky changes at most every three hours.
	while sky.size() < 72:
		var at: int = hour + sky.size()
		var last: String = sky[-1]
		if posmod(at, 3) != 0:
			sky.append(last)
			continue
		var p: Array = SKY_NEXT[last].duplicate()
		var h: int = posmod(at, 24)
		if h >= 14 and h < 21:   # afternoon and evening rain is common
			var shift: float = minf(float(p[0]), 0.06)
			p[0] = float(p[0]) - shift
			p[2] = float(p[2]) + shift
		var r := rng.randf()
		var pick := last
		for i in 4:
			r -= float(p[i])
			if r <= 0.0:
				pick = SKIES[i]
				break
		sky.append(pick)


func outside(h_abs: int, state: String) -> Dictionary:
	var h: int = posmod(h_abs, 24)
	var typical: float = 27.5 + 4.5 * sin((h - 8) / 24.0 * TAU)
	var t: float = typical + drift + (3.0 if heat_days > 0 else 0.0)
	if state == "clear" and h >= 8 and h < 18:
		t += 1.5
	elif state == "cloudy":
		t -= 0.5
	elif state == "rain":
		t -= 2.5
	elif state == "storm":
		t -= 3.5
	var rh: float = clampf(100.0 - (t - 23.0) * 4.5, 50.0, 98.0)
	var rain := 0.0
	if state == "rain":
		rh = maxf(rh, 92.0)
		rain = 1.5
	elif state == "storm":
		rh = maxf(rh, 95.0)
		rain = 8.0
	return {"state": state, "temp": t, "humidity": rh, "rain_mm": rain, "sun": float(SUN[state]), "typical": typical}


func _weather_step(h: int) -> void:
	sky.pop_front()
	_extend_sky()
	weather = outside(hour, sky[0])
	today_max = maxf(today_max, float(weather["temp"]))
	var rain: float = weather["rain_mm"]
	if rain > 0.0:
		today["rain_mm"] = float(today["rain_mm"]) + rain
		var caught: float = minf(rain * float(c["roof_catchment_m2"]), float(c["tank_capacity_l"]) - tank_l)
		tank_l += caught
		totals["rain_l"] = float(totals["rain_l"]) + caught
	if weather["state"] == "storm" and posmod(h, 3) == 0 and power_cut_hours == 0 and rng.randf() < float(c["storm_power_cut_chance"]):
		power_cut_hours = 3 + rng.randi() % 4
		_log("Storm: the power is out.")


func weather_outlook() -> Array:
	var out := []
	var names := ["next 24 h", "24 to 48 h", "48 to 72 h"]
	for d in 3:
		var rain := 0
		var storm := 0
		var hi := 0.0
		for i in 24:
			var idx: int = d * 24 + i
			if idx >= sky.size():
				break
			if sky[idx] == "rain":
				rain += 1
			elif sky[idx] == "storm":
				storm += 1
			hi = maxf(hi, float(outside(hour + idx, sky[idx])["temp"]))
		out.append({"when": names[d], "rain_hours": rain, "storm_hours": storm, "max_temp": snappedf(hi, 0.1)})
	return out


# ---------------------------------------------------------------- water

func _water_available(need: float) -> bool:
	return water_cut_hours == 0 or tank_l >= need


func _draw_water(need: float) -> float:
	# Tank water (rain) first, then the mains. Returns the litres actually supplied.
	var got: float = minf(need, tank_l)
	tank_l -= got
	var rest: float = need - got
	if rest > 0.0 and water_cut_hours == 0:
		got += rest
		totals["mains_l"] = float(totals["mains_l"]) + rest
		var rm: float = rest / 1000.0 * float(c["water_rm_per_m3"])
		totals["water_rm"] = float(totals["water_rm"]) + rm
		_spend(rm)
	water_now += got
	return got


# ---------------------------------------------------------------- one hour

func step() -> void:
	hour += 1
	var h := hod()
	kwh_now = 0.0
	water_now = 0.0
	if h == 0:
		_new_day()
	_weather_step(h)
	var power := power_cut_hours == 0
	if power:
		# Lab, office and lights, plus incubation cooling, which works harder when it is hot outside.
		kwh_now += float(c["base_kw"]) + float(c["incubation_kw"]) * (0.6 + 0.08 * maxf(float(weather["temp"]) - 24.0, 0.0))
	if is_work_hour():
		_work(staff(), power)
	_steam(h, power)
	for k in containers:
		_climate(k, h, power)
		_spoil(k)
	today["kwh"] = float(today["kwh"]) + kwh_now
	totals["kwh"] = float(totals["kwh"]) + kwh_now
	var rm: float = kwh_now * float(c["tariff_rm_per_kwh"])
	totals["power_rm"] = float(totals["power_rm"]) + rm
	_spend(rm)
	today["water_l"] = float(today["water_l"]) + water_now
	totals["water_l"] = float(totals["water_l"]) + water_now
	if power_cut_hours > 0:
		power_cut_hours -= 1
		if power_cut_hours == 0:
			_log("The power is back.")
	if water_cut_hours > 0:
		water_cut_hours -= 1
		if water_cut_hours == 0:
			_log("The mains water is back.")
	if absent_hours > 0:
		absent_hours -= 1
		if absent_hours == 0:
			absent = 0
			_log("The absent workers are back.")


func _work(st: Dictionary, power: bool) -> void:
	# Prepare: mix the substrate and fill bags, up to the day's target. Needs power and water.
	var n: int = mini(int(c["prepare_rate"]) * int(st["prepare"]), target - prepared_today)
	if not power:
		n = 0
	if not quiet:
		n = mini(n, bags_of_materials())
	if n > 0:
		var per: float = c["water_per_bag_l"]
		var got: float = _draw_water(n * per)
		n = mini(n, int(got / per + 0.001))
	if n > 0:
		q_prepared += n
		prepared_today += n
		_spend(n * float(c["cost_per_bag"]))
		kwh_now += n * float(c["prepare_kwh_per_bag"])
		if not quiet:
			stock["sawdust_kg"] = float(stock["sawdust_kg"]) - n * float(c["sawdust_kg_per_bag"])
			stock["dedak_kg"] = float(stock["dedak_kg"]) - n * float(c["dedak_kg_per_bag"])
			stock["calcium_kg"] = float(stock["calcium_kg"]) - n * float(c["calcium_kg_per_bag"])
		today["prepared"] = int(today["prepared"]) + n
		totals["prepared"] = int(totals["prepared"]) + n
		flows.append(["sawdust", "prepare"])
		flows.append(["prepare", "steamer"])
	_draw_water(float(c["cleaning_l_per_day"]) / float(int(c["work_end"]) - int(c["work_start"])))
	# Seeding: put spawn into the cooled bags and shelve them in incubation. The clean bench needs power.
	var room: int = int(c["incubation_capacity"]) - incubation_bags()
	n = mini(mini(q_cooled, int(c["seeding_rate"]) * int(st["seeding"])), mini(int(spawn * float(c["bags_per_spawn"])), room))
	if not power:
		n = 0
	if n > 0:
		q_cooled -= n
		spawn -= n / float(c["bags_per_spawn"])
		var b: Dictionary = _todays_batch()
		b["bags"] = int(b["bags"]) + n
		today["seeded"] = int(today["seeded"]) + n
		totals["seeded"] = int(totals["seeded"]) + n
		flows.append(["cooling", "seeding"])
		flows.append(["lab", "seeding"])
		flows.append(["seeding", "incubation"])
	# Harvest: pick what is ripe, oldest first.
	var cap: float = float(c["harvest_rate"]) * int(st["harvest"])
	for k in containers:
		for bt in k["batches"]:
			if cap <= 0.0:
				break
			var kg: float = minf(cap, float(bt["ripe_kg"]))
			if kg > 0.0:
				bt["ripe_kg"] = float(bt["ripe_kg"]) - kg
				cap -= kg
				today["kg"] = float(today["kg"]) + kg
				totals["kg"] = float(totals["kg"]) + kg
				totals["revenue"] = float(totals["revenue"]) + kg * float(c["price_per_kg"])
				k["picked_today"] = float(k["picked_today"]) + kg
				flows.append([k["name"], "packing"])


func _todays_batch() -> Dictionary:
	if not incubation.is_empty() and int(incubation[-1]["day0"]) == day():
		return incubation[-1]
	var b := {"id": next_id, "bags": 0, "day0": day(), "ready": false}
	next_id += 1
	incubation.append(b)
	return b


func _steam(h: int, power: bool) -> void:
	# Cooling room: a steamed load cools there, then waits there for seeding.
	if int(cooling["hours_left"]) > 0 and power:
		kwh_now += float(c["cooling_room_kw"])
		cooling["hours_left"] = int(cooling["hours_left"]) - 1
		if int(cooling["hours_left"]) == 0:
			q_cooled += int(cooling["load"])
			_log("Cooling: %d bags are cool and ready for seeding." % int(cooling["load"]))
			cooling["load"] = 0
	if int(steamer["down_hours"]) > 0:
		steamer["down_hours"] = int(steamer["down_hours"]) - 1
		if int(steamer["down_hours"]) == 0:
			_log("The autoclaves are repaired.")
		return
	if int(steamer["hours_left"]) > 0:
		if not power:
			return
		kwh_now += float(c["autoclave_kwh_per_cycle"]) / float(c["steam_hours"])
		steamer["hours_left"] = int(steamer["hours_left"]) - 1
		if int(steamer["hours_left"]) > 0:
			return
	if int(steamer["load"]) > 0:
		# Steamed. The load moves on only when the cooling room is empty.
		# The cooling room holds one full autoclave load in all: a new load may join cooled bags still waiting for seeding.
		if int(cooling["load"]) == 0 and q_cooled + int(steamer["load"]) <= int(c["steamer_capacity"]):
			cooling["load"] = int(steamer["load"])
			cooling["hours_left"] = int(c["cool_hours"])
			_log("Steam: %d bags sterilised and moved to the cooling room." % int(steamer["load"]))
			steamer["load"] = 0
			flows.append(["steamer", "cooling"])
		return
	if auto_steam and power and _water_available(float(c["steam_water_l"])) \
			and (q_prepared >= int(c["steamer_capacity"]) or (h == int(c["work_end"]) and q_prepared > 0)):
		start_steam()


func start_steam() -> Dictionary:
	if int(steamer["down_hours"]) > 0:
		return err("The autoclaves are down for another %d hours." % int(steamer["down_hours"]))
	if int(steamer["hours_left"]) > 0:
		return err("The autoclaves are already running, %d hours left." % int(steamer["hours_left"]))
	if int(steamer["load"]) > 0:
		return err("A steamed load is still in the autoclaves, waiting for the cooling room.")
	if q_prepared <= 0:
		return err("No prepared bags are waiting.")
	if power_cut_hours > 0:
		return err("The power is out.")
	if not _water_available(float(c["steam_water_l"])):
		return err("There is not enough water for steam: the mains are off and the tank is low.")
	_draw_water(float(c["steam_water_l"]))
	var load_n: int = mini(int(c["steamer_capacity"]), q_prepared)
	q_prepared -= load_n
	steamer["load"] = load_n
	steamer["hours_left"] = int(c["steam_hours"])
	_log("Steam: started with %d bags." % load_n)
	return ok("Steaming %d bags; done in %d hours, then they cool." % [load_n, int(steamer["hours_left"])])


func _new_day() -> void:
	today["day"] = day() - 1
	daily.append(today)
	if daily.size() > 120:
		daily.pop_front()
	today = _blank_day()
	prepared_today = 0
	yesterday_max = today_max
	today_max = 0.0
	drift = clampf(drift * 0.8 + rng.randfn(0.0, 0.5), -1.5, 1.5)
	if heat_days > 0:
		heat_days -= 1
		if heat_days == 0:
			_log("The heat wave is over.")
	_spend(float(c["wage_per_day"]) * int(c["workers"]))
	for dl in deliveries.duplicate():
		if day() >= int(dl["day"]):
			for key in ["sawdust_kg", "dedak_kg", "calcium_kg"]:
				stock[key] = float(stock[key]) + float(dl[key])
			stock["sawdust_kg"] = minf(float(stock["sawdust_kg"]), float(c["sawdust_capacity_kg"]))
			deliveries.erase(dl)
			_log("Delivery: the materials order has arrived.")
	for k in containers:
		if float(k["picked_today"]) > 0.0:
			_room_log(k, "Harvest", "%d kg picked." % int(round(float(k["picked_today"]))))
			k["picked_today"] = 0.0
	spawn = minf(spawn + float(c["lab_spawn_per_day"]), float(c["lab_capacity"]))
	# Incubation: inspect, remove infected bags, find the batches that have matured.
	# A very hot day makes infection more likely (assumed).
	var dtm := int(c["days_to_maturity"])
	var hazard: float = 1.0 - pow(1.0 - float(c["removal_rate"]), 1.0 / dtm)
	hazard *= 1.0 + 0.08 * maxf(yesterday_max - 32.0, 0.0)
	if outbreak_days > 0:
		hazard *= float(c["outbreak_factor"])
		outbreak_days -= 1
		if outbreak_days == 0:
			_log("The contamination outbreak is over.")
	for b in incubation:
		var lost: int = mini(int(b["bags"]), int(int(b["bags"]) * hazard + rng.randf()))
		if lost > 0:
			b["bags"] = int(b["bags"]) - lost
			today["removed"] = int(today["removed"]) + lost
			totals["removed"] = int(totals["removed"]) + lost
		if not b["ready"] and day() - int(b["day0"]) >= dtm:
			b["ready"] = true
	if auto_move_in:
		for b in incubation.duplicate():
			if b["ready"]:
				var k = _roomiest()
				if k != null and container_free(k) >= int(b["bags"]):
					_move_in(b, k)
	# Fruiting: a flush comes ripe; a batch that has given its last flush is removed.
	var ys: Array = c["flush_yield_g"]
	for k in containers:
		for b in k["batches"].duplicate():
			if int(b["flush"]) < ys.size() and day() >= int(b["next_flush_day"]):
				var share: float = 1.0 if int(b["hours"]) == 0 else float(b["good"]) / float(b["hours"])
				var factor: float = float(c["yield_floor"]) + (1.0 - float(c["yield_floor"])) * share
				b["ripe_kg"] = float(b["ripe_kg"]) + int(b["bags"]) * float(ys[int(b["flush"])]) / 1000.0 * factor
				b["ripe_hour"] = hour
				b["flush"] = int(b["flush"]) + 1
				b["next_flush_day"] = day() + int(c["flush_gap_days"])
				b["good"] = 0
				b["hours"] = 0
				b["factor"] = factor
				_room_log(k, "Inspection", "Batch %d: flush %d is ripe. Room in range %d%% of the time." % [int(b["id"]), int(b["flush"]), int(round(share * 100.0))])
			elif int(b["flush"]) >= ys.size() and float(b["ripe_kg"]) <= 0.0:
				k["batches"].erase(b)
				totals["spent"] = int(totals["spent"]) + int(b["bags"])
				_log("Removal: batch %d (%d spent bags) left %s." % [int(b["id"]), int(b["bags"]), k["name"]])
				_room_log(k, "Removal", "Batch %d: %d spent bags taken out." % [int(b["id"]), int(b["bags"])])


func _roomiest():
	var best = null
	for k in containers:
		if best == null or container_free(k) > container_free(best):
			best = k
	return best


func _move_in(b: Dictionary, k: Dictionary) -> void:
	incubation.erase(b)
	k["batches"].append({"id": b["id"], "bags": b["bags"], "day_in": day(), "flush": 0,
		"next_flush_day": day() + int(c["first_flush_days"]), "ripe_kg": 0.0, "ripe_hour": hour, "good": 0, "hours": 0, "factor": PLAN_FACTOR})
	_log("Move In: batch %d (%d bags) to %s. Caps opened." % [int(b["id"]), int(b["bags"]), k["name"]])
	flows.append(["incubation", k["name"]])
	_room_log(k, "Move In", "Batch %d: %d bags moved in." % [int(b["id"]), int(b["bags"])])
	_room_log(k, "Open Cap", "Batch %d: caps opened." % int(b["id"]))


func _climate(k: Dictionary, h: int, power: bool) -> void:
	# 1. The room's own climate: its usual level for the hour plus a disturbance that fades (fitted),
	#    pushed by the weather outside (assumed).
	var base := {}
	for v in VARS:
		var p: Dictionary = climate[v]
		var phi1: float = p["phi"]
		var sd: float = float(p["noise_sd"]) * sqrt((1.0 - pow(phi1, 12.0)) / (1.0 - phi1 * phi1))
		k["d"][v] = pow(phi1, 6.0) * float(k["d"][v]) + rng.randfn(0.0, sd)
	k["d"]["humidity"] = clampf(float(k["d"]["humidity"]), -12.0, 8.0)
	k["d"]["CO2"] = clampf(float(k["d"]["CO2"]), -200.0, 500.0)
	var out_t: float = weather["temp"]
	var out_rh: float = weather["humidity"]
	var midday: float = 0.6 * (float(weather["sun"]) - 0.7) if h >= 10 and h < 16 else 0.0
	base["temperature"] = usual("temperature", float(h)) + float(k["d"]["temperature"]) + 0.45 * (out_t - float(weather["typical"])) + midday
	base["humidity"] = usual("humidity", float(h)) + float(k["d"]["humidity"]) + 0.1 * (out_rh - 80.0)
	base["CO2"] = usual("CO2", float(h)) + float(k["d"]["CO2"]) + float(c["crop_co2_ppm"]) * container_bags(k) / float(c["container_capacity"])
	var act: Dictionary = k["act"]
	var vent_dry: float = float(fx["vent1"]["humidity"]) * clampf((95.0 - out_rh) / 25.0, 0.1, 1.4)   # vents dry the room less when it rains
	var gain: float = fx["humidifier"]["humidity"]
	var cool_c: float = c["aircond_cooling_c"]
	var light_on: bool = bool(act["light"]) and power
	var t0: float = float(base["temperature"]) + (float(fx["light"]["temperature"]) if light_on else 0.0)
	# 2. The container's automation (assumed rules): vents open as far as the CO2 limit needs, the aircond
	#    holds the temperature limit, and the humidifier cycles to hold the middle of the humidity range.
	var duty := 1.0 if act["humidifier"] else 0.0
	var ac := 1.0 if act["aircond"] else 0.0
	if k["auto"]:
		var outside_co2: float = fx["outside_CO2"]
		var keep1: float = 1.0 + float(fx["vent1"]["CO2_excess_fraction"])
		var raw: float = base["CO2"]
		act["vent1"] = raw > float(c["co2_limit"]) - 60.0
		act["vent2"] = outside_co2 + (raw - outside_co2) * keep1 > float(c["co2_limit"]) - 60.0
		ac = clampf((t0 - (float(c["temp_limit"]) - 1.0)) / cool_c, 0.0, 1.0)
		act["aircond"] = ac > 0.03
		var open_vents: int = int(bool(act["vent1"])) + int(bool(act["vent2"]))
		var dry: float = float(base["humidity"]) + vent_dry * open_vents - 3.0 * ac
		var mid: float = (float(c["humidity_low"]) + float(c["humidity_high"])) / 2.0
		duty = clampf((mid - dry) / gain, 0.0, 1.0)
		act["humidifier"] = duty > 0.03
	# 3. What actually runs: nothing without power, no mist without water or with a failed humidifier.
	var vents: int = int(bool(act["vent1"])) + int(bool(act["vent2"]))
	var spray := 1.0 if act["spray"] else 0.0
	if not power:
		vents = 0
		duty = 0.0
		ac = 0.0
		spray = 0.0
	if int(k["fault_hours"]) > 0:
		duty = 0.0
	var need: float = float(c["humidifier_l_per_hour"]) * duty + float(c["spray_l_per_hour"]) * spray
	if need > 0.0:
		var share: float = _draw_water(need) / need
		duty *= share
		spray *= share
	# 4. What the actuators do to the room (assumed effects, see data/params.json).
	var rh: float = float(base["humidity"]) + gain * duty + float(fx["spray"]["humidity"]) * spray + vent_dry * vents - 3.0 * ac
	var t: float = t0 + float(fx["humidifier"]["temperature"]) * duty + float(fx["spray"]["temperature"]) * spray - cool_c * ac
	var co2: float = base["CO2"]
	if vents > 0:
		var keep: float = pow(1.0 + float(fx["vent1"]["CO2_excess_fraction"]), vents)
		co2 = float(fx["outside_CO2"]) + (co2 - float(fx["outside_CO2"])) * keep
	k["humidity"] = clampf(rh, 30.0, 99.9)
	k["temperature"] = clampf(t, 18.0, 42.0)
	k["CO2"] = maxf(co2, 380.0)
	k["duty"] = duty
	k["ac"] = ac
	kwh_now += float(c["humidifier_kw"]) * duty + float(c["vent_kw"]) * vents + float(c["aircond_kw"]) * ac + (float(c["light_kw"]) if light_on else 0.0)
	if int(k["fault_hours"]) > 0:
		k["fault_hours"] = int(k["fault_hours"]) - 1
		if int(k["fault_hours"]) == 0:
			_log("%s: the humidifier is repaired." % k["name"])
			_room_log(k, "Repair", "The humidifier is repaired.")
	var good := in_range(k)
	for b in k["batches"]:
		b["hours"] = int(b["hours"]) + 1
		if good:
			b["good"] = int(b["good"]) + 1


func _spoil(k: Dictionary) -> void:
	for b in k["batches"]:
		if float(b["ripe_kg"]) > 0.0 and hour - int(b["ripe_hour"]) >= int(c["ripe_hold_hours"]):
			var kg: float = b["ripe_kg"]
			b["ripe_kg"] = 0.0
			today["lost_kg"] = float(today["lost_kg"]) + kg
			totals["lost_kg"] = float(totals["lost_kg"]) + kg
			_log("%s: %d kg spoiled before it was picked." % [k["name"], int(kg)])
			_room_log(k, "Inspection", "%d kg spoiled before it was picked." % int(kg))


# ---------------------------------------------------------------- what the manager reads

func forecast(days: int) -> Array:
	# Expected harvest per day from every bag already in the pipeline.
	var out := []
	out.resize(days)
	out.fill(0.0)
	var ys: Array = c["flush_yield_g"]
	var gap := int(c["flush_gap_days"])
	var d0 := day()
	for k in containers:
		for b in k["batches"]:
			if float(b["ripe_kg"]) > 0.0:
				out[0] = float(out[0]) + float(b["ripe_kg"])
			var when: int = int(b["next_flush_day"])
			for f in range(int(b["flush"]), ys.size()):
				var i: int = maxi(when - d0, 0)
				if i < days:
					out[i] = float(out[i]) + int(b["bags"]) * float(ys[f]) / 1000.0 * PLAN_FACTOR
				when += gap
	var dtm := int(c["days_to_maturity"])
	for b in incubation:
		var mature: int = maxi(int(b["day0"]) + dtm, d0)
		var survive: float = pow(1.0 - float(c["removal_rate"]), float(mature - d0) / dtm)
		var when: int = mature + int(c["first_flush_days"])
		for f in ys.size():
			var i: int = when - d0
			if i >= 0 and i < days:
				out[i] = float(out[i]) + int(b["bags"]) * survive * float(ys[f]) / 1000.0 * PLAN_FACTOR
			when += gap
	return out


func week() -> Dictionary:
	# Daily averages over the last seven finished days.
	var out := {"prepared": 0.0, "seeded": 0.0, "removed": 0.0, "kg": 0.0, "lost_kg": 0.0, "kwh": 0.0, "water_l": 0.0, "rain_mm": 0.0}
	var rows: Array = daily.slice(maxi(daily.size() - 7, 0))
	for r in rows:
		for key in out:
			out[key] = float(out[key]) + float(r[key])
	for key in out:
		out[key] = snappedf(float(out[key]) / maxf(rows.size(), 1.0), 0.1)
	return out


func utility_cost_per_kg() -> float:
	return (float(totals["power_rm"]) + float(totals["water_rm"])) / maxf(float(totals["kg"]), 1.0)


func bottleneck() -> String:
	if power_cut_hours > 0:
		return "The power is out (%d h)" % power_cut_hours
	if int(steamer["down_hours"]) > 0:
		return "Autoclaves are down (%d h)" % int(steamer["down_hours"])
	if bags_of_materials() < 1:
		return "Materials have run out: order sawdust, dedak padi or calcium carbonate"
	if water_cut_hours > 0 and tank_l < 300.0:
		return "No water: the mains are off and the tank is low"
	if int(steamer["load"]) > 0 and int(steamer["hours_left"]) == 0:
		return "Cooling room is full: a steamed load is waiting in the autoclaves"
	if ready_bags() > 0 and not auto_move_in:
		return "%d bags ready, waiting for Move In" % ready_bags()
	if ready_bags() > 0:
		return "Fruiting space: %d bags ready, no container has room" % ready_bags()
	if ripe_kg() > float(c["harvest_rate"]) * int(staff()["harvest"]) * (int(c["work_end"]) - int(c["work_start"])):
		return "Harvest: more ripe than the pickers can pick today"
	if q_prepared > 2 * int(c["steamer_capacity"]):
		return "Autoclaves: %d bags waiting" % q_prepared
	if q_cooled > int(c["seeding_rate"]) * int(staff()["seeding"]) * (int(c["work_end"]) - int(c["work_start"])):
		return "Seeding: %d cooled bags waiting" % q_cooled
	if spawn * float(c["bags_per_spawn"]) < target * 2.0:
		return "Lab: spawn covers under 2 days"
	if int(c["incubation_capacity"]) - incubation_bags() < target:
		return "Incubation rooms are full"
	return "None"


func faults() -> Array:
	var out := []
	if power_cut_hours > 0:
		out.append("Power cut, %d hours left" % power_cut_hours)
	if water_cut_hours > 0:
		out.append("Mains water off, %d hours left" % water_cut_hours)
	if heat_days > 0:
		out.append("Heat wave, %d days left" % heat_days)
	if int(steamer["down_hours"]) > 0:
		out.append("Autoclaves down, %d hours left" % int(steamer["down_hours"]))
	if outbreak_days > 0:
		out.append("Contamination outbreak in incubation, %d days left" % outbreak_days)
	if absent > 0:
		out.append("%d workers absent, %d hours left" % [absent, absent_hours])
	for k in containers:
		if int(k["fault_hours"]) > 0:
			out.append("%s humidifier failed, %d hours left" % [k["name"], int(k["fault_hours"])])
	return out


func snapshot() -> Dictionary:
	var ready := []
	for b in incubation:
		if b["ready"]:
			ready.append({"batch_id": b["id"], "bags": b["bags"]})
	var rooms := []
	for k in containers:
		var on := []
		for a in ACTUATORS:
			if k["act"][a]:
				on.append(a)
		rooms.append({"name": k["name"], "bags": container_bags(k), "free": container_free(k), "ripe_kg": snappedf(container_ripe(k), 0.1),
			"humidity": snappedf(float(k["humidity"]), 0.1), "temperature": snappedf(float(k["temperature"]), 0.1), "CO2": int(k["CO2"]),
			"in_range": in_range(k), "automation": k["auto"], "actuators_on": on})
	var f := forecast(14)
	var f14 := 0.0
	for v in f:
		f14 += float(v)
	var settings := {}
	for key in order:
		settings[key] = c[key]
	return {
		"time": stamp(hour), "working_hours": is_work_hour(),
		"weather": {"now": weather["state"], "outside_temp": snappedf(float(weather["temp"]), 0.1), "outside_humidity": snappedf(float(weather["humidity"]), 1.0),
			"rain_mm_per_hour": weather["rain_mm"], "outlook": weather_outlook()},
		"plan": {"daily_target_bags": target, "workers_total": int(c["workers"]), "workers_absent": absent, "workers_on": alloc,
			"auto_steam": auto_steam, "auto_move_in": auto_move_in,
			"fruiting_targets": {"humidity_low": c["humidity_low"], "humidity_high": c["humidity_high"], "co2_limit": c["co2_limit"], "temp_limit": c["temp_limit"]}},
		"lab": {"spawn_units": snappedf(spawn, 0.1)},
		"materials": {"sawdust_kg": snappedf(float(stock["sawdust_kg"]), 1.0), "dedak_padi_guni": snappedf(float(stock["dedak_kg"]) / float(c["dedak_guni_kg"]), 0.1),
			"calcium_carbonate_guni": snappedf(float(stock["calcium_kg"]) / float(c["calcium_guni_kg"]), 0.1), "enough_for_bags": bags_of_materials(), "on_order": deliveries},
		"production": {"prepared_today": prepared_today, "waiting_for_steam": q_prepared, "autoclaves": steamer, "cooling_room": cooling, "cooled_waiting_for_seeding": q_cooled},
		"incubation": {"bags": incubation_bags(), "capacity": int(c["incubation_capacity"]), "batches": incubation.size(), "ready_for_move_in": ready},
		"fruiting": rooms,
		"utilities": {"power_now_kw": snappedf(kwh_now, 0.1), "kwh_today": snappedf(float(today["kwh"]), 1.0), "water_today_l": snappedf(float(today["water_l"]), 1.0),
			"tank_l": snappedf(tank_l, 1.0), "tank_capacity_l": c["tank_capacity_l"], "power_cut_hours": power_cut_hours, "mains_water_off_hours": water_cut_hours,
			"utility_cost_rm_per_kg": snappedf(utility_cost_per_kg(), 0.01)},
		"daily_average_last_7_days": week(),
		"since_start": {"kg_harvested": snappedf(float(totals["kg"]), 0.1), "kg_spoiled": snappedf(float(totals["lost_kg"]), 0.1),
			"bags_seeded": totals["seeded"], "bags_removed_infected": totals["removed"], "cash_rm": snappedf(cash(), 1.0),
			"electricity_rm": snappedf(float(totals["power_rm"]), 1.0), "water_rm": snappedf(float(totals["water_rm"]), 1.0)},
		"harvest_forecast_next_14_days_kg": snappedf(f14, 1.0),
		"bottleneck": bottleneck(), "faults": faults(), "settings": settings,
	}


# ---------------------------------------------------------------- tools (the manager's buttons and the AI's hands)

func ok(result) -> Dictionary:
	return {"ok": true, "result": result}


func err(why: String) -> Dictionary:
	return {"ok": false, "error": why}


func tools_spec() -> Array:
	var room_names := ["all"]
	for k in containers:
		room_names.append(k["name"])
	return [
		_tool("get_state", "Read the whole farm now: weather and outlook, plan, queues, autoclaves, incubation, each fruiting container, utilities, forecast, bottleneck and faults.", {}, []),
		_tool("set_target", "Set how many bags the production line prepares per day.", {"bags": {"type": "integer"}}, ["bags"]),
		_tool("assign_workers", "Put workers on the three jobs. The total cannot exceed the workers on the farm.",
			{"prepare": {"type": "integer"}, "seeding": {"type": "integer"}, "harvest": {"type": "integer"}}, ["prepare", "seeding", "harvest"]),
		_tool("start_steam", "Start the autoclaves now with the prepared bags that are waiting.", {}, []),
		_tool("set_policy", "Turn the standing rules on or off: auto_steam starts the autoclaves when a full load is waiting or the day ends; auto_move_in moves matured batches into the container with most room.",
			{"auto_steam": {"type": "boolean"}, "auto_move_in": {"type": "boolean"}}, []),
		_tool("move_in", "Move a matured incubation batch into a fruiting container and open its caps.",
			{"batch_id": {"type": "integer"}, "container": {"type": "string"}}, ["batch_id", "container"]),
		_tool("set_climate", "Control a fruiting container. automation=true lets the container run its own humidifier, vents and aircond. Naming any actuator switches that container to manual.",
			{"container": {"type": "string", "enum": room_names}, "automation": {"type": "boolean"}, "humidifier": {"type": "boolean"}, "spray": {"type": "boolean"},
			"vent1": {"type": "boolean"}, "vent2": {"type": "boolean"}, "aircond": {"type": "boolean"}, "light": {"type": "boolean"}}, ["container"]),
		_tool("order_materials", "Order raw materials for the bag line. They arrive after the delivery time and are paid for now.",
			{"sawdust_tonnes": {"type": "number"}, "dedak_guni": {"type": "integer"}, "calcium_guni": {"type": "integer"}}, []),
		_tool("set_fruiting_targets", "Set what the container automation aims for: the humidity range in %RH, the CO2 limit in ppm and the temperature limit in C. A higher temperature limit saves aircond electricity but costs yield when rooms run hot.",
			{"humidity_low": {"type": "number"}, "humidity_high": {"type": "number"}, "co2_limit": {"type": "number"}, "temp_limit": {"type": "number"}}, []),
	]


func _tool(tool_name: String, about: String, props: Dictionary, required: Array) -> Dictionary:
	return {"type": "function", "function": {"name": tool_name, "description": about, "parameters": {"type": "object", "properties": props, "required": required}}}


func call_tool(tool_name: String, a: Dictionary) -> Dictionary:
	match tool_name:
		"get_state":
			return ok(snapshot())
		"set_target":
			var n := int(a.get("bags", -1))
			if n < 0 or n > 5000:
				return err("bags must be between 0 and 5000.")
			target = n
			_log("Plan: daily target set to %d bags." % n)
			return ok("The daily target is now %d bags." % n)
		"assign_workers":
			var plan := {}
			var sum := 0
			for job in JOBS:
				var n := int(a.get(job, -1))
				if n < 0:
					return err("Give a number of workers for prepare, seeding and harvest.")
				plan[job] = n
				sum += n
			if sum > int(c["workers"]):
				return err("That needs %d workers and the farm has %d." % [sum, int(c["workers"])])
			alloc = plan
			_log("Plan: workers set to prepare %d, seeding %d, harvest %d." % [int(plan["prepare"]), int(plan["seeding"]), int(plan["harvest"])])
			return ok("Workers: prepare %d, seeding %d, harvest %d." % [int(plan["prepare"]), int(plan["seeding"]), int(plan["harvest"])])
		"start_steam":
			return start_steam()
		"set_policy":
			if not a.has("auto_steam") and not a.has("auto_move_in"):
				return err("Name auto_steam or auto_move_in.")
			if a.has("auto_steam"):
				auto_steam = bool(a["auto_steam"])
			if a.has("auto_move_in"):
				auto_move_in = bool(a["auto_move_in"])
			_log("Plan: auto steam %s, auto move-in %s." % ["on" if auto_steam else "off", "on" if auto_move_in else "off"])
			return ok("Auto steam is %s; auto move-in is %s." % ["on" if auto_steam else "off", "on" if auto_move_in else "off"])
		"move_in":
			var k = _room(str(a.get("container", "")))
			if k == null:
				return err("There is no container with that name.")
			for b in incubation:
				if int(b["id"]) == int(a.get("batch_id", -1)):
					if not b["ready"]:
						return err("Batch %d has not matured yet." % int(b["id"]))
					if container_free(k) < int(b["bags"]):
						return err("%s has room for %d bags and the batch has %d." % [k["name"], container_free(k), int(b["bags"])])
					_move_in(b, k)
					return ok("Batch %d moved into %s." % [int(b["id"]), k["name"]])
			return err("There is no incubation batch with that id.")
		"set_climate":
			var which := str(a.get("container", ""))
			var rooms := []
			if which == "all":
				rooms = containers
			elif _room(which) != null:
				rooms = [_room(which)]
			else:
				return err("There is no container with that name.")
			var said := []
			for act_name in ACTUATORS:
				if a.has(act_name):
					said.append("%s %s" % [act_name, "on" if bool(a[act_name]) else "off"])
			for k in rooms:
				for act_name in ACTUATORS:
					if a.has(act_name):
						k["act"][act_name] = bool(a[act_name])
						k["auto"] = false
				if a.has("automation"):
					k["auto"] = bool(a["automation"])
				_room_log(k, "Climate", "Set by hand or by the steward: %s." % ", ".join(said))
			if a.has("automation"):
				said.append("automation %s" % ("on" if bool(a["automation"]) else "off"))
			elif not said.is_empty():
				said.append("automation off (manual)")
			if said.is_empty():
				return err("Name automation or at least one actuator.")
			_log("Climate %s: %s." % [which, ", ".join(said)])
			return ok("%s: %s." % [which, ", ".join(said)])
		"order_materials":
			var tonnes := float(a.get("sawdust_tonnes", 0.0))
			var dedak := int(a.get("dedak_guni", 0))
			var calcium := int(a.get("calcium_guni", 0))
			if tonnes < 0.0 or dedak < 0 or calcium < 0 or (tonnes == 0.0 and dedak == 0 and calcium == 0):
				return err("Order at least one of sawdust_tonnes, dedak_guni or calcium_guni.")
			if tonnes > 25.0 or dedak > 400 or calcium > 400:
				return err("That order is too large for one delivery.")
			var rm: float = tonnes * float(c["sawdust_rm_per_tonne"]) + dedak * float(c["dedak_rm_per_guni"]) + calcium * float(c["calcium_rm_per_guni"])
			_spend(rm)
			deliveries.append({"day": day() + int(c["delivery_days"]), "sawdust_kg": tonnes * 1000.0, "dedak_kg": dedak * float(c["dedak_guni_kg"]),
				"calcium_kg": calcium * float(c["calcium_guni_kg"])})
			_log("Ordered %.1f t sawdust, %d guni dedak padi, %d guni calcium carbonate for RM %d." % [tonnes, dedak, calcium, int(rm)])
			return ok("Ordered for RM %d; it arrives on day %d." % [int(rm), day() + int(c["delivery_days"])])
		"set_fruiting_targets":
			var lo := float(a.get("humidity_low", c["humidity_low"]))
			var hi := float(a.get("humidity_high", c["humidity_high"]))
			var co2 := float(a.get("co2_limit", c["co2_limit"]))
			var tl := float(a.get("temp_limit", c["temp_limit"]))
			if lo < 60.0 or hi > 99.0 or lo >= hi:
				return err("Give a humidity range between 60 and 99 with low under high.")
			if co2 < 500.0 or co2 > 5000.0:
				return err("Give a CO2 limit between 500 and 5000 ppm.")
			if tl < 22.0 or tl > 38.0:
				return err("Give a temperature limit between 22 and 38 C.")
			c["humidity_low"] = lo
			c["humidity_high"] = hi
			c["co2_limit"] = co2
			c["temp_limit"] = tl
			_log("Climate targets: humidity %d to %d %%RH, CO2 under %d ppm, temperature under %.1f C." % [int(lo), int(hi), int(co2), tl])
			return ok("Targets: humidity %d to %d %%RH, CO2 under %d ppm, temperature under %.1f C." % [int(lo), int(hi), int(co2), tl])
	return err("There is no tool called %s." % tool_name)


func _room(room_name: String):
	for k in containers:
		if str(k["name"]).to_lower() == room_name.to_lower():
			return k
	return null


# ---------------------------------------------------------------- what-ifs

const WHAT_IFS := {
	"steamer": "the autoclaves break down for 2 days",
	"outbreak": "a contamination outbreak hits incubation for 10 days",
	"humidifier": "the humidifier in the first container fails for 3 days",
	"absent": "two workers are absent for 3 days",
	"heat": "a heat wave lasts 5 days",
	"storm": "a storm sits over the farm for 9 hours",
	"power": "the power is cut for 8 hours",
	"water": "the mains water is off for 2 days",
}


func fault(kind: String) -> String:
	if not WHAT_IFS.has(kind):
		return ""
	match kind:
		"steamer":
			steamer["down_hours"] = 48
		"outbreak":
			outbreak_days = 10
		"humidifier":
			containers[0]["fault_hours"] = 72
			_room_log(containers[0], "Fault", "The humidifier failed.")
		"absent":
			absent = mini(2, int(c["workers"]))
			absent_hours = 72
		"heat":
			heat_days = 5
		"storm":
			for i in mini(9, sky.size()):
				sky[i] = "storm"
			weather = outside(hour, sky[0])
		"power":
			power_cut_hours = 8
		"water":
			water_cut_hours = 48
	var text: String = "What if: %s." % WHAT_IFS[kind]
	_log(text)
	return text
