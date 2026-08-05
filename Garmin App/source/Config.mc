using Toybox.Application;
using Toybox.Application.Properties;
using Toybox.Lang;
using Toybox.WatchUi;

//! Settings the user edits in Garmin Connect Mobile, plus the bearer token the
//! app stores after registering. Connect IQ has no on-watch text entry, so this
//! is the only way to get a URL, a secret, or Portuguese reply presets onto the
//! watch.
module Config {

    function getString(key as Lang.String) as Lang.String {
        var value = null;
        try {
            value = Properties.getValue(key);
        } catch (e) {
            value = null;
        }
        if (value == null) {
            return "";
        }
        return value.toString();
    }

    function setString(key as Lang.String, value as Lang.String) as Void {
        try {
            Properties.setValue(key, value);
        } catch (e) {
            // Read-only or missing property: nothing useful to do on-watch.
        }
    }

    //! Base URL of the SMS sync server, without a trailing slash.
    function serverUrl() as Lang.String {
        var url = getString("syncUrl");
        while (url.length() > 0 && url.substring(url.length() - 1, url.length()).equals("/")) {
            url = url.substring(0, url.length() - 1);
        }
        return url;
    }

    function secret() as Lang.String {
        return getString("syncSecret");
    }

    function token() as Lang.String {
        return getString("syncToken");
    }

    function setToken(value as Lang.String) as Void {
        setString("syncToken", value);
    }

    //! True once there's enough to talk to the server.
    function isConfigured() as Lang.Boolean {
        var url = serverUrl();
        // Connect IQ only allows HTTPS from the watch.
        if (!(url.length() > 8) || !url.substring(0, 8).equals("https://")) {
            return false;
        }
        return secret().length() > 0 || token().length() > 0;
    }

    //! Preset replies, in order, skipping any the user left blank.
    function replies() as Lang.Array<Lang.String> {
        var keys = ["reply1", "reply2", "reply3", "reply4", "reply5", "reply6"];
        var out = [] as Lang.Array<Lang.String>;
        for (var i = 0; i < keys.size(); i++) {
            var text = getString(keys[i]);
            if (text.length() > 0) {
                out.add(text);
            }
        }
        return out;
    }
}
