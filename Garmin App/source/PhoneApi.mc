using Toybox.Communications;
using Toybox.Lang;
using Toybox.WatchUi;

//! Talks to the Bubbles Android app over Bluetooth instead of to a server.
//!
//! Why: the phone app already holds BOTH SMS and iMessage, so this is the only
//! way the watch can see iMessage at all — and it sidesteps the HTTP limits that
//! make the sync server's own API unusable here (Connect IQ fails near 32KB of
//! JSON and needs double that in memory to parse it). It also means no internet,
//! no tunnel and no credentials on the watch.
//!
//! Protocol (see GarminBridge.kt on the phone):
//!   watch → phone   {q:"chats"} | {q:"msgs", c:key} | {q:"send", c:key, s:"sms"|"imsg", b:text}
//!   phone → watch   {t:"c", n:i, k:total, v:[chats]}
//!                   {t:"m", c:key, n:i, k:total, v:[messages]}
//!                   {t:"new"}  something arrived
//!                   {t:"sent"} reply accepted
//! Replies arrive in slices because one Bluetooth message only carries a couple
//! of KB; slices are reassembled here.
module PhoneApi {

    // Reassembly buffers for the reply currently streaming in.
    var chatSlices = {} as Lang.Dictionary;
    var chatSliceCount = 0;
    var messageSlices = {} as Lang.Dictionary;
    var messageSliceCount = 0;
    var messageChatKey = "";

    //! Someone has to own the callbacks; set by the controllers.
    var onChats as Lang.Method or Null = null;
    var onMessages as Lang.Method or Null = null;
    var onNew as Lang.Method or Null = null;

    function start() as Void {
        Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
    }

    function requestChats() as Void {
        chatSlices = {};
        chatSliceCount = 0;
        transmit({ "q" => "chats" });
    }

    function requestMessages(chatKey as Lang.String) as Void {
        messageSlices = {};
        messageSliceCount = 0;
        messageChatKey = chatKey;
        transmit({ "q" => "msgs", "c" => chatKey });
    }

    function sendReply(chatKey as Lang.String, service as Lang.String, body as Lang.String) as Void {
        transmit({ "q" => "send", "c" => chatKey, "s" => service, "b" => body });
    }

    function transmit(payload as Lang.Dictionary) as Void {
        try {
            Communications.transmit(payload, null, new TransmitListener());
        } catch (e) {
            // No phone / Garmin Connect not running: the UI keeps its cache.
        }
    }

    //! Incoming slice from the phone.
    function onPhoneMessage(message) as Void {
        var data = message.data;
        if (!(data instanceof Lang.Dictionary)) {
            return;
        }
        var type = data.get("t");
        if (type == null) {
            return;
        }
        var kind = type.toString();

        if (kind.equals("new")) {
            if (onNew != null) { onNew.invoke(); }
            return;
        }
        if (kind.equals("c")) {
            collect(data, true);
            return;
        }
        if (kind.equals("m")) {
            collect(data, false);
            return;
        }
    }

    //! Stores a slice and, once every slice has arrived, hands over the whole list.
    private function collect(data as Lang.Dictionary, isChats as Lang.Boolean) as Void {
        var index = data.get("n");
        var total = data.get("k");
        var items = data.get("v");
        if (index == null || total == null || !(items instanceof Lang.Array)) {
            return;
        }
        var i = index.toNumber();
        var k = total.toNumber();

        if (isChats) {
            chatSlices.put(i, items);
            chatSliceCount = k;
            if (chatSlices.size() >= k) {
                var all = flatten(chatSlices, k);
                chatSlices = {};
                if (onChats != null) { onChats.invoke(all); }
            }
        } else {
            var key = data.get("c");
            var keyText = key == null ? "" : key.toString();
            if (!keyText.equals(messageChatKey)) {
                return;   // a stale reply for a thread we've left
            }
            messageSlices.put(i, items);
            messageSliceCount = k;
            if (messageSlices.size() >= k) {
                var msgs = flatten(messageSlices, k);
                messageSlices = {};
                if (onMessages != null) { onMessages.invoke(msgs); }
            }
        }
    }

    private function flatten(slices as Lang.Dictionary, count as Lang.Number) as Lang.Array {
        var out = [] as Lang.Array;
        for (var i = 0; i < count; i++) {
            var slice = slices.get(i);
            if (slice instanceof Lang.Array) {
                for (var j = 0; j < slice.size(); j++) {
                    out.add(slice[j]);
                }
            }
        }
        return out;
    }
}

class TransmitListener extends Communications.ConnectionListener {
    function initialize() {
        ConnectionListener.initialize();
    }

    function onComplete() as Void {
    }

    function onError() as Void {
        // Phone unreachable; the views fall back to their cached copy.
    }
}
