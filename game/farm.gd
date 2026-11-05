extends RefCounted
## The farm simulation. Bags flow through OINC's own steps:
##   Lab (spawn) -> Prepare -> Steam -> Seeding -> Incubation -> Move In / Open Cap -> Harvest -> Removal
## One step is one hour. Everything a manager or the AI steward can change goes through
## call_tool(), so the AI can do what the manager's buttons can do and nothing more.
##
## Numbers come from data/farm.json (mostly assumed, each one labelled) and from
## data/params.json (the daily climate fitted from a real container's sensor log).

const VARS := ["temperature", "humidity", "CO2"]
const ACTUATORS := ["humidifier", "spray", "vent1", "vent2", "light", "pump", "fill"]
const JOBS := ["prepare", "seeding", "harvest"]
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
var q_prepared := 0  # bags waiting for the steamer
var q_cooled := 0    # sterilised bags waiting for seeding
var steamer := {"load": 0, "hours_left": 0, "down_hours": 0}   # the two autoclaves, loaded together
var cooling := {"load": 0, "hours_left": 0}                    # the cooling room holds one steamed load
var spawn := 0.0
var incubation := [] # batches: {id, bags, day0, ready}
var containers := []
var auto_steam := true
var auto_move_in := true
var outbreak_days := 0
var next_id := 1
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
		containers.append({"name": str(names[i]) if i < names.size() else "C%d" % (i + 1), "batches": [], "d": {"temperature": 0.0, "humidity": 0.0, "CO2": 0.0},
			"temperature": 28.0, "humidity": 88.0, "CO2": 700.0, "act": act, "auto": true, "fault_hours": 0})
	auto_steam = true
	auto_move_in = true
	outbreak_days = 0
	next_id = 1
	_blank_books()
	# Warm start: run the farm quietly so the manager begins with a full pipeline, then call that day 0.
	quiet = true
	for i in warm_days * 24:
		step()
	hour = 0
	for b in incubation:
		b["day0"] = int(b["day0"]) - warm_days
	for k in containers:
		for b in k["batches"]:
			b["day_in"] = int(b["day_in"]) - warm_days
			b["next_flush_day"] = int(b["next_flush_day"]) - warm_days
			b["ripe_hour"] = int(b["ripe_hour"]) - warm_days * 24
	for i in 7:
		step()
	quiet = false
	_blank_books()
	flows = []
	events = []
	events_total = 0
	_log("The farm is running. %d bags are incubating and %d are fruiting." % [incubation_bags(), fruiting_bags()])


func _blank_books() -> void:
	totals = {"prepared": 0, "seeded": 0, "removed": 0, "spent": 0, "kg": 0.0, "lost_kg": 0.0, "revenue": 0.0, "cost": 0.0}
	today = _blank_day()
	daily = []


func _blank_day() -> Dictionary:
	return {"day": day(), "prepared": 0, "seeded": 0, "removed": 0, "kg": 0.0, "lost_kg": 0.0}


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
		and float(k["CO2"]) <= float(c["co2_limit"])


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


# ---------------------------------------------------------------- one hour

func step() -> void:
	hour += 1
	var h := hod()
	if h == 0:
		_new_day()
	if is_work_hour():
		_work(staff())
	_steam(h)
	for k in containers:
		_climate(k, h)
		_spoil(k)
	if absent_hours > 0:
		absent_hours -= 1
		if absent_hours == 0:
			absent = 0
			_log("The absent workers are back.")


func _work(st: Dictionary) -> void:
	# Prepare: mix the substrate and fill bags, up to the day's target.
	var n: int = mini(int(c["prepare_rate"]) * int(st["prepare"]), target - prepared_today)
	if n > 0:
		q_prepared += n
		prepared_today += n
		_spend(n * float(c["cost_per_bag"]))
		today["prepared"] = int(today["prepared"]) + n
		totals["prepared"] = int(totals["prepared"]) + n
		flows.append(["prepare", "steamer"])
	# Seeding: put spawn into the cooled bags and shelve them in incubation.
	var room: int = int(c["incubation_capacity"]) - incubation_bags()
	n = mini(mini(q_cooled, int(c["seeding_rate"]) * int(st["seeding"])), mini(int(spawn * float(c["bags_per_spawn"])), room))
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
				flows.append([k["name"], "packing"])


func _todays_batch() -> Dictionary:
	if not incubation.is_empty() and int(incubation[-1]["day0"]) == day():
		return incubation[-1]
	var b := {"id": next_id, "bags": 0, "day0": day(), "ready": false}
	next_id += 1
	incubation.append(b)
	return b


func _steam(h: int) -> void:
	# Cooling room: a steamed load cools there, then waits there for seeding.
	if int(cooling["hours_left"]) > 0:
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
		steamer["hours_left"] = int(steamer["hours_left"]) - 1
		if int(steamer["hours_left"]) > 0:
			return
	if int(steamer["load"]) > 0:
		# Steamed. The load moves on only when the cooling room is empty.
		if int(cooling["load"]) == 0 and q_cooled == 0:
			cooling["load"] = int(steamer["load"])
			cooling["hours_left"] = int(c["cool_hours"])
			_log("Steam: %d bags sterilised and moved to the cooling room." % int(steamer["load"]))
			steamer["load"] = 0
			flows.append(["steamer", "cooling"])
		return
	if auto_steam and (q_prepared >= int(c["steamer_capacity"]) or (h == int(c["work_end"]) and q_prepared > 0)):
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
	_spend(float(c["wage_per_day"]) * int(c["workers"]))
	spawn = minf(spawn + float(c["lab_spawn_per_day"]), float(c["lab_capacity"]))
	# Incubation: inspect, remove infected bags, find the batches that have matured.
	var dtm := int(c["days_to_maturity"])
	var hazard: float = 1.0 - pow(1.0 - float(c["removal_rate"]), 1.0 / dtm)
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
			elif int(b["flush"]) >= ys.size() and float(b["ripe_kg"]) <= 0.0:
				k["batches"].erase(b)
				totals["spent"] = int(totals["spent"]) + int(b["bags"])
				_log("Removal: batch %d (%d spent bags) left %s." % [int(b["id"]), int(b["bags"]), k["name"]])


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


func _climate(k: Dictionary, h: int) -> void:
	# 1. The room's own climate: its usual level for the hour plus a disturbance that fades (fitted).
	var base := {}
	for v in VARS:
		var p: Dictionary = climate[v]
		var phi1: float = p["phi"]
		var sd: float = float(p["noise_sd"]) * sqrt((1.0 - pow(phi1, 12.0)) / (1.0 - phi1 * phi1))
		k["d"][v] = pow(phi1, 6.0) * float(k["d"][v]) + rng.randfn(0.0, sd)
		base[v] = usual(v, float(h)) + float(k["d"][v])
	k["d"]["humidity"] = clampf(float(k["d"]["humidity"]), -18.0, 12.0)
	k["d"]["CO2"] = clampf(float(k["d"]["CO2"]), -200.0, 800.0)
	base["humidity"] = usual("humidity", float(h)) + float(k["d"]["humidity"])
	base["CO2"] = usual("CO2", float(h)) + float(k["d"]["CO2"]) + float(c["crop_co2_ppm"]) * container_bags(k) / float(c["container_capacity"])
	# 2. The container's automation, working from the last reading (assumed rules).
	var act: Dictionary = k["act"]
	if k["auto"]:
		var mid: float = (float(c["humidity_low"]) + float(c["humidity_high"])) / 2.0
		if float(k["humidity"]) < float(c["humidity_low"]) + 2.0:
			act["humidifier"] = true
		elif float(k["humidity"]) > mid + 2.0:
			act["humidifier"] = false
		if float(k["CO2"]) > float(c["co2_limit"]) - 50.0:
			act["vent1"] = true
		elif float(k["CO2"]) < float(c["co2_limit"]) - 300.0:
			act["vent1"] = false
		act["vent2"] = float(k["CO2"]) > float(c["co2_limit"]) + 400.0
	# 3. What the actuators do to the room (assumed effects, see data/params.json).
	var hum_ok: bool = bool(act["humidifier"]) and int(k["fault_hours"]) == 0
	var rh: float = base["humidity"]
	var t: float = base["temperature"]
	var co2: float = base["CO2"]
	if hum_ok:
		rh += float(fx["humidifier"]["humidity"])
		t += float(fx["humidifier"]["temperature"])
	if act["spray"]:
		rh += float(fx["spray"]["humidity"])
		t += float(fx["spray"]["temperature"])
	if act["light"]:
		t += float(fx["light"]["temperature"])
	var vents: int = int(bool(act["vent1"])) + int(bool(act["vent2"]))
	if vents > 0:
		rh += float(fx["vent1"]["humidity"]) * vents
		var keep: float = pow(1.0 + float(fx["vent1"]["CO2_excess_fraction"]), vents)
		co2 = float(fx["outside_CO2"]) + (co2 - float(fx["outside_CO2"])) * keep
	k["humidity"] = clampf(rh, 30.0, 99.9)
	k["temperature"] = clampf(t, 20.0, 40.0)
	k["CO2"] = maxf(co2, 380.0)
	if int(k["fault_hours"]) > 0:
		k["fault_hours"] = int(k["fault_hours"]) - 1
		if int(k["fault_hours"]) == 0:
			_log("%s: the humidifier is repaired." % k["name"])
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


func bottleneck() -> String:
	if int(steamer["down_hours"]) > 0:
		return "Autoclaves are down (%d h)" % int(steamer["down_hours"])
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
		return "Incubation room is full"
	return "None"


func faults() -> Array:
	var out := []
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
	var last7 := {"prepared": 0, "seeded": 0, "removed": 0, "kg": 0.0, "lost_kg": 0.0}
	for r in daily.slice(maxi(daily.size() - 7, 0)):
		for key in last7:
			last7[key] = snappedf(float(last7[key]) + float(r[key]), 0.1)
	var f := forecast(14)
	var f14 := 0.0
	for v in f:
		f14 += float(v)
	var settings := {}
	for key in order:
		settings[key] = c[key]
	return {
		"time": stamp(hour), "working_hours": is_work_hour(),
		"plan": {"daily_target_bags": target, "workers_total": int(c["workers"]), "workers_absent": absent, "workers_on": alloc,
			"auto_steam": auto_steam, "auto_move_in": auto_move_in,
			"humidity_range": [c["humidity_low"], c["humidity_high"]], "co2_limit": c["co2_limit"]},
		"lab": {"spawn_units": snappedf(spawn, 0.1)},
		"production": {"prepared_today": prepared_today, "waiting_for_steam": q_prepared, "autoclaves": steamer, "cooling_room": cooling, "cooled_waiting_for_seeding": q_cooled},
		"incubation": {"bags": incubation_bags(), "capacity": int(c["incubation_capacity"]), "batches": incubation.size(), "ready_for_move_in": ready},
		"fruiting": rooms,
		"last_7_days": last7,
		"since_start": {"kg_harvested": snappedf(float(totals["kg"]), 0.1), "kg_spoiled": snappedf(float(totals["lost_kg"]), 0.1),
			"bags_seeded": totals["seeded"], "bags_removed_infected": totals["removed"], "cash_rm": snappedf(cash(), 1.0)},
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
		_tool("get_state", "Read the whole farm now: plan, queues, steamer, incubation, each fruiting container, forecast, bottleneck and faults.", {}, []),
		_tool("set_target", "Set how many bags the production line prepares per day.", {"bags": {"type": "integer"}}, ["bags"]),
		_tool("assign_workers", "Put workers on the three jobs. The total cannot exceed the workers on the farm.",
			{"prepare": {"type": "integer"}, "seeding": {"type": "integer"}, "harvest": {"type": "integer"}}, ["prepare", "seeding", "harvest"]),
		_tool("start_steam", "Start the steamer now with the prepared bags that are waiting.", {}, []),
		_tool("set_policy", "Turn the standing rules on or off: auto_steam starts the steamer when a full load is waiting or the day ends; auto_move_in moves matured batches into the container with most room.",
			{"auto_steam": {"type": "boolean"}, "auto_move_in": {"type": "boolean"}}, []),
		_tool("move_in", "Move a matured incubation batch into a fruiting container and open its caps.",
			{"batch_id": {"type": "integer"}, "container": {"type": "string"}}, ["batch_id", "container"]),
		_tool("set_climate", "Control a fruiting container. automation=true lets the container run its own humidifier and vents. Naming any actuator switches that container to manual.",
			{"container": {"type": "string", "enum": room_names}, "automation": {"type": "boolean"}, "humidifier": {"type": "boolean"}, "spray": {"type": "boolean"},
			"vent1": {"type": "boolean"}, "vent2": {"type": "boolean"}, "light": {"type": "boolean"}}, ["container"]),
		_tool("set_humidity_range", "Set the fruiting humidity range the automation aims for, in %RH.", {"low": {"type": "number"}, "high": {"type": "number"}}, ["low", "high"]),
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
			for k in rooms:
				for act_name in ["humidifier", "spray", "vent1", "vent2", "light"]:
					if a.has(act_name):
						k["act"][act_name] = bool(a[act_name])
						k["auto"] = false
				if a.has("automation"):
					k["auto"] = bool(a["automation"])
			for act_name in ["humidifier", "spray", "vent1", "vent2", "light"]:
				if a.has(act_name):
					said.append("%s %s" % [act_name, "on" if bool(a[act_name]) else "off"])
			if a.has("automation"):
				said.append("automation %s" % ("on" if bool(a["automation"]) else "off"))
			elif not said.is_empty():
				said.append("automation off (manual)")
			if said.is_empty():
				return err("Name automation or at least one actuator.")
			_log("Climate %s: %s." % [which, ", ".join(said)])
			return ok("%s: %s." % [which, ", ".join(said)])
		"set_humidity_range":
			var lo := float(a.get("low", 0.0))
			var hi := float(a.get("high", 0.0))
			if lo < 60.0 or hi > 99.0 or lo >= hi:
				return err("Give a range between 60 and 99 with low under high.")
			c["humidity_low"] = lo
			c["humidity_high"] = hi
			_log("Climate: humidity range set to %d to %d %%RH." % [int(lo), int(hi)])
			return ok("The humidity range is now %d to %d %%RH." % [int(lo), int(hi)])
	return err("There is no tool called %s." % tool_name)


func _room(room_name: String):
	for k in containers:
		if str(k["name"]).to_lower() == room_name.to_lower():
			return k
	return null


# ---------------------------------------------------------------- what-ifs

func fault(kind: String) -> String:
	var text := ""
	match kind:
		"steamer":
			steamer["down_hours"] = 48
			text = "What if: the autoclaves break down for 2 days."
		"outbreak":
			outbreak_days = 10
			text = "What if: a contamination outbreak hits the incubation room for 10 days."
		"humidifier":
			containers[0]["fault_hours"] = 72
			text = "What if: the humidifier in %s fails for 3 days." % containers[0]["name"]
		"absent":
			absent = mini(2, int(c["workers"]))
			absent_hours = 72
			text = "What if: %d workers are absent for 3 days." % absent
	if text != "":
		_log(text)
	return text
