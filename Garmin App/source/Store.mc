using Toybox.Application;
using Toybox.Application.Storage;
using Toybox.Lang;

//! Tiny persisted cache: the last chat list and the last thread viewed.
//!
//! Connect IQ storage is small and there's no database, so this is deliberately
//! just the most recent snapshot — enough for the list to appear instantly on
//! open and to still read something when the phone is out of Bluetooth range.
module Store {

    const KEY_CHATS = "chats";
    const KEY_THREAD_ID = "threadId";
    const KEY_THREAD = "thread";

    function get(key as Lang.String) {
        try {
            return Storage.getValue(key);
        } catch (e) {
            return null;
        }
    }

    function put(key as Lang.String, value) as Void {
        try {
            Storage.setValue(key, value);
        } catch (e) {
            // Storage full or unavailable: the app still works, just without cache.
        }
    }

    function chats() as Lang.Array or Null {
        var value = get(KEY_CHATS);
        if (value instanceof Lang.Array) {
            return value;
        }
        return null;
    }

    function setChats(list as Lang.Array) as Void {
        put(KEY_CHATS, list);
    }

    //! Cached messages, but only if they belong to the chat being asked about.
    function thread(conversationId as Lang.String) as Lang.Array or Null {
        var id = get(KEY_THREAD_ID);
        if (id == null || !id.toString().equals(conversationId)) {
            return null;
        }
        var value = get(KEY_THREAD);
        if (value instanceof Lang.Array) {
            return value;
        }
        return null;
    }

    function setThread(conversationId as Lang.String, messages as Lang.Array) as Void {
        put(KEY_THREAD_ID, conversationId);
        put(KEY_THREAD, messages);
    }

    function clear() as Void {
        put(KEY_CHATS, null);
        put(KEY_THREAD_ID, null);
        put(KEY_THREAD, null);
    }
}
