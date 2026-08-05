using Toybox.Application.Properties;
using Toybox.Lang;

//! Only the preset replies live here now.
//!
//! Everything else comes from the phone app over Bluetooth, so the watch needs no
//! server URL, no secret and no token. Presets are edited in Garmin Connect
//! Mobile — the only way to get Portuguese text onto a watch with no keyboard.
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

    //! Preset replies in order, skipping blanks.
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
