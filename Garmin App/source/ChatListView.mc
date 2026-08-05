using Toybox.Lang;
using Toybox.WatchUi;

//! Inbox, fed by the phone app over Bluetooth.
//!
//! Built on Menu2 so scrolling, touch and buttons come from the system. Menu2
//! can't be emptied reliably across API levels, so each data change builds a
//! fresh menu and swaps it in — only while the inbox is on screen, so a late
//! reply can't yank you out of a thread.
class ChatListMenu extends WatchUi.Menu2 {
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

class ChatListController {
    private var _chats as Lang.Array = [];
    private var _menu as ChatListMenu or Null = null;

    function initialize() {
        var cached = Store.chats();
        if (cached != null) {
            _chats = cached;
        }
    }

    function chatAt(index as Lang.Number) {
        if (index < 0 || index >= _chats.size()) {
            return null;
        }
        return _chats[index];
    }

    //! Take over the phone callbacks (the thread view claims them while open).
    function claim() as Void {
        PhoneApi.onChats = method(:onChats);
        PhoneApi.onNew = method(:refresh);
    }

    function buildMenu(status as Lang.String or Null) as ChatListMenu {
        var menu = new ChatListMenu(WatchUi.loadResource(Rez.Strings.Messages));
        if (status != null) {
            menu.addItem(new WatchUi.MenuItem(status, null, "status", {}));
        }
        for (var i = 0; i < _chats.size(); i++) {
            var chat = _chats[i];
            var title = Format.chatTitle(chat);
            if (Format.isUnread(chat)) {
                title = "• " + title;
            }
            menu.addItem(new WatchUi.MenuItem(title, Format.text(chat.get("s")), i.toString(), {}));
        }
        if (status == null && _chats.size() == 0) {
            menu.addItem(new WatchUi.MenuItem(
                WatchUi.loadResource(Rez.Strings.NoChats), null, "status", {}));
        }
        _menu = menu;
        return menu;
    }

    private function reload(status as Lang.String or Null) as Void {
        var current = _menu;
        if (current == null || !current.isVisible()) {
            return;
        }
        WatchUi.switchToView(buildMenu(status), new ChatListDelegate(self), WatchUi.SLIDE_IMMEDIATE);
    }

    function refresh() as Void {
        claim();
        if (_chats.size() == 0) {
            reload(WatchUi.loadResource(Rez.Strings.Loading));
        }
        PhoneApi.requestChats();
    }

    function onChats(list as Lang.Array) as Void {
        _chats = list;
        Store.setChats(list);
        if (list.size() == 0) {
            reload(WatchUi.loadResource(Rez.Strings.NoChats));
        } else {
            reload(null);
        }
    }
}

class ChatListDelegate extends WatchUi.Menu2InputDelegate {
    private var _controller as ChatListController;

    function initialize(controller as ChatListController) {
        Menu2InputDelegate.initialize();
        _controller = controller;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == null || id.toString().equals("status")) {
            _controller.refresh();   // tap the status row to retry
            return;
        }
        var chat = _controller.chatAt(id.toString().toNumber());
        if (chat == null) {
            return;
        }
        var thread = new ThreadController(chat, _controller);
        WatchUi.pushView(
            thread.buildMenu(WatchUi.loadResource(Rez.Strings.Loading)),
            new ThreadDelegate(thread),
            WatchUi.SLIDE_LEFT);
        thread.refresh();
    }
}
