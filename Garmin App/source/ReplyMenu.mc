using Toybox.Lang;
using Toybox.WatchUi;

//! Preset replies.
//!
//! Connect IQ gives third-party apps no keyboard and no dictation, so this is the
//! only way to answer from a Garmin watch. The texts come from the app's settings
//! in Garmin Connect Mobile, which is also how they can be written in Portuguese.
module ReplyMenu {

    function build(thread as ThreadController) as WatchUi.Menu2 {
        var menu = new WatchUi.Menu2({ :title => WatchUi.loadResource(Rez.Strings.Reply) });
        var replies = Config.replies();
        for (var i = 0; i < replies.size(); i++) {
            menu.addItem(new WatchUi.MenuItem(replies[i], null, i.toString(), {}));
        }
        return menu;
    }
}

class ReplyDelegate extends WatchUi.Menu2InputDelegate {
    private var _thread as ThreadController;

    function initialize(thread as ThreadController) {
        Menu2InputDelegate.initialize();
        _thread = thread;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == null) {
            return;
        }
        var replies = Config.replies();
        var index = id.toString().toNumber();
        if (index == null || index < 0 || index >= replies.size()) {
            return;
        }
        // Back to the thread first, so the send status is visible there.
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
        _thread.sendPreset(replies[index]);
    }
}
