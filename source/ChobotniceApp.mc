import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

// Set when the watch stops the per-second partial updates for going over
// its power budget. The face then animates only once a minute.
var budgetExceeded as Boolean = false;

class ChobotniceApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new ChobotniceView(), new ChobotniceDelegate()];
    }
}

class ChobotniceDelegate extends WatchUi.WatchFaceDelegate {
    function initialize() {
        WatchFaceDelegate.initialize();
    }

    function onPowerBudgetExceeded(info as WatchUi.WatchFacePowerInfo) as Void {
        var clock = System.getClockTime();
        System.println(clock.hour.format("%02d") + ":" + clock.min.format("%02d") + " power budget exceeded: avg "
            + info.executionTimeAverage + " ms, limit " + info.executionTimeLimit + " ms");
        budgetExceeded = true;
    }
}
