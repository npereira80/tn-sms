using Toybox.Lang;
using Toybox.WatchUi;

//! One conversation: messages oldest-first, then the reply options.
class ThreadMenu extends WatchUi.Menu2 {
    private var _visible as Lang.Boolean = false;

    function initialize(title as Lang.String) {
        Menu2.initialize({ :title => title });
    }

    function onShow() as Void {
        Menu2.onShow();
        _visible = true;
    }

    function onHide() as Void {
        Menu2.onHide();
        _visible = false;
    }

    function isVisible() as Lang.Boolean {
        return _visible;
    }
}

class ThreadController {
    private var _chat as Lang.Dictionary;
    private var _inbox as ChatListController;
    private var _messages as Lang.Array = [];
    private var _menu as ThreadMenu or Null = null;

    function initialize(chat as Lang.Dictionary, inbox as ChatListController) {
        _chat = chat;
        _inbox = inbox;
        var cached = Store.thread(key());
        if (cached != null) {
            _messages = cached;
        }
    }

    function key() as Lang.String {
        return Format.chatKey(_chat);
    }

    function title() as Lang.String {
        return Format.chatTitle(_chat);
    }

    function canSms() as Lang.Boolean {
        return Format.hasSms(_chat) && Format.isReplyable(_chat);
    }

    function canIMessage() as Lang.Boolean {
        return Format.hasIMessage(_chat) && Format.isReplyable(_chat);
    }

    function buildMenu(status as Lang.String or Null) as ThreadMenu {
        var menu = new ThreadMenu(title());
        if (status != null) {
            menu.addItem(new WatchUi.MenuItem(status, null, "status", {}));
        }
        for (var i = 0; i < _messages.size(); i++) {
            var m = _messages[i];
            menu.addItem(new WatchUi.MenuItem(
                Format.messageBody(m), Format.messageMeta(m), "m" + i.toString(), {}));
        }
        if (status == null && _messages.size() == 0) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.NoMessages), null, "status", {}));
        }

        // One entry per service the thread supports, mirroring the Wear OS app.
        if (canIMessage()) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.ReplyIMessage), null, "r_imsg", {}));
        }
        if (canSms()) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.ReplySms), null, "r_sms", {}));
        }
        if (!canSms() && !canIMessage()) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.CannotReply), null, "status", {}));
        }
        _menu = menu;
        return menu;
    }

    private function reload(status as Lang.String or Null) as Void {
        var current = _menu;
        if (current == null || !current.isVisible()) {
            return;
        }
        WatchUi.switchToView(buildMenu(status), new ThreadDelegate(self), WatchUi.SLIDE_IMMEDIATE);
    }

    function refresh() as Void {
        PhoneApi.onMessages = method(:onMessages);
        PhoneApi.onNew = method(:refresh);
        PhoneApi.requestMessages(key());
    }

    function onMessages(list as Lang.Array) as Void {
        _messages = list;
        Store.setThread(key(), list);
        reload(list.size() == 0 ? WatchUi.loadResource(Rez.Strings.NoMessages) : null);
    }

    //! Hands the phone a preset reply; it sends over the SIM or BlueBubbles.
    function sendPreset(service as Lang.String, body as Lang.String) as Void {
        reload(WatchUi.loadResource(Rez.Strings.Sending));
        PhoneApi.sendReply(key(), service, body);
        // The phone rebuilds its snapshot after sending, so ask again shortly.
        refresh();
    }

    //! Give the inbox its callbacks back when this thread closes.
    function release() as Void {
        _inbox.claim();
    }
}

class ThreadDelegate extends WatchUi.Menu2InputDelegate {
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
        var key = id.toString();
        if (key.equals("r_sms")) {
            WatchUi.pushView(ReplyMenu.build(), new ReplyDelegate(_thread, "sms"), WatchUi.SLIDE_LEFT);
        } else if (key.equals("r_imsg")) {
            WatchUi.pushView(ReplyMenu.build(), new ReplyDelegate(_thread, "imsg"), WatchUi.SLIDE_LEFT);
        } else if (key.equals("status")) {
            _thread.refresh();
        }
    }

    function onBack() as Void {
        _thread.release();
        Menu2InputDelegate.onBack();
    }
}
