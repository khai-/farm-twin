# OINC Farm Twin

A manager's simulation of OINC's Sibu mushroom factory, built in Godot 4.7 on 5 Nov 2026.
Bags (bongkah) flow through the bag line, incubation and fruiting, under weather, using
electricity, water and raw materials. An AI steward (Muse Spark 1.3) runs the farm through
tools, and asks before it changes anything.

It is a rehearsal tool for management, not a validated twin. Most numbers are placeholders;
the game shows the source of every one under **Numbers**.

## Run

```sh
godot --path .                       # play
godot --headless --path . -- --selftest          # 120 simulated days, 14 checks
godot --headless --path . -- --ask "raise the target to 450"   # one order to the steward
godot --path . -- --shot out.png --hour 21 --sky rain --inspect C3   # save a picture
```

The steward needs a Meta Model API key: set `META_API_KEY`, or on a Mac keep it in a Keychain
item named `meta-model-api`. Without a key everything else still works.

## Using it

- **AI console (right):** press Enter, type an order in your own words. `/help` lists commands.
  The steward can change the plan, climate targets and material orders, move the camera, open
  details and start a what-if. With "Ask me before changing the farm" on, it proposes and waits.
- **Click** a farm container for its bongkah batches and operations log, or a worker for their
  status. Wheel zooms, right-drag moves the view, `0` returns to the overview.
- **Plan (bottom):** bags a day, workers per job, standing rules, start steam, order sawdust.
- **What if (bottom):** heat wave, storm, power cut, water cut, autoclaves down, contamination
  outbreak, humidifier failure, workers absent.
- Space pauses; `1` `2` `3` set the speed.

## What is real and what is assumed

| Part | Source |
|---|---|
| Yard layout, stations, container count and sizes | OINC Phase 1 layout drawing, 26 Oct 2026 |
| Autoclave load (864 bags) and incubation capacity (19,440) | The same drawing, as read: 108 bongkah per stack. To be confirmed |
| 3,000 bags and about 300 kg a month per container, RM18 per kg | OINC operating plan |
| Step names (Prepare, Steam, Seeding, Move In, Open Cap, Harvest, Removal) | OINC server's own log types |
| Daily climate of a fruiting room | Fitted from container2's sensor log (11,842 readings); see below |
| What each actuator does to a room | Assumed. The control log does not record what ran when |
| Weather | Assumed generator for a hot, wet town; not Sibu's records |
| Workers, rates, yields per flush, removal rate, power, water, prices, recipe | Assumed |

The climate fit, checked on days it had not seen: temperature within 0.8 C and humidity within
3.3 %RH one hour ahead; at six hours it is no better than the usual level for that hour, and CO2
is not predictable from the log. `fit.py` reproduces it from the sensor export; raw readings stay
on the machine and only fitted numbers are written to `data/params.json`.

The pictures in a container's log are drawn views of the simulated racks, not photographs.
Workers are "Worker 1" to "Worker 5"; the simulation tracks jobs, not named people.

## Files

- `game/farm.gd` the simulation and its tools; `game/steward.gd` the AI steward;
  `game/main.gd` the yard, weather, camera and scene tools; `game/hud.gd` the controls.
- `data/farm.json` every setting with its source; `data/params.json` the fitted climate;
  `data/sample_day.json` one real logged day (not yet used in the game).
- `fit.py` fits the climate from a sensor export.

## Not done

- Real production figures (bags a day, headcount, removal rates, harvest weights) are not in it.
- No step test of the actuators, so their effects are guesses.
- No real photos; no link to the live MQTT feed or the OINC server.
- Not submitted to the Meta hackathon. The layout and fitted numbers are OINC's, so decide
  what may be public before this repository is published anywhere.
