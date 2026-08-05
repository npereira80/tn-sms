using Toybox.Application;
using Toybox.Lang;
using Toybox.WatchUi;

//! Inbox.
//!
//! Built on Menu2 so scrolling, touch and physical buttons all come from the
//! system; hand-drawing a list would be more code and worse on a round screen.
//! Menu2 can't be emptied reliably across API levels, so each data change builds
//! a fresh menu and swaps it in — but only while the inbox is actually on screen,
//! so a late response can't yank the user out of a thread.
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

//! Holds the inbox state and drives loading.
class ChatListController {
    private var _chats as Lang.Array = [];
    private var _loading as Lang.Boolean = false;
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

    //! Builds the menu for the current state. `status` shows a single
    //! informational row instead of the list (loading, error, not configured).
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

    //! Swap in a rebuilt menu, but only if the inbox is the visible view.
    private function reload(status as Lang.String or Null) as Void {
        var current = _menu;
        if (current == null || !current.isVisible()) {
            return;
        }
        var menu = buildMenu(status);
        WatchUi.switchToView(menu, new ChatListDelegate(self), WatchUi.SLIDE_IMMEDIATE);
    }

    function refresh() as Void {
        if (!Config.isConfigured()) {
            reload(WatchUi.loadResource(Rez.Strings.NoConfig));
            return;
        }
        if (_loading) {
            return;
        }
        _loading = true;
        if (_chats.size() == 0) {
            reload(WatchUi.loadResource(Rez.Strings.Loading));
        }
        Api.ensureToken(method(:onToken));
    }

    function onToken(ok as Lang.Boolean) as Void {
        if (!ok) {
            _loading = false;
            reload(WatchUi.loadResource(Rez.Strings.ServerError));
            return;
        }
        Api.chats(20, method(:onChats));
    }

    function onChats(code as Lang.Number, data) as Void {
        _loading = false;
        if (code == 200 && data != null && data instanceof Lang.Dictionary) {
            var list = data.get("c");
            if (list instanceof Lang.Array) {
                _chats = list;
                Store.setChats(list);
                reload(null);
                return;
            }
        }
        // Failed: keep showing the cached list, and only complain if it's empty.
        if (_chats.size() == 0) {
            reload(Format.errorText(code));
        }
    }
}

//! Input handling for the inbox.
class ChatListDelegate extends WatchUi.Menu2InputDelegate {
    private var _controller as ChatListController;

    function initialize(controller as ChatListController) {
        Menu2InputDelegate.initialize();
        _controller = controller;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == null || id.toString().equals("status")) {
            _controller.refresh();   // tapping the status row retries
            return;
        }
        var chat = _controller.chatAt(id.toString().toNumber());
        if (chat == null) {
            return;
        }
        var thread = new ThreadController(chat);
        WatchUi.pushView(thread.buildMenu(WatchUi.loadResource(Rez.Strings.Loading)),
            new ThreadDelegate(thread), WatchUi.SLIDE_LEFT);
        thread.refresh();
    }
}
