package gmbridge

import (
	"encoding/json"
	"fmt"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

// handleEvent converts libgm's typed events into (eventType, JSON) pairs
// for the Swift side.
func (c *Client) handleEvent(rawEvt any) {
	switch evt := rawEvt.(type) {
	case *events.PairSuccessful:
		c.emit(EventPairSuccessful, map[string]any{"phoneID": evt.PhoneID})
	case *events.ClientReady:
		convs := make([]json.RawMessage, 0, len(evt.Conversations))
		for _, conv := range evt.Conversations {
			if raw, err := pjMarshal.Marshal(conv); err == nil {
				convs = append(convs, raw)
			}
		}
		c.emit(EventReady, map[string]any{
			"sessionID":     evt.SessionID,
			"conversations": convs,
		})
	case *libgm.WrappedMessage:
		raw, err := pjMarshal.Marshal(evt.Message)
		if err != nil {
			c.log.Err(err).Msg("Failed to marshal message event")
			return
		}
		c.emit(EventMessage, map[string]any{
			"isOld":   evt.IsOld,
			"message": json.RawMessage(raw),
		})
	case *gmproto.Conversation:
		raw, err := pjMarshal.Marshal(evt)
		if err != nil {
			c.log.Err(err).Msg("Failed to marshal conversation event")
			return
		}
		c.emit(EventConversation, map[string]any{
			"conversation": json.RawMessage(raw),
		})
	case *gmproto.TypingData:
		raw, _ := pjMarshal.Marshal(evt)
		c.emit(EventTyping, map[string]any{
			"conversationID": evt.GetConversationID(),
			"started":        evt.GetType() == gmproto.TypingTypes_STARTED_TYPING,
			"raw":            json.RawMessage(raw),
		})
	case *gmproto.Settings:
		c.mu.Lock()
		c.settings = evt
		c.mu.Unlock()
		raw, _ := pjMarshal.Marshal(evt)
		c.emit(EventSettings, map[string]any{"settings": json.RawMessage(raw)})
	case *gmproto.UserAlertEvent:
		c.emit(EventUserAlert, map[string]any{"alertType": evt.GetAlertType().String()})
	case *events.BrowserActive:
		c.emit(EventBrowserActive, map[string]any{"sessionID": evt.SessionID})
	case *events.AuthTokenRefreshed:
		c.emit(EventAuthTokenRefreshed, map[string]any{})
	case *events.ListenFatalError:
		c.emit(EventListenFatal, map[string]any{"error": errString(evt.Error)})
	case *events.ListenTemporaryError:
		c.emit(EventListenTempError, map[string]any{"error": errString(evt.Error)})
	case *events.ListenRecovered:
		c.emit(EventListenRecovered, map[string]any{})
	case *events.PhoneNotResponding:
		c.emit(EventPhoneNotResponding, map[string]any{})
	case *events.PhoneRespondingAgain:
		c.emit(EventPhoneResponding, map[string]any{})
	case *events.PingFailed:
		c.emit(EventPingFailed, map[string]any{
			"error": errString(evt.Error),
			"count": evt.ErrorCount,
		})
	case *events.GaiaLoggedOut:
		c.emit(EventGaiaLoggedOut, map[string]any{})
	case *events.AccountChange:
		c.emit(EventAccountChange, map[string]any{
			"account": evt.GetAccount(),
			"enabled": evt.GetEnabled(),
			"isFake":  evt.IsFake,
		})
	case *events.NoDataReceived:
		c.emit(EventNoDataReceived, map[string]any{})
	case *gmproto.RevokePairData:
		c.emit(EventPairRevoked, map[string]any{})
	case *events.HackySetActiveMayFail:
		// Internal libgm quirk event; nothing for the app to do.
	default:
		c.emit(EventUnknown, map[string]any{"goType": fmt.Sprintf("%T", rawEvt)})
	}
}

func (c *Client) emit(eventType string, payload any) {
	if c.sink == nil {
		return
	}
	data, err := json.Marshal(payload)
	if err != nil {
		c.log.Err(err).Str("event_type", eventType).Msg("Failed to marshal event payload")
		data = []byte("{}")
	}
	c.sink.OnEvent(eventType, string(data))
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
