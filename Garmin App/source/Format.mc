using Toybox.Lang;
using Toybox.System;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.WatchUi;

//! Display helpers. The server sends short keys to keep responses small:
//!   chat:    i=id  a=address  s=snippet  t=ts(ms)  u=unread
//!   message: i=id  d=1 if from me  b=body  t=ts(ms)  p=1 if it had a photo
module Format {

    function text(value) as Lang.String {
        if (value == null) {
            return "";
        }
        return value.toString();
    }

    function chatTitle(chat as Lang.Dictionary) as Lang.String {
        // No contact lookup: Connect IQ can't read the phone's contacts, so the
        // address is the best we have (the sync server stores numbers, not names).
        var address = chat.get("a");
        if (address == null) {
            address = chat.get("i");
        }
        return text(address);
    }

    function isUnread(chat as Lang.Dictionary) as Lang.Boolean {
        var u = chat.get("u");
        return u != null && u.toString().equals("1");
    }

    //! One-way senders (OTP codes, banks) can't be answered on any service.
    function isReplyable(address as Lang.String) as Lang.Boolean {
        if (address.length() == 0) {
            return false;
        }
        var digits = 0;
        var chars = address.toCharArray();
        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i];
            if (c >= '0' && c <= '9') {
                digits++;
            } else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
                return false;   // alphanumeric sender id
            }
        }
        return digits > 0;
    }

    function messageBody(message as Lang.Dictionary) as Lang.String {
        var body = text(message.get("b"));
        var photo = message.get("p");
        if (photo != null && body.length() == 0) {
            return "[foto]";
        }
        if (photo != null) {
            return "[foto] " + body;
        }
        return body;
    }

    //! Sub-label: direction plus a short timestamp.
    function messageMeta(message as Lang.Dictionary) as Lang.String {
        var fromMe = false;
        var d = message.get("d");
        if (d != null && d.toString().equals("1")) {
            fromMe = true;
        }
        var stamp = shortTime(message.get("t"));
        if (fromMe) {
            return stamp.length() > 0 ? "→ " + stamp : "→";
        }
        return stamp;
    }

    //! HH:MM for today, otherwise DD/MM HH:MM.
    function shortTime(tsMillis) as Lang.String {
        if (tsMillis == null) {
            return "";
        }
        var seconds = tsMillis.toLong() / 1000;
        if (seconds <= 0) {
            return "";
        }
        var moment = new Time.Moment(seconds);
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        var today = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var hhmm = info.hour.format("%02d") + ":" + info.min.format("%02d");
        if (info.year == today.year && info.month == today.month && info.day == today.day) {
            return hhmm;
        }
        return info.day.format("%02d") + "/" + info.month.format("%02d") + " " + hhmm;
    }

    //! Turns a Communications error code into something readable.
    function errorText(code as Lang.Number) as Lang.String {
        if (code == -104) {
            // BLE_CONNECTION_UNAVAILABLE: nothing works without the phone.
            return WatchUi.loadResource(Rez.Strings.Offline);
        }
        return WatchUi.loadResource(Rez.Strings.ServerError);
    }
}
