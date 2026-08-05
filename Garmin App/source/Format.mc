using Toybox.Lang;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.WatchUi;

//! Display helpers. The phone sends short keys to keep each Bluetooth message
//! small (see garmin_snapshot.dart):
//!   chat:    k=key n=name a=address s=snippet t=ts(ms) u=unread sms=1 im=1
//!   message: d=1 if from me  b=body  t=ts(ms)  p=1 if it was a photo
module Format {

    function text(value) as Lang.String {
        if (value == null) {
            return "";
        }
        return value.toString();
    }

    function flag(value) as Lang.Boolean {
        return value != null && value.toString().equals("1");
    }

    //! Contact name resolved by the phone (the watch can't read contacts).
    function chatTitle(chat as Lang.Dictionary) as Lang.String {
        var name = chat.get("n");
        if (name != null && name.toString().length() > 0) {
            return name.toString();
        }
        var address = chat.get("a");
        if (address != null) {
            return address.toString();
        }
        return text(chat.get("k"));
    }

    function chatKey(chat as Lang.Dictionary) as Lang.String {
        return text(chat.get("k"));
    }

    function isUnread(chat as Lang.Dictionary) as Lang.Boolean {
        return flag(chat.get("u"));
    }

    function hasSms(chat as Lang.Dictionary) as Lang.Boolean {
        return flag(chat.get("sms"));
    }

    function hasIMessage(chat as Lang.Dictionary) as Lang.Boolean {
        return flag(chat.get("im"));
    }

    //! One-way senders (OTP codes, banks) can't be answered on any service.
    function isReplyable(chat as Lang.Dictionary) as Lang.Boolean {
        if (!hasSms(chat) && !hasIMessage(chat)) {
            return false;
        }
        var address = text(chat.get("a"));
        if (address.length() == 0) {
            return false;
        }
        if (address.find("@") != null) {
            return true;   // email handle: iMessage-addressable
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
        if (flag(message.get("p"))) {
            return body.length() == 0 ? "[foto]" : "[foto] " + body;
        }
        return body;
    }

    //! Sub-label: "→" for our own messages, plus a short timestamp.
    function messageMeta(message as Lang.Dictionary) as Lang.String {
        var stamp = shortTime(message.get("t"));
        if (flag(message.get("d"))) {
            return stamp.length() > 0 ? "→ " + stamp : "→";
        }
        return stamp;
    }

    //! HH:MM today, otherwise DD/MM HH:MM.
    function shortTime(tsMillis) as Lang.String {
        if (tsMillis == null) {
            return "";
        }
        var seconds = tsMillis.toLong() / 1000;
        if (seconds <= 0) {
            return "";
        }
        var info = Gregorian.info(new Time.Moment(seconds), Time.FORMAT_SHORT);
        var today = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var hhmm = info.hour.format("%02d") + ":" + info.min.format("%02d");
        if (info.year == today.year && info.month == today.month && info.day == today.day) {
            return hhmm;
        }
        return info.day.format("%02d") + "/" + info.month.format("%02d") + " " + hhmm;
    }
}
