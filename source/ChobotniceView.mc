import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.SensorHistory;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.WatchUi;

// Watch face after the 1981 LCD game "Octopus": the boat with its rope floats
// top left, the octopus fills the subscreen top right and spreads its broad
// segmented tentacles over the seabed, and the diver goes from the boat down
// to the treasure chest as the step goal fills up. Once the goal is reached
// he keeps fetching gold: cheers at the chest, carries it up to the boat,
// waves, goes back down. Reversed LCD colors.
// Coordinates are designed for a 176x176 screen and scaled.
class ChobotniceView extends WatchUi.WatchFace {
    private const DAYS = ["NE", "PO", "ÚT", "ST", "ČT", "PÁ", "SO"];
    // 7-segment masks, bit 0 = a (top) ... bit 6 = g (middle).
    private const SEGMENTS = [0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F];

    // Reversed LCD: light cells on a dark screen.
    private const INK = Graphics.COLOR_WHITE;
    private const PAPER = Graphics.COLOR_BLACK;

    // Diver stops: 0 = on the boat, 1 = down the rope, 2..4 = seabed,
    // 5 = treasure. [x, feet y] in design pixels.
    private const STOPS = [[44, 49], [24, 104], [52, 146], [77, 146], [102, 146], [124, 146]];
    private const SURFACE_Y = 57;
    private const SEABED_Y = 147;

    // Codes of the things a partial redraw may have to repaint, in drawing order.
    private const CODE_WAVES = 1;
    private const CODE_ROPE = 2;
    private const CODE_TREASURE = 3;
    private const CODE_BOAT = 4;
    private const CODE_ARM = 100;
    private const CODE_CELL = 1000;
    private const CODE_OCTOPUS = 5000;
    private const CODE_DIVER = 6000;

    // Diver poses.
    private const POSE_WALK = 0;
    private const POSE_CARRY = 1;
    private const POSE_CHEER = 2;
    private const POSE_WAVE = 3;
    // Ticks the diver spends cheering at the chest and waving on the boat.
    private const PAUSE = 3;

    private var _awake as Boolean = false;
    private var _scale as Float = 1.0;
    private var _sub as Array<Number> = [113, 0, 63, 63];

    // Tentacle k, cell j: polygon, unlit dot circle [x, y, r], bounding box
    // [x0, y0, x1, y1] and the codes of everything that box overlaps.
    private var _cells as Array<Array<Array<Graphics.Point2D>>> = [];
    private var _dots as Array<Array<Array<Number>>> = [];
    private var _cellBoxes as Array<Array<Array<Number>>> = [];
    private var _cellHits as Array<Array<Array<Number>>> = [];
    private var _armCells as Array<Array<Graphics.Point2D>> = [];
    // Per diver stop: boxes around the walking legs and around the whole
    // sprite, and what each overlaps.
    private var _legBoxes as Array<Array<Number>> = [];
    private var _legHits as Array<Array<Number>> = [];
    private var _diverBoxes as Array<Array<Number>> = [];
    private var _diverHits as Array<Array<Number>> = [];
    // Tighter box and hits for a walking or carrying diver (no raised arms).
    private var _walkBoxes as Array<Array<Number>> = [];
    private var _walkHits as Array<Array<Number>> = [];
    // Precomputed so the per-tick redraws do no float math: design pixels
    // 0..40 scaled for the full-size (0) and on-deck (1) diver, the octopus
    // shapes, the rope, and dot offsets of unlit cells per radius.
    private var _px as Array<Array<Number>> = [];
    private var _mantle as Array<Graphics.Point2D> = [];
    private var _oct as Array<Number> = [];
    private var _snout as Array<Graphics.Point2D> = [];
    private var _rope as Array<Graphics.Point2D> = [];
    // Pre-drawn bitmaps: unlit-cell dots per radius, diver poses per key.
    private var _ghosts as Dictionary<Number, Graphics.BufferedBitmapReference> = {};
    private var _sprites as Dictionary<Number, Graphics.BufferedBitmapReference> = {};

    // The diver, simulated one tick at a time: stop, heading (1 out to the
    // chest, -1 back to the boat), carrying gold, ticks left of a pause.
    private var _simTick as Number = -1;
    private var _pos as Number = 0;
    private var _dir as Number = 1;
    private var _bag as Boolean = false;
    private var _pause as Number = 0;
    // What is on the screen now, which partial redraws compare against.
    private var _shownPos as Number = 0;
    private var _shownPose as Number = POSE_WALK;
    private var _shownDir as Number = 1;
    private var _shownTick as Number = 0;
    private var _shownReach as Array<Number> = [0, 0, 0, 0];

    // State of the last full draw, reused by the partial redraws.
    private var _open as Boolean = false;
    private var _eyesToReader as Boolean = false;
    private var _spares as Number = 1;
    // Seconds between partial redraws in low power. Each redraws only the
    // tentacles or only the diver (measured: ~12 and ~20 ms).
    private var _every as Number = 2;
    // Timing of the partial redraws since the last full redraw.
    private var _partials as Number = 0;
    private var _partialMs as Number = 0;
    private var _partialMax as Number = 0;
    // Where the partial time goes (per minute): tentacle cells, diver.
    private var _msArms as Number = 0;
    private var _msDiver as Number = 0;

    function initialize() {
        WatchFace.initialize();
    }

    function onLayout(dc as Graphics.Dc) as Void {
        _scale = dc.getWidth() / 176.0;
        _sub = subscreen();

        _px = [];
        var sizes = [_scale, _scale * 0.75];
        for (var i = 0; i < 2; i++) {
            var row = [] as Array<Number>;
            for (var v = 0; v <= 40; v++) {
                row.add(p(v, sizes[i]));
            }
            _px.add(row);
        }

        layoutOctopus();

        // Rope from the boat's stern down to the seabed, gently kinked.
        _rope = [];
        for (var y = SURFACE_Y - 2; y <= SEABED_Y - 8; y += 8) {
            var x = 8 + (y / 8) % 2 * 2;
            _rope.add([s(x), s(y)]);
        }

        // Tentacle k leaves the porthole's lower left edge and reaches to just
        // above the diver's helmet at stop k + 1. Broad at the root, pointed at
        // the tip; the upper ones arch out to the left, the lower ones hang.
        var cx = (_sub[0] + _sub[2] / 2) / _scale;
        var cy = (_sub[1] + _sub[3] / 2) / _scale;
        var bases = [[cx - 30, cy + 29], [cx - 22, cy + 36], [cx - 10, cy + 40], [cx + 6, cy + 41]];
        var bends = [-5.0, -6.0, 4.0, 8.0];
        _cells = [];
        _dots = [];
        for (var k = 0; k < 4; k++) {
            var stop = STOPS[k + 1];
            var arm = tentacle(bases[k][0], bases[k][1], stop[0] + 2, stop[1] - 27, 11, bends[k], 9.0, 2.0);
            _cells.add(arm[0] as Array<Array<Graphics.Point2D>>);
            _dots.add(arm[1] as Array<Array<Number>>);
        }
        // One arm that never moves, curling down over the treasure.
        _armCells = tentacle(cx + 18, cy + 36, 164, 112, 11, -10.0, 7.0, 2.0)[0] as Array<Array<Graphics.Point2D>>;

        layoutRepaints();
    }

    // Integer geometry of the octopus in the porthole.
    private function layoutOctopus() as Void {
        var cx = _sub[0] + _sub[2] / 2;
        var cy = _sub[1] + _sub[3] / 2;
        var r = (_sub[2] < _sub[3] ? _sub[2] : _sub[3]) / 2.0;
        _mantle = ellipse(cx + r * 0.2, cy - r * 0.22, r * 0.62, r * 0.5, -0.5);
        _snout = [
            [cx - (r * 0.5).toNumber(), cy + (r * 0.16).toNumber()],
            [cx - (r * 0.82).toNumber(), cy + (r * 0.1).toNumber()],
            [cx - (r * 0.82).toNumber(), cy + (r * 0.32).toNumber()],
            [cx - (r * 0.5).toNumber(), cy + (r * 0.36).toNumber()]
        ];
        _oct = [
            // 0..3 face ellipse, 4..7 arm roots ellipse
            cx - (r * 0.14).toNumber(), cy + (r * 0.14).toNumber(), (r * 0.5).toNumber(), (r * 0.38).toNumber(),
            cx - (r * 0.08).toNumber(), cy + (r * 0.5).toNumber(), (r * 0.62).toNumber(), (r * 0.26).toNumber(),
            // 8..10 snout hole x, y, r
            cx - (r * 0.78).toNumber(), cy + (r * 0.21).toNumber(), (r * 0.05).toNumber() + 1,
            // 11..14 eye centers x0, y0, x1, y1; 15 eye radius; 16 pupil radius
            cx - (r * 0.36).toNumber(), cy + (r * 0.02).toNumber(), cx - (r * 0.02).toNumber(), cy - (r * 0.06).toNumber(),
            (r * 0.22).toNumber(), (r * 0.09).toNumber(),
            // 17, 18 pupil offset toward the diver
            -(r * 0.07).toNumber(), (r * 0.06).toNumber()
        ];
    }

    // Works out, for every box a partial redraw clears, which things overlap
    // it, so the redraw repaints only those.
    private function layoutRepaints() as Void {
        var codes = [] as Array<Number>;
        var boxes = [] as Array<Array<Number>>;
        var sy = s(SURFACE_Y);
        codes.add(CODE_WAVES);
        boxes.add([s(4), sy - s(3), _sub[0] - s(6), sy + 1]);
        codes.add(CODE_ROPE);
        boxes.add([s(4), s(SURFACE_Y - 4), s(14), s(SEABED_Y)]);
        codes.add(CODE_TREASURE);
        boxes.add([s(126), s(120), s(168), s(SEABED_Y)]);
        codes.add(CODE_BOAT);
        boxes.add([s(4), s(SURFACE_Y - 28), s(60), s(SURFACE_Y + 3)]);
        for (var j = 0; j < _armCells.size(); j++) {
            codes.add(CODE_ARM + j);
            boxes.add(boxOf(_armCells[j]));
        }
        _cellBoxes = [];
        for (var k = 0; k < _cells.size(); k++) {
            var list = [] as Array<Array<Number>>;
            for (var j = 0; j < _cells[k].size(); j++) {
                var b = boxOf(_cells[k][j]);
                list.add(b);
                codes.add(CODE_CELL + k * 100 + j);
                boxes.add(b);
            }
            _cellBoxes.add(list);
        }
        codes.add(CODE_OCTOPUS);
        boxes.add([_sub[0], _sub[1], _sub[0] + _sub[2], _sub[1] + _sub[3]]);
        _legBoxes = [];
        _diverBoxes = [];
        _walkBoxes = [];
        for (var i = 0; i < STOPS.size(); i++) {
            var x = s(STOPS[i][0]);
            var feet = s(STOPS[i][1]);
            var q = _px[i == 0 ? 1 : 0];
            // Room for raised arms, a bag held overhead and a hop. On deck
            // there is no hop or raised bag, so the box stays clear of the clock.
            var box = [x - q[14], feet - q[i == 0 ? 26 : 36], x + q[14], feet - 1];
            codes.add(CODE_DIVER + i);
            boxes.add(box);
            _diverBoxes.add(box);
            _walkBoxes.add([box[0], feet - q[26], box[2], box[3]]);
            _legBoxes.add([x - q[8], feet - q[5], x + q[8], feet - 1]);
        }

        _cellHits = [];
        for (var k = 0; k < _cellBoxes.size(); k++) {
            var list = [] as Array<Array<Number>>;
            for (var j = 0; j < _cellBoxes[k].size(); j++) {
                list.add(hits(_cellBoxes[k][j], codes, boxes));
            }
            _cellHits.add(list);
        }
        _legHits = [];
        _diverHits = [];
        _walkHits = [];
        for (var i = 0; i < STOPS.size(); i++) {
            _legHits.add(hits(_legBoxes[i], codes, boxes));
            _diverHits.add(hits(_diverBoxes[i], codes, boxes));
            _walkHits.add(hits(_walkBoxes[i], codes, boxes));
        }
    }

    function onExitSleep() as Void {
        _awake = true;
    }

    function onEnterSleep() as Void {
        _awake = false;
        WatchUi.requestUpdate();
    }

    // Full redraw: every second while the wrist is up, once a minute otherwise.
    function onUpdate(dc as Graphics.Dc) as Void {
        var clock = System.getClockTime();
        var frame = frameOf(clock);
        if (!_awake) {
            logPartials(clock);
        }
        // One tick per second with the wrist up; in low power the world moves
        // every 4 s (the partial redraws split that into two 2 s steps).
        var tick = _awake ? frame : frame / (2 * _every);

        dc.clearClip();
        dc.setColor(INK, PAPER);
        dc.clear();
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);

        var info = ActivityMonitor.getInfo();
        var steps = info.steps != null ? info.steps : 0;
        var goal = info.stepGoal != null && info.stepGoal > 0 ? info.stepGoal : 10000;
        _open = steps >= goal;
        advance(tick);
        showDiver(tick);
        for (var k = 0; k < 4; k++) {
            _shownReach[k] = reach(k, tick);
        }
        _eyesToReader = _awake && frame % 7 == 0;
        var bb = bodyBattery();
        _spares = bb == null ? 1 : (bb > 66 ? 2 : (bb > 33 ? 1 : 0));

        drawClock(dc, clock);
        drawSea(dc);
        drawBoat(dc);
        drawRope(dc);
        drawTreasure(dc);
        drawTentacles(dc);
        drawOctopus(dc);
        for (var i = 0; i < STOPS.size(); i++) {
            drawDiverAt(dc, i);
        }
        drawFooter(dc, steps);
    }

    // Low-power redraw between the full ones. One world tick lasts 4 s and is
    // shown in two steps, because one repaint costs about 10 ms: on the first
    // the tentacles take their cell (the tentacles take turns, as on the
    // original), on the second the diver moves, where he stands or, when he
    // moves on, his old and new place. The diver decides on the tentacles
    // already on the screen and one tick ahead, so he never dodges what the
    // screen doesn't show.
    function onPartialUpdate(dc as Graphics.Dc) as Void {
        var frame = frameOf(System.getClockTime());
        if (frame % _every != 0) {
            return;
        }
        var started = System.getTimer();
        var step = frame / _every;
        var tick = step / 2;
        var t1 = started;
        if (step % 2 == 0) {
            // Bring the tentacles on screen up to date, a cell at a time.
            for (var k = 0; k < 4; k++) {
                var actual = reach(k, tick);
                while (_shownReach[k] != actual) {
                    var shown = _shownReach[k];
                    _shownReach[k] = shown < actual ? shown + 1 : shown - 1;
                    var j = shown < actual ? shown : shown - 1;
                    repaint(dc, _cellBoxes[k][j], _cellHits[k][j]);
                }
            }
            t1 = System.getTimer();
            _msArms += t1 - started;
        } else {
            advance(tick);
            if (_pos != _shownPos) {
                var old = _shownPos;
                var oldWalk = _shownPose == POSE_WALK || _shownPose == POSE_CARRY;
                showDiver(tick);
                var newWalk = _shownPose == POSE_WALK || _shownPose == POSE_CARRY;
                repaint(dc, oldWalk ? _walkBoxes[old] : _diverBoxes[old], oldWalk ? _walkHits[old] : _diverHits[old]);
                repaint(dc, newWalk ? _walkBoxes[_pos] : _diverBoxes[_pos], newWalk ? _walkHits[_pos] : _diverHits[_pos]);
            } else {
                var pose = poseNow();
                var legsOnly = pose == _shownPose && _dir == _shownDir && (pose == POSE_WALK || pose == POSE_CARRY);
                showDiver(tick);
                if (legsOnly) {
                    repaint(dc, _legBoxes[_pos], _legHits[_pos]);
                } else {
                    repaint(dc, _diverBoxes[_pos], _diverHits[_pos]);
                }
            }
            _msDiver += System.getTimer() - started;
        }
        dc.clearClip();

        var took = System.getTimer() - started;
        _partials += 1;
        _partialMs += took;
        if (took > _partialMax) {
            _partialMax = took;
        }
    }

    // Writes how the partial redraws went since the last full one to the
    // sideload log (Garmin\Apps\LOGS\CHOBOTNICE.TXT, if that file exists).
    private function logPartials(clock as System.ClockTime) as Void {
        var avg = _partials > 0 ? _partialMs / _partials : 0;
        System.println(clock.hour.format("%02d") + ":" + clock.min.format("%02d")
            + " partials=" + _partials + " avg=" + avg + "ms max=" + _partialMax
            + "ms arms=" + _msArms + "ms diver=" + _msDiver + "ms"
            + " tick=" + _every + "s budget=" + ($.budgetExceeded ? "EXCEEDED" : "ok"));
        _partials = 0;
        _partialMs = 0;
        _partialMax = 0;
        _msArms = 0;
        _msDiver = 0;
    }

    // ---- animation ------------------------------------------------------

    // Seconds since midnight.
    private function frameOf(clock as System.ClockTime) as Number {
        return clock.hour * 3600 + clock.min * 60 + clock.sec;
    }

    // How many cells tentacle k has out at this tick. The tentacles take
    // turns: tentacle k moves one cell on every fourth tick, out to its full
    // length and back, each out of step with the others.
    private function reach(k as Number, tick as Number) as Number {
        var n = _cells[k].size();
        var v = ((tick + 4 - k) / 4 + k * 3) % (2 * n);
        return v <= n ? v : 2 * n - v;
    }

    // A seabed stop is dangerous while the tip of the tentacle above it is at
    // the diver's head or one cell short of it, now or next tick: the diver
    // doesn't step there, and leaves if he is there. Boat and chest are always
    // safe. (Simulated over a whole day of ticks: never caught, under a near
    // tip 0.15 % of the time when boxed in, a round trip every ~32 ticks.)
    private function danger(stop as Number, tick as Number) as Boolean {
        return near(stop, tick) || near(stop, tick + 1);
    }

    private function near(stop as Number, tick as Number) as Boolean {
        if (stop < 1 || stop > 4) {
            return false;
        }
        return reach(stop - 1, tick) >= _cells[stop - 1].size() - 1;
    }

    // Brings the diver simulation up to `tick`. After a jump (the face just
    // started, or the tick length changed with the power mode) he simply
    // carries on from where he is.
    private function advance(tick as Number) as Void {
        if (_simTick < 0 || tick < _simTick || tick - _simTick > 8) {
            _simTick = tick - 1;
        }
        while (_simTick < tick) {
            _simTick += 1;
            step(_simTick);
        }
    }

    // One tick of the diver: pause at the boat or the chest, otherwise step
    // on if the next stop is safe, run back if his own stop turns dangerous,
    // or wait.
    private function step(tick as Number) as Void {
        if (_pause > 0) {
            _pause -= 1;
            if (_pause == 0) {
                // Turn round: back to the boat with the gold, or out for more.
                _bag = _pos == 5;
                _dir = _pos == 5 ? -1 : 1;
            }
            return;
        }
        if (!danger(_pos + _dir, tick)) {
            stepOn();
        } else if (danger(_pos, tick)) {
            // Run back if that is safe. Boxed in between two tentacles, slip
            // past whichever is furthest from reaching down.
            if (!danger(_pos - _dir, tick)) {
                _pos -= _dir;
            } else if (!near(_pos + _dir, tick)) {
                stepOn();
            } else if (!near(_pos - _dir, tick)) {
                _pos -= _dir;
            } else if (!caught(_pos + _dir, tick)) {
                stepOn();
            } else if (!caught(_pos - _dir, tick)) {
                _pos -= _dir;
            }
        }
    }

    private function stepOn() as Void {
        _pos += _dir;
        if (_pos == 5 || _pos == 0) {
            _pause = PAUSE;
            _bag = _pos == 5;
        }
    }

    // The tentacle above this stop is all the way out: a diver there is caught.
    private function caught(stop as Number, tick as Number) as Boolean {
        if (stop < 1 || stop > 4) {
            return false;
        }
        return reach(stop - 1, tick) >= _cells[stop - 1].size();
    }

    private function poseNow() as Number {
        if (_pause > 0) {
            return _pos == 5 ? POSE_CHEER : POSE_WAVE;
        }
        return _bag ? POSE_CARRY : POSE_WALK;
    }

    private function showDiver(tick as Number) as Void {
        _shownTick = tick;
        _shownPos = _pos;
        _shownPose = poseNow();
        _shownDir = _dir;
    }

    // Clears one box and redraws the precomputed list of things overlapping it.
    private function repaint(dc as Graphics.Dc, box as Array<Number>, codes as Array<Number>) as Void {
        var w = box[2] - box[0] + 1;
        var h = box[3] - box[1] + 1;
        dc.setClip(box[0], box[1], w, h);
        dc.setColor(PAPER, PAPER);
        dc.fillRectangle(box[0], box[1], w, h);
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i < codes.size(); i++) {
            var code = codes[i];
            if (code == CODE_WAVES) {
                waves(dc, s(4), _sub[0] - s(6), s(SURFACE_Y));
            } else if (code == CODE_ROPE) {
                drawRope(dc);
            } else if (code == CODE_TREASURE) {
                drawTreasure(dc);
            } else if (code == CODE_BOAT) {
                drawBoat(dc);
            } else if (code < CODE_CELL) {
                dc.fillPolygon(_armCells[code - CODE_ARM]);
            } else if (code < CODE_OCTOPUS) {
                var k = (code - CODE_CELL) / 100;
                var j = (code - CODE_CELL) % 100;
                drawCell(dc, k, j, j < _shownReach[k]);
            } else if (code == CODE_OCTOPUS) {
                drawOctopus(dc);
            } else {
                drawDiverAt(dc, code - CODE_DIVER);
            }
        }
    }

    // Codes of the boxes overlapping `box`, in drawing order.
    private function hits(box as Array<Number>, codes as Array<Number>, boxes as Array<Array<Number>>) as Array<Number> {
        var out = [] as Array<Number>;
        for (var i = 0; i < codes.size(); i++) {
            var b = boxes[i];
            if (box[0] <= b[2] && b[0] <= box[2] && box[1] <= b[3] && b[1] <= box[3]) {
                out.add(codes[i]);
            }
        }
        return out;
    }

    private function boxOf(pts as Array<Graphics.Point2D>) as Array<Number> {
        var b = [pts[0][0], pts[0][1], pts[0][0], pts[0][1]] as Array<Number>;
        for (var i = 1; i < pts.size(); i++) {
            var x = pts[i][0] as Number;
            var y = pts[i][1] as Number;
            if (x < b[0]) { b[0] = x; }
            if (y < b[1]) { b[1] = y; }
            if (x > b[2]) { b[2] = x; }
            if (y > b[3]) { b[3] = y; }
        }
        return [b[0] - 1, b[1] - 1, b[2] + 1, b[3] + 1];
    }

    // ---- scene ----------------------------------------------------------

    // Time where the game had its score, heart rate below it.
    private function drawClock(dc as Graphics.Dc, clock as System.ClockTime) as Void {
        var hour = clock.hour;
        if (!System.getDeviceSettings().is24Hour) {
            hour = hour % 12;
            if (hour == 0) {
                hour = 12;
            }
        }
        // The subscreen's bezel ring covers a few pixels around its box.
        var right = _sub[0] - s(12);
        drawSegText(dc, hour.format("%02d") + ":" + clock.min.format("%02d"), right, s(5), s(13), s(24), s(3));

        var hr = heartRate();
        if (hr != null) {
            dc.drawText(right, s(41), Graphics.FONT_XTINY, hr.toString(),
                Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
            var tw = dc.getTextWidthInPixels(hr.toString(), Graphics.FONT_XTINY);
            heart(dc, right - tw - s(7), s(41));
        }
    }

    private function drawSea(dc as Graphics.Dc) as Void {
        waves(dc, s(4), _sub[0] - s(6), s(SURFACE_Y));

        dc.drawLine(s(12), s(SEABED_Y), s(166), s(SEABED_Y));
        dc.fillCircle(s(64), s(SEABED_Y + 2), s(3));
        dc.fillCircle(s(90), s(SEABED_Y + 2), s(2));
        dc.fillCircle(s(112), s(SEABED_Y + 2), s(3));
        weed(dc, s(38), s(SEABED_Y), 3);
    }

    // Boat on the surface. The spare divers on deck show Body Battery.
    private function drawBoat(dc as Graphics.Dc) as Void {
        var y = s(SURFACE_Y);
        dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(s(4), y - s(4), s(56), s(8));
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);
        dc.fillPolygon([[s(4), y - s(8)], [s(58), y - s(8)], [s(52), y + s(2)], [s(10), y + s(2)]]);
        dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(s(8), y - s(5), s(54), y - s(5));
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);

        var xs = [s(16), s(29)];
        for (var i = 0; i < 2; i++) {
            if (i < _spares) {
                sprite(dc, xs[i], y - s(8), 0, 1, POSE_WALK, 1);
            } else {
                ghost(dc, xs[i], y - s(22), s(4));
            }
        }
    }

    private function drawRope(dc as Graphics.Dc) as Void {
        for (var i = 0; i + 1 < _rope.size(); i++) {
            dc.drawLine(_rope[i][0], _rope[i][1], _rope[i + 1][0], _rope[i + 1][1]);
        }
    }

    // The octopus as on the original: a big round mantle behind, round staring
    // eyes with the pupils on the diver, and a short snout pointing left.
    private function drawOctopus(dc as Graphics.Dc) as Void {
        var o = _oct;
        dc.fillPolygon(_mantle);
        dc.fillEllipse(o[0], o[1], o[2], o[3]);
        dc.fillEllipse(o[4], o[5], o[6], o[7]);
        dc.fillPolygon(_snout);
        dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(o[8], o[9], o[10]);

        // Eyes: white with a dark ring, pupils down left at the diver. Now
        // and then, with the wrist up, they turn to the reader.
        var dx = _eyesToReader ? 0 : o[17];
        var dy = _eyesToReader ? 0 : o[18];
        for (var i = 0; i < 2; i++) {
            var x = o[11 + 2 * i];
            var y = o[12 + 2 * i];
            dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, y, o[15]);
            dc.setColor(INK, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x, y, o[15] - 2);
            dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x + dx, y + dy, o[16]);
        }
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);
    }

    private function drawTentacles(dc as Graphics.Dc) as Void {
        for (var j = 0; j < _armCells.size(); j++) {
            dc.fillPolygon(_armCells[j]);
        }
        for (var k = 0; k < _cells.size(); k++) {
            var len = _shownReach[k];
            for (var j = 0; j < _cells[k].size(); j++) {
                drawCell(dc, k, j, j < len);
            }
        }
    }

    private function drawCell(dc as Graphics.Dc, k as Number, j as Number, lit as Boolean) as Void {
        if (lit) {
            dc.fillPolygon(_cells[k][j]);
        } else {
            var d = _dots[k][j];
            ghost(dc, d[0], d[1], d[2]);
        }
    }

    // Wooden chest with an arched lid, iron bands and a glint of gold. Once
    // the step goal is reached the lid is up and the gold shows.
    private function drawTreasure(dc as Graphics.Dc) as Void {
        var open = _open;
        var x = s(136);
        var y = s(136);
        var w = s(24);
        dc.fillRectangle(x, y, w, s(11));
        if (open) {
            // Lid tipped back, gold heaped over the rim.
            dc.fillPolygon([[x + s(2), y - s(2)], [x + w + s(2), y - s(2)], [x + w + s(6), y - s(12)], [x + s(6), y - s(12)]]);
            dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x + s(1), y - s(1), w - s(2), s(2));
            dc.setColor(INK, Graphics.COLOR_TRANSPARENT);
            for (var i = 0; i < 4; i++) {
                dc.fillCircle(x + s(4) + i * s(5), y - s(1) - (i % 2) * s(2), s(2));
            }
        } else {
            dc.fillEllipse(x + w / 2, y, w / 2, s(6));
        }
        // Bands and keyhole in the background color.
        dc.setColor(PAPER, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x, y + s(1), x + w, y + s(1));
        dc.drawLine(x + s(5), y - (open ? 0 : s(5)), x + s(5), y + s(11));
        dc.drawLine(x + w - s(6), y - (open ? 0 : s(5)), x + w - s(6), y + s(11));
        dc.fillRectangle(x + w / 2 - s(1), y + s(4), s(3), s(4));
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);

        // Glints around it.
        var gx = x + w / 2;
        var gy = y - s(open ? 14 : 8);
        dc.drawLine(gx, gy - s(5), gx, gy - s(1));
        dc.drawLine(gx - s(12), gy + s(1), gx - s(8), gy + s(4));
        dc.drawLine(gx + s(12), gy + s(1), gx + s(8), gy + s(4));
        dc.drawLine(gx - s(7), gy - s(4), gx - s(5), gy);
        dc.drawLine(gx + s(7), gy - s(4), gx + s(5), gy);
    }

    // The diver at stop i if he is shown there, otherwise the faint helmet of
    // an unlit LCD cell.
    private function drawDiverAt(dc as Graphics.Dc, i as Number) as Void {
        var x = s(STOPS[i][0]);
        var feet = s(STOPS[i][1]);
        // On deck the diver is drawn at the spares' size to clear the clock.
        var si = i == 0 ? 1 : 0;
        if (_shownPos == i) {
            sprite(dc, x, feet, _shownTick, si, _shownPose, _shownDir);
        } else {
            var q = _px[si];
            ghost(dc, x, feet - q[19], q[6]);
        }
    }

    private function drawFooter(dc as Graphics.Dc, steps as Number) as Void {
        // Drawing a palette bitmap leaves the colors swapped, so set them again.
        dc.setColor(INK, Graphics.COLOR_TRANSPARENT);
        var now = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var date = DAYS[(now.day_of_week as Number) - 1] + " " + now.day + "." + now.month + ".";
        dc.drawText(s(28), s(160), Graphics.FONT_XTINY, date,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        drawSegText(dc, steps.toString(), s(148), s(154), s(7), s(12), s(2));

        if (System.getSystemStats().battery < 20) {
            var x = s(152);
            dc.drawRectangle(x, s(156), s(10), s(7));
            dc.fillRectangle(x + s(10), s(158), s(2), s(3));
            dc.fillRectangle(x + s(2), s(158), s(2), s(3));
        }
    }

    // ---- sprites --------------------------------------------------------

    // Diver as on the original: round helmet with a cross-barred window,
    // standing on (x, feet), facing `dir` (1 right, -1 left). si picks the
    // full (0) or on-deck (1) size.
    private function diver(dc as Graphics.Dc, x as Number, feet as Number, tick as Number,
            si as Number, pose as Number, dir as Number) as Void {
        var q = _px[si];
        var moving = pose == POSE_WALK || pose == POSE_CARRY;
        var stride = moving && tick % 2 == 1 ? q[2] : 0;
        // A hop of joy at the chest.
        var f = pose == POSE_CHEER && tick % 2 == 0 ? feet - q[3] : feet;
        var head = f - q[19];
        var hr = q[6];

        // Helmet ring in ink only, so the sprite needs no second color: the
        // 1-bit screen takes bitmaps of one color plus transparency.
        for (var i = 0; i < q[2]; i++) {
            dc.drawCircle(x, head, hr - i);
        }
        dc.drawLine(x - hr, head, x + hr, head);
        dc.drawLine(x, head - hr, x, head + hr);

        dc.fillRectangle(x - q[4], f - q[13], q[9], q[8]);
        dc.fillRectangle(x - q[4] - stride, f - q[5], q[3], q[5]);
        dc.fillRectangle(x + q[2] + stride, f - q[5], q[3], q[5]);

        var shoulder = f - q[11];
        if (pose == POSE_CHEER) {
            // Both arms up, the bag of gold held high.
            dc.drawLine(x - q[4], shoulder, x - q[6], head - q[6]);
            dc.drawLine(x + q[4], shoulder, x + q[6], head - q[6]);
            dc.fillCircle(x, head - q[10], q[4]);
        } else if (pose == POSE_WAVE) {
            // Waving both arms by turns, the bag set down on deck behind him.
            var up = tick % 2 == 0;
            dc.drawLine(x - q[4], shoulder, x - q[8], up ? head - q[4] : head + q[3]);
            dc.drawLine(x + q[4], shoulder, x + q[8], up ? head + q[3] : head - q[4]);
            dc.fillCircle(x - dir * q[11], f - q[3], q[3]);
        } else {
            // Arms swing with the stride; carrying, the front hand holds the bag.
            dc.drawLine(x + dir * q[4], shoulder, x + dir * q[9], f - q[8] - (pose == POSE_CARRY ? 0 : stride));
            dc.drawLine(x - dir * q[4], shoulder, x - dir * q[8], f - q[8] + stride);
            if (pose == POSE_CARRY) {
                dc.fillCircle(x + dir * q[10], f - q[7], q[3]);
            }
        }
    }

    // ---- drawing helpers ------------------------------------------------

    // Right-aligned 7-segment text of digits and colons.
    private function drawSegText(dc as Graphics.Dc, text as String, right as Number, y as Number,
            dw as Number, dh as Number, t as Number) as Void {
        var gap = t;
        var chars = text.toCharArray();
        var x = right;
        for (var i = chars.size() - 1; i >= 0; i--) {
            var c = chars[i];
            if (c == ':') {
                x -= t + gap;
                dc.fillRectangle(x, y + dh / 4, t, t);
                dc.fillRectangle(x, y + dh * 3 / 4 - t, t, t);
            } else {
                x -= dw;
                digit(dc, x, y, dw, dh, t, c.toNumber() - '0'.toNumber());
                x -= gap;
            }
        }
    }

    private function digit(dc as Graphics.Dc, x as Number, y as Number, dw as Number, dh as Number,
            t as Number, n as Number) as Void {
        var m = SEGMENTS[n];
        var top = y + (dh - t) / 2;
        var bottom = top + t;
        if ((m & 0x01) != 0) { dc.fillRectangle(x + t, y, dw - 2 * t, t); }
        if ((m & 0x02) != 0) { dc.fillRectangle(x + dw - t, y + t, t, top - y - t); }
        if ((m & 0x04) != 0) { dc.fillRectangle(x + dw - t, bottom, t, y + dh - t - bottom); }
        if ((m & 0x08) != 0) { dc.fillRectangle(x + t, y + dh - t, dw - 2 * t, t); }
        if ((m & 0x10) != 0) { dc.fillRectangle(x, bottom, t, y + dh - t - bottom); }
        if ((m & 0x20) != 0) { dc.fillRectangle(x, y + t, t, top - y - t); }
        if ((m & 0x40) != 0) { dc.fillRectangle(x + t, top, dw - 2 * t, t); }
    }

    // Unlit LCD cell: a sparse dot grid inside the circle, drawn once per
    // radius into a transparent bitmap that is then just copied.
    private function ghost(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        if (!(Graphics has :createBufferedBitmap)) {
            ghostDots(dc, cx, cy, r);
            return;
        }
        var ref = _ghosts[r];
        if (ref == null || ref.get() == null) {
            ref = Graphics.createBufferedBitmap({
                :width => 2 * r + 1, :height => 2 * r + 1,
                :palette => [INK, Graphics.COLOR_TRANSPARENT]
            });
            var bmp = ref.get();
            if (bmp == null) {
                ghostDots(dc, cx, cy, r);
                return;
            }
            var bdc = (bmp as Graphics.BufferedBitmap).getDc();
            bdc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_TRANSPARENT);
            bdc.clear();
            bdc.setColor(INK, Graphics.COLOR_TRANSPARENT);
            ghostDots(bdc, r, r, r);
            _ghosts[r] = ref;
        }
        dc.drawBitmap(cx - r, cy - r, ref);
    }

    private function ghostDots(dc as Graphics.Dc, cx as Number, cy as Number, r as Number) as Void {
        for (var dy = -r; dy <= r; dy += 3) {
            for (var dx = -r; dx <= r; dx += 3) {
                if (dx * dx + dy * dy <= r * r) {
                    dc.drawPoint(cx + dx, cy + dy);
                }
            }
        }
    }

    // The diver drawn once per size, pose, heading and step phase into a
    // transparent bitmap, then just copied: a single draw call per redraw
    // instead of fifteen.
    private function sprite(dc as Graphics.Dc, x as Number, feet as Number, tick as Number,
            si as Number, pose as Number, dir as Number) as Void {
        var phase = tick % 2;
        if (!(Graphics has :createBufferedBitmap)) {
            diver(dc, x, feet, phase, si, pose, dir);
            return;
        }
        var q = _px[si];
        var key = si * 100 + pose * 10 + (dir > 0 ? 2 : 0) + phase;
        var ref = _sprites[key];
        if (ref == null || ref.get() == null) {
            ref = Graphics.createBufferedBitmap({
                :width => 2 * q[14] + 1, :height => q[36] + 1,
                :palette => [INK, Graphics.COLOR_TRANSPARENT]
            });
            var bmp = ref.get();
            if (bmp == null) {
                diver(dc, x, feet, phase, si, pose, dir);
                return;
            }
            var bdc = (bmp as Graphics.BufferedBitmap).getDc();
            bdc.setColor(Graphics.COLOR_TRANSPARENT, Graphics.COLOR_TRANSPARENT);
            bdc.clear();
            bdc.setColor(INK, Graphics.COLOR_TRANSPARENT);
            diver(bdc, q[14], q[36], phase, si, pose, dir);
            _sprites[key] = ref;
        }
        dc.drawBitmap(x - q[14], feet - q[36], ref);
    }

    private function waves(dc as Graphics.Dc, x1 as Number, x2 as Number, y as Number) as Void {
        var step = s(6);
        var up = true;
        for (var x = x1; x + step <= x2; x += step) {
            dc.drawLine(x, up ? y : y - s(2), x + step, up ? y - s(2) : y);
            up = !up;
        }
    }

    private function weed(dc as Graphics.Dc, x as Number, y as Number, leaves as Number) as Void {
        var h = s(5);
        for (var i = 0; i < leaves; i++) {
            var dx = i % 2 == 0 ? s(2) : -s(2);
            dc.drawLine(x, y - i * h, x + dx, y - (i + 1) * h);
            dc.drawLine(x + dx, y - (i + 1) * h, x, y - (i + 1) * h - s(1));
        }
    }

    private function heart(dc as Graphics.Dc, x as Number, y as Number) as Void {
        dc.fillCircle(x - s(2), y - s(1), s(2));
        dc.fillCircle(x + s(2), y - s(1), s(2));
        dc.fillPolygon([[x - s(4), y], [x + s(4), y], [x, y + s(4)]]);
    }

    // Polygon of an ellipse with semi-axes a, b rotated by `angle` radians.
    private function ellipse(cx as Float, cy as Float, a as Float, b as Float, angle as Float) as Array<Graphics.Point2D> {
        var pts = [] as Array<Graphics.Point2D>;
        var ca = Math.cos(angle);
        var sa = Math.sin(angle);
        for (var i = 0; i < 20; i++) {
            var t = i * Math.PI / 10;
            var x = a * Math.cos(t);
            var y = b * Math.sin(t);
            pts.add([(cx + x * ca - y * sa).toNumber(), (cy + x * sa + y * ca).toNumber()]);
        }
        return pts;
    }

    // A tentacle as a broad ribbon from (x1, y1) to (x2, y2) along a curve
    // bent by `bend` pixels (positive sags down), cut into cells about
    // `spacing` long with a thin gap between them, w0 wide at the root and w1
    // at the tip. Design pixels in, screen pixels out.
    // Returns [cell polygons, [x, y, r] dot circles for the unlit cells].
    private function tentacle(x1 as Numeric, y1 as Numeric, x2 as Numeric, y2 as Numeric, spacing as Number,
            bend as Float, w0 as Float, w1 as Float) as Array {
        var cx = (x1 + x2) / 2.0;
        var cy = (y1 + y2) / 2.0 + bend;
        var dist = Math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
        var n = (dist / spacing).toNumber();
        var gap = 0.6 / dist;
        var cells = [] as Array<Array<Graphics.Point2D>>;
        var dots = [] as Array<Array<Number>>;
        for (var j = 0; j < n; j++) {
            var a = rib(x1, y1, cx, cy, x2, y2, j.toFloat() / n + gap, w0, w1);
            var b = rib(x1, y1, cx, cy, x2, y2, (j + 1.0) / n - gap, w0, w1);
            // The last cell ends in a point.
            if (j == n - 1) {
                cells.add([[s(a[0]), s(a[1])], [s((b[0] + b[2]) / 2), s((b[1] + b[3]) / 2)], [s(a[2]), s(a[3])]]);
            } else {
                cells.add([[s(a[0]), s(a[1])], [s(b[0]), s(b[1])], [s(b[2]), s(b[3])], [s(a[2]), s(a[3])]]);
            }
            var m = rib(x1, y1, cx, cy, x2, y2, (j + 0.5) / n, w0, w1);
            var half = Math.sqrt((m[0] - m[2]) * (m[0] - m[2]) + (m[1] - m[3]) * (m[1] - m[3])) / 2;
            dots.add([s((m[0] + m[2]) / 2), s((m[1] + m[3]) / 2), s(half)]);
        }
        return [cells, dots];
    }

    // The two edge points [lx, ly, rx, ry] of the ribbon across the curve at t.
    private function rib(x1 as Numeric, y1 as Numeric, cx as Float, cy as Float, x2 as Numeric, y2 as Numeric,
            t as Float, w0 as Float, w1 as Float) as Array<Float> {
        var u = 1 - t;
        var x = u * u * x1 + 2 * u * t * cx + t * t * x2;
        var y = u * u * y1 + 2 * u * t * cy + t * t * y2;
        var dx = 2 * u * (cx - x1) + 2 * t * (x2 - cx);
        var dy = 2 * u * (cy - y1) + 2 * t * (y2 - cy);
        var len = Math.sqrt(dx * dx + dy * dy);
        var w = (w0 + (w1 - w0) * t) / 2;
        var nx = -dy / len * w;
        var ny = dx / len * w;
        return [x + nx, y + ny, x - nx, y - ny];
    }

    // Design pixels (176-wide screen) to real pixels.
    private function s(v as Numeric) as Number {
        return p(v, _scale);
    }

    private function p(v as Numeric, scale as Float) as Number {
        var r = (v * scale + 0.5).toNumber();
        return r < 1 && v > 0 ? 1 : r;
    }

    private function subscreen() as Array<Number> {
        if (WatchUi has :getSubscreen) {
            var box = WatchUi.getSubscreen();
            if (box != null) {
                return [box.x, box.y, box.width, box.height];
            }
        }
        return [s(113), 0, s(63), s(63)];
    }

    // ---- data -----------------------------------------------------------

    private function bodyBattery() as Number? {
        if ((Toybox has :SensorHistory) && (SensorHistory has :getBodyBatteryHistory)) {
            var sample = SensorHistory.getBodyBatteryHistory({:period => 1}).next();
            if (sample != null && sample.data != null) {
                return sample.data.toNumber();
            }
        }
        return null;
    }

    private function heartRate() as Number? {
        var act = Activity.getActivityInfo();
        if (act != null && act.currentHeartRate != null) {
            return act.currentHeartRate;
        }
        var sample = ActivityMonitor.getHeartRateHistory(1, true).next();
        if (sample != null && sample.heartRate != ActivityMonitor.INVALID_HR_SAMPLE) {
            return sample.heartRate;
        }
        return null;
    }
}
