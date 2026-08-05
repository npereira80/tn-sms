using Toybox.Application;
using Toybox.Lang;
using Toybox.WatchUi;

//! One conversation: messages oldest-first, then a "Responder" row.
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
    private var _messages as Lang.Array = [];
    private var _menu as ThreadMenu or Null = null;
    private var _loading as Lang.Boolean = false;

    function initialize(chat as Lang.Dictionary) {
        _chat = chat;
        var cached = Store.thread(conversationId());
        if (cached != null) {
            _messages = cached;
        }
    }

    function conversationId() as Lang.String {
        var id = _chat.get("i");
        return id == null ? "" : id.toString();
    }

    function address() as Lang.String {
        var a = _chat.get("a");
        if (a == null) {
            return conversationId();
        }
        return a.toString();
    }

    function title() as Lang.String {
        return Format.chatTitle(_chat);
    }

    //! Can we answer this at all? Alphanumeric senders (OTP codes, banks) are
    //! one-way, exactly as on the phone and Wear OS apps.
    function canReply() as Lang.Boolean {
        return Format.isReplyable(address());
    }

    function buildMenu(status as Lang.String or Null) as ThreadMenu {
        var menu = new ThreadMenu(title());

        if (status != null) {
            menu.addItem(new WatchUi.MenuItem(status, null, "status", {}));
        }
        for (var i = 0; i < _messages.size(); i++) {
            var m = _messages[i];
            var body = Format.messageBody(m);
            var meta = Format.messageMeta(m);
            menu.addItem(new WatchUi.MenuItem(body, meta, "m" + i.toString(), {}));
        }
        if (status == null && _messages.size() == 0) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.NoMessages), null, "status", {}));
        }

        if (canReply()) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.Reply), null, "reply", {}));
        } else {
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
        if (_loading || !Config.isConfigured()) {
            return;
        }
        _loading = true;
        Api.messages(conversationId(), 20, method(:onMessages));
    }

    function onMessages(code as Lang.Number, data) as Void {
        _loading = false;
        if (code == 200 && data != null && data instanceof Lang.Dictionary) {
            var list = data.get("m");
            if (list instanceof Lang.Array) {
                _messages = list;
                Store.setThread(conversationId(), list);
                reload(null);
                return;
            }
        }
        if (_messages.size() == 0) {
            reload(Format.errorText(code));
        }
    }

    //! Sends a preset reply. The server hands it to the phone holding the SIM.
    function sendPreset(text as Lang.String) as Void {
        reload(WatchUi.loadResource(Rez.Strings.Sending));
        Api.send(address(), text, method(:onSent));
    }

    function onSent(code as Lang.Number, data) as Void {
        if (code == 200) {
            // Pull the thread again so the sent message shows up as the server
            // has it (the phone ingests it right after transmitting).
            refresh();
        } else {
            reload(WatchUi.loadResource(Rez.Strings.SendFailed));
        }
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
        if (key.equals("reply")) {
            var menu = ReplyMenu.build(_thread);
            WatchUi.pushView(menu, new ReplyDelegate(_thread), WatchUi.SLIDE_LEFT);
        } else if (key.equals("status")) {
            _thread.refresh();
        }
        // Tapping a message does nothing: there's no room to expand it usefully,
        // and Connect IQ has no text selection.
    }
}
