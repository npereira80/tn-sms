using Toybox.Application;
using Toybox.Communications;
using Toybox.Lang;

//! Talks to the SMS sync server through the phone's Garmin Connect app.
//!
//! Constraints that shape this file:
//!   - HTTPS only; plain HTTP never leaves the watch.
//!   - Responses must stay small (~32KB fails on many devices, and parsing costs
//!     more than double in memory), hence the compact /watch/* endpoints.
//!   - Everything needs a live Bluetooth link; -104 means the phone is away.
module Api {

    //! Registers this watch and stores the bearer token. `done` is invoked with
    //! true once a token is available.
    function ensureToken(done as Lang.Method) as Void {
        if (Config.token().length() > 0) {
            done.invoke(true);
            return;
        }
        var url = Config.serverUrl() + "/devices/register";
        var body = {
            "secret" => Config.secret(),
            "label" => "Garmin",
            "platform" => "android",
        };
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => { "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        Communications.makeWebRequest(url, body, options, new RegisterHandler(done).method(:onResponse));
    }

    //! GET a compact endpoint with the bearer token attached.
    function authedGet(path as Lang.String, params, callback as Lang.Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_GET,
            :headers => { "Authorization" => "Bearer " + Config.token() },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        Communications.makeWebRequest(Config.serverUrl() + path, params, options, callback);
    }

    //! Recent conversations. Response: { c: [ {i,a,s,t,u} ] }
    function chats(limit as Lang.Number, callback as Lang.Method) as Void {
        authedGet("/watch/chats", { "limit" => limit }, callback);
    }

    //! Recent messages in one thread, oldest first. Response: { m: [ {i,d,b,t,p} ] }
    function messages(conversationId as Lang.String, limit as Lang.Number, callback as Lang.Method) as Void {
        authedGet("/watch/messages", { "conversationId" => conversationId, "limit" => limit }, callback);
    }

    //! Queue an outbound SMS: the server hands it to the phone with the SIM.
    function send(address as Lang.String, text as Lang.String, callback as Lang.Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                "Authorization" => "Bearer " + Config.token(),
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        var body = { "to" => address, "body" => text };
        Communications.makeWebRequest(Config.serverUrl() + "/send", body, options, callback);
    }

    //! Delete a whole conversation everywhere.
    function deleteConversation(conversationId as Lang.String, callback as Lang.Method) as Void {
        var options = {
            :method => Communications.HTTP_REQUEST_METHOD_POST,
            :headers => {
                "Content-Type" => Communications.REQUEST_CONTENT_TYPE_JSON,
                "Authorization" => "Bearer " + Config.token(),
            },
            :responseType => Communications.HTTP_RESPONSE_CONTENT_TYPE_JSON,
        };
        Communications.makeWebRequest(
            Config.serverUrl() + "/delete",
            { "conversationId" => conversationId },
            options,
            callback);
    }
}

//! Stores the token from /devices/register, then reports back.
class RegisterHandler {
    private var _done as Lang.Method;

    function initialize(done as Lang.Method) {
        _done = done;
    }

    function onResponse(code as Lang.Number, data) as Void {
        if (code == 200 && data != null && data instanceof Lang.Dictionary) {
            var token = data.get("token");
            if (token != null) {
                Config.setToken(token.toString());
                _done.invoke(true);
                return;
            }
        }
        _done.invoke(false);
    }
}
