using Toybox.Application;
using Toybox.Lang;
using Toybox.WatchUi;

//! Bubbles for Garmin.
//!
//! Reads the merged SMS + iMessage inbox from the Bubbles Android app over
//! Bluetooth and answers with preset replies. Deliberately small: Connect IQ apps
//! get very little memory, no database, a couple of KB per message, and no text
//! input at all.
class TnApp extends Application.AppBase {
    private var _inbox as ChatListController or Null = null;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state as Lang.Dictionary or Null) as Void {
        PhoneApi.start();
    }

    function onStop(state as Lang.Dictionary or Null) as Void {
    }

    function getInitialView() as Lang.Array {
        var inbox = new ChatListController();
        _inbox = inbox;
        inbox.claim();
        var menu = inbox.buildMenu(WatchUi.loadResource(Rez.Strings.Loading));
        inbox.refresh();   // ask the phone; the menu swaps itself when data lands
        return [menu, new ChatListDelegate(inbox)] as Lang.Array;
    }

    //! Preset replies edited in Garmin Connect Mobile.
    function onSettingsChanged() as Void {
    }
}
