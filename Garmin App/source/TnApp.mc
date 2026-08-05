using Toybox.Application;
using Toybox.Lang;
using Toybox.WatchUi;

//! Bubbles for Garmin.
//!
//! Reads the merged SMS inbox from the sync server and answers with preset
//! replies. Deliberately small: Connect IQ apps get very little memory, no
//! database, ~32KB per web response and no text input at all.
class TnApp extends Application.AppBase {
    private var _inbox as ChatListController or Null = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Lang.Dictionary or Null) as Void {
    }

    function onStop(state as Lang.Dictionary or Null) as Void {
    }

    function getInitialView() as Lang.Array {
        var inbox = new ChatListController();
        _inbox = inbox;
        var status = Config.isConfigured()
            ? WatchUi.loadResource(Rez.Strings.Loading)
            : WatchUi.loadResource(Rez.Strings.NoConfig);
        var menu = inbox.buildMenu(status);
        // Kick off the load; the menu swaps itself out when data lands.
        inbox.refresh();
        return [menu, new ChatListDelegate(inbox)] as Lang.Array;
    }

    //! Re-read settings edited in Garmin Connect Mobile (server URL, presets).
    function onSettingsChanged() as Void {
        var inbox = _inbox;
        if (inbox != null) {
            inbox.refresh();
        }
    }
}
