# Chobotnice

A watch face for the Garmin Instinct 3 Solar, inspired by the 1981 LCD game *Octopus*. A diver walks down to a treasure chest while an octopus reaches for him. Your step goal decides how far he gets.

Black and white, all art drawn from scratch in Monkey C. No bitmap files for the scene.

![Chobotnice on the Instinct 3](docs/chobotnice.png)

## How it plays

- The diver starts on the boat, climbs down the rope and crosses the seabed to the chest.
- **Steps are the dive.** He reaches the treasure when you hit your daily step goal.
- After the goal he keeps fetching gold: cheers at the chest, carries it up to the boat, waves, and goes back down.
- The octopus sits in the round sub-screen window. Its tentacles take turns reaching down over the seabed, one cell at a time, like the segments of the original game.
- **The diver never gets caught.** He waits, turns back or slips past when a tentacle is about to reach his spot.
- Now and then the octopus looks at you instead of the diver.

## What it shows

| Item | Where |
|---|---|
| Time, seven-segment digits | top left |
| Heart rate | under the time |
| Body Battery as spare divers on the boat | boat, top left |
| Day and date (`MO 4.11.`) | bottom left |
| Steps as the score, seven-segment | bottom right |
| Low battery icon (under 20 %) | bottom right |

## Supported watches

- Garmin Instinct 3 Solar, 45 mm and 50 mm (Connect IQ device `instinct3solar45mm`)

Other watches are not built or tested. The layout is made for the Instinct's cut-corner screen and round sub-screen window.

## Install

The face is not on the Connect IQ Store yet. To sideload it:

1. Build `bin/Chobotnice.prg` (see below).
2. Connect the watch with USB.
3. Copy `Chobotnice.prg` to `Garmin/Apps` on the watch.
4. Unplug the watch. It installs the file.
5. Pick Chobotnice from the watch face list.

## Build

You need the Connect IQ SDK and a developer key.

```
monkeyc -f monkey.jungle -d instinct3solar45mm -o bin/Chobotnice.prg -y developer_key.der -r
```

- `-r` makes a release build. Use it for anything you run on the watch. The debug build is six times larger.
- For the Connect IQ Store, export the package with `monkeyc -e -r -f monkey.jungle -o bin/Chobotnice.iq -y developer_key.der`.

## How it works

The Instinct has a 1-bit screen. In low power mode the watch lets a face redraw only small areas and takes away the animation if it uses too much power. The face is built around that.

- **Pre-drawn sprites.** The diver poses and the unlit tentacle dots are drawn once into small one-color bitmaps with transparency, then copied. A pose is one draw call instead of about fifteen.
- **Partial redraws.** Only the small box that changed is cleared and repainted, together with the few things that overlap it. The overlaps are worked out once at start.
- **Split ticks.** The world moves every 4 seconds. The redraw is split into two steps, 2 seconds apart: first the tentacles, then the diver. One repaint costs about 10 ms on the watch, so the split keeps the average redraw at about 16 ms (tentacles about 12 ms, diver about 20 ms).
- **The diver decides on what the screen shows.** He looks at the tentacles already drawn and one tick ahead, so he never dodges something you cannot see.
- **No float math in the redraw.** All geometry is computed once in `onLayout`.
- **Power budget.** If the watch still reports that the face went over its budget, the face animates only once a minute.

### Timing log

The face prints a line per minute. On the watch it goes to `Garmin/Apps/LOGS/CHOBOTNICE.TXT` if that file exists (create an empty one):

```
07:05 partials=31 avg=16ms max=34ms arms=168ms diver=328ms tick=2s budget=ok
```

`partials` is the number of redraws in that minute. `arms` and `diver` are the total milliseconds spent on each. `budget=EXCEEDED` means the watch complained about the power budget.

## Files

- `source/ChobotniceView.mc`: the watch face (scene, diver simulation, redraws).
- `source/ChobotniceApp.mc`: app entry point and the power budget handler.
- `manifest.xml`, `monkey.jungle`: Connect IQ project files.
- `docs/chobotnice.png`: screenshot from the simulator.

## License

None yet. All rights reserved by the author.
