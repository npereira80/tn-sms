// Package gmbridge wraps go.mau.fi/mautrix-gmessages/pkg/libgm with a
// gomobile-compatible API surface (strings, ints, bools, []byte and one
// callback interface) so the Swift app can drive the Google Messages
// web-pairing protocol.
//
// Build with: gomobile bind -target macos -o build/Gmbridge.xcframework .
package gmbridge

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sync"
	"time"

	"github.com/rs/zerolog"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/util"
)

func init() {
	// Identity shown in Google Messages > Device pairing. Presenting as a
	// web/Safari client (rather than libgm's default tablet) makes the
	// phone show the OS string as-is instead of appending "(Android)".
	util.BrowserDetailsMessage.OS = "SMS TN (MacOS)"
	util.BrowserDetailsMessage.BrowserType = gmproto.BrowserType_SAFARI
	util.BrowserDetailsMessage.DeviceType = gmproto.DeviceType_WEB
}

// EventSink receives asynchronous events from the protocol layer.
// eventType is one of the Event* constants; payloadJSON is a JSON object
// whose shape depends on the event type. Callbacks arrive on arbitrary
// (Go-managed) threads; the Swift side must hop to its own actor/queue.
type EventSink interface {
	OnEvent(eventType string, payloadJSON string)
}

// Event type constants emitted through EventSink.
const (
	EventPairSuccessful      = "pair_successful"
	EventReady               = "ready"
	EventMessage             = "message"
	EventConversation        = "conversation"
	EventTyping              = "typing"
	EventSettings            = "settings"
	EventUserAlert           = "user_alert"
	EventBrowserActive       = "browser_active"
	EventAuthTokenRefreshed  = "auth_token_refreshed"
	EventListenFatal         = "listen_fatal"
	EventListenTempError     = "listen_temp_error"
	EventListenRecovered     = "listen_recovered"
	EventPhoneNotResponding  = "phone_not_responding"
	EventPhoneResponding     = "phone_responding_again"
	EventPingFailed          = "ping_failed"
	EventGaiaLoggedOut       = "gaia_logged_out"
	EventAccountChange       = "account_change"
	EventNoDataReceived      = "no_data_received"
	EventPairRevoked         = "pair_revoked"
	EventGaiaEmoji           = "gaia_emoji"
	EventGaiaError           = "gaia_error"
	EventUnknown             = "unknown"
)

// Reaction actions for SendReaction.
const (
	ReactionActionAdd    = 1
	ReactionActionRemove = 2
	ReactionActionSwitch = 3
)

// Conversation folders for ListConversations.
const (
	FolderInbox       = 1
	FolderArchive     = 2
	FolderSpamBlocked = 5
)

var errNotConfigured = errors.New("client not configured; call Configure first")

var pjMarshal = protojson.MarshalOptions{}

// Client is the gomobile-exported wrapper around libgm.Client.
type Client struct {
	mu       sync.Mutex
	sink     EventSink
	log      zerolog.Logger
	client   *libgm.Client
	settings *gmproto.Settings
}

// NewClient creates an unconfigured client. Call Configure next.
func NewClient(sink EventSink) *Client {
	writer := zerolog.ConsoleWriter{Out: os.Stderr, TimeFormat: time.TimeOnly}
	return &Client{
		sink: sink,
		log:  zerolog.New(writer).With().Timestamp().Logger().Level(zerolog.InfoLevel),
	}
}

// SetLogLevel accepts trace|debug|info|warn|error.
func (c *Client) SetLogLevel(level string) {
	parsed, err := zerolog.ParseLevel(level)
	if err == nil {
		c.log = c.log.Level(parsed)
	}
}

// Configure prepares the underlying libgm client. Pass the persisted
// session JSON (from SessionJSON) to resume an existing pairing, or an
// empty string to start fresh (before QR pairing).
func (c *Client) Configure(sessionJSON string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	authData := libgm.NewAuthData()
	if sessionJSON != "" {
		authData = &libgm.AuthData{}
		if err := json.Unmarshal([]byte(sessionJSON), authData); err != nil {
			return fmt.Errorf("invalid session data: %w", err)
		}
	}
	cli := libgm.NewClient(authData, nil, c.log)
	cli.SetEventHandler(c.handleEvent)
	c.client = cli
	return nil
}

func (c *Client) getClient() (*libgm.Client, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.client == nil {
		return nil, errNotConfigured
	}
	return c.client, nil
}

// IsLoggedIn reports whether a pairing session exists.
func (c *Client) IsLoggedIn() bool {
	cli, err := c.getClient()
	return err == nil && cli.IsLoggedIn()
}

// IsConnected reports whether the long-poll connection is up.
func (c *Client) IsConnected() bool {
	cli, err := c.getClient()
	return err == nil && cli.IsConnected()
}

// SessionJSON serializes the current auth/session state. Persist this in
// the Keychain after pair_successful and auth_token_refreshed events.
// Returns []byte (UTF-8) so gomobile bridges it to a throwing Swift call.
func (c *Client) SessionJSON() ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	return json.Marshal(cli.AuthData)
}

// StartQRLogin begins QR pairing on a freshly configured client and
// returns the QR code payload URL to render (UTF-8 bytes). The QR code
// expires after ~30 seconds; call RefreshQR for a new one. On success
// the bridge emits pair_successful, reconnects itself, then emits ready.
func (c *Client) StartQRLogin() ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := cli.FetchConfig(ctx); err != nil {
		return nil, fmt.Errorf("failed to fetch config: %w", err)
	}
	qr, err := cli.StartLogin()
	if err != nil {
		return nil, err
	}
	return []byte(qr), nil
}

// RefreshQR returns a fresh QR code payload (UTF-8 bytes) while pairing
// is in progress.
func (c *Client) RefreshQR() ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	qr, err := cli.RefreshPhoneRelay()
	if err != nil {
		return nil, err
	}
	return []byte(qr), nil
}

// StartGoogleLogin performs Google-account (Gaia) pairing, the method
// current Google Messages versions use instead of QR. cookiesJSON is a
// JSON object of Google cookies (SID, HSID, OSID, SSID, APISID, SAPISID,
// and optionally __Secure-1PSIDTS) harvested from a signed-in Google web
// session.
//
// This returns as soon as config fetch succeeds. The pairing then runs
// in the background and reports progress via events:
//   - "gaia_emoji"  {emoji}     show this emoji; the user confirms the
//                                matching one on their phone
//   - "pair_successful"         phone confirmed; bridge reconnects, then
//                                emits "ready"
//   - "gaia_error"  {error}     pairing failed (wrong emoji, timeout, …)
func (c *Client) StartGoogleLogin(cookiesJSON string) error {
	var cookies map[string]string
	if err := json.Unmarshal([]byte(cookiesJSON), &cookies); err != nil {
		return fmt.Errorf("invalid cookies: %w", err)
	}
	if len(cookies) == 0 {
		return errors.New("no cookies provided")
	}

	authData := libgm.NewAuthData()
	authData.Cookies = cookies
	cli := libgm.NewClient(authData, nil, c.log)
	cli.SetEventHandler(c.handleEvent)

	c.mu.Lock()
	c.client = cli
	c.mu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := cli.FetchConfig(ctx); err != nil {
		return fmt.Errorf("failed to fetch config (check that you are signed in): %w", err)
	}

	go func() {
		pairCtx, pcancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer pcancel()
		err := cli.DoGaiaPairing(pairCtx, func(emoji string) {
			c.emit(EventGaiaEmoji, map[string]any{"emoji": emoji})
		})
		if err != nil {
			c.emit(EventGaiaError, map[string]any{"error": err.Error()})
		}
	}()
	return nil
}

// Connect starts the realtime long-poll connection for a paired session.
// Do not call this right after QR pairing: the bridge reconnects itself.
func (c *Client) Connect() error {
	cli, err := c.getClient()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := cli.FetchConfig(ctx); err != nil {
		// Match upstream connector behavior: log but keep going.
		c.log.Warn().Err(err).Msg("Failed to fetch config before connect")
	}
	return cli.Connect()
}

// Disconnect stops the long-poll connection.
func (c *Client) Disconnect() {
	cli, err := c.getClient()
	if err == nil {
		cli.Disconnect()
	}
}

// Unpair removes the pairing both locally and on the phone.
func (c *Client) Unpair() error {
	cli, err := c.getClient()
	if err != nil {
		return err
	}
	return cli.Unpair()
}

// ListConversations returns protojson of gmproto.ListConversationsResponse.
// folder is one of the Folder* constants.
func (c *Client) ListConversations(count int, folder int) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	resp, err := cli.ListConversations(count, gmproto.ListConversationsRequest_Folder(folder))
	if err != nil {
		return nil, err
	}
	return marshalProto(resp)
}

// StartConversation gets or creates a 1:1 conversation for the given
// phone numbers and returns the conversation protojson. numbersJSON is a
// JSON array of phone number strings, e.g. ["+351912345678"]. Use the
// returned conversation's conversationID + defaultOutgoingID to send.
func (c *Client) StartConversation(numbersJSON string) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	var numbers []string
	if err := json.Unmarshal([]byte(numbersJSON), &numbers); err != nil {
		return nil, fmt.Errorf("invalid numbers: %w", err)
	}
	if len(numbers) == 0 {
		return nil, errors.New("no numbers provided")
	}
	contactNumbers := make([]*gmproto.ContactNumber, 0, len(numbers))
	for _, n := range numbers {
		contactNumbers = append(contactNumbers, &gmproto.ContactNumber{
			MysteriousInt: 7, // user-entered number
			Number:        n,
			Number2:       n,
		})
	}
	resp, err := cli.GetOrCreateConversation(&gmproto.GetOrCreateConversationRequest{
		Numbers: contactNumbers,
	})
	if err != nil {
		return nil, err
	}
	if resp.GetConversation() == nil {
		return nil, errors.New("no conversation returned")
	}
	return marshalProto(resp.GetConversation())
}

// GetConversation returns protojson of a single gmproto.Conversation.
func (c *Client) GetConversation(conversationID string) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	conv, err := cli.GetConversation(conversationID)
	if err != nil {
		return nil, err
	}
	return marshalProto(conv)
}

// ListMessages returns protojson of gmproto.ListMessagesResponse.
// For the first page pass cursorLastItemID="" and cursorTimestamp=0; for
// older pages pass the cursor fields from the previous response.
func (c *Client) ListMessages(conversationID string, count int, cursorLastItemID string, cursorTimestamp int64) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	var cursor *gmproto.Cursor
	if cursorLastItemID != "" {
		cursor = &gmproto.Cursor{
			LastItemID:        cursorLastItemID,
			LastItemTimestamp: cursorTimestamp,
		}
	}
	resp, err := cli.FetchMessages(conversationID, int64(count), cursor)
	if err != nil {
		return nil, err
	}
	return marshalProto(resp)
}

// SendTextMessage sends a text message. participantID is the conversation's
// defaultOutgoingID. Returns JSON: {"tmpID": "...", "status": "SUCCESS"}.
func (c *Client) SendTextMessage(conversationID, participantID, text string, forceRCS bool) ([]byte, error) {
	info := []*gmproto.MessageInfo{{
		Data: &gmproto.MessageInfo_MessageContent{
			MessageContent: &gmproto.MessageContent{Content: text},
		},
	}}
	return c.sendMessage(conversationID, participantID, info, forceRCS)
}

// SendMediaMessage sends previously uploaded media (see UploadMedia) with
// an optional caption. mediaContentJSON is the protojson MediaContent
// returned by UploadMedia. Returns the same JSON shape as SendTextMessage.
func (c *Client) SendMediaMessage(conversationID, participantID, mediaContentJSON, caption string, forceRCS bool) ([]byte, error) {
	var media gmproto.MediaContent
	if err := protojson.Unmarshal([]byte(mediaContentJSON), &media); err != nil {
		return nil, fmt.Errorf("invalid media content: %w", err)
	}
	info := []*gmproto.MessageInfo{{
		Data: &gmproto.MessageInfo_MediaContent{MediaContent: &media},
	}}
	if caption != "" {
		info = append(info, &gmproto.MessageInfo{
			Data: &gmproto.MessageInfo_MessageContent{
				MessageContent: &gmproto.MessageContent{Content: caption},
			},
		})
	}
	return c.sendMessage(conversationID, participantID, info, forceRCS)
}

func (c *Client) sendMessage(conversationID, participantID string, info []*gmproto.MessageInfo, forceRCS bool) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	tmpID := randomTmpID()
	req := &gmproto.SendMessageRequest{
		ConversationID: conversationID,
		TmpID:          tmpID,
		MessagePayload: &gmproto.MessagePayload{
			TmpID:          tmpID,
			TmpID2:         tmpID,
			ConversationID: conversationID,
			ParticipantID:  participantID,
			MessageInfo:    info,
		},
		SIMPayload: c.currentSIMPayload(),
		ForceRCS:   forceRCS,
	}
	resp, err := cli.SendMessage(req)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"tmpID":  tmpID,
		"status": resp.GetStatus().String(),
	})
}

// UploadMedia encrypts and uploads attachment bytes, returning protojson
// MediaContent to pass to SendMediaMessage.
func (c *Client) UploadMedia(data []byte, fileName, mimeType string) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	media, err := cli.UploadMedia(data, fileName, mimeType)
	if err != nil {
		return nil, err
	}
	return marshalProto(media)
}

// DownloadMedia fetches and decrypts an attachment. keyBase64 is the
// standard-base64 decryptionKey (or thumbnailDecryptionKey) from the
// message's MediaContent.
func (c *Client) DownloadMedia(mediaID string, keyBase64 string) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	key, err := base64.StdEncoding.DecodeString(keyBase64)
	if err != nil {
		return nil, fmt.Errorf("invalid media key: %w", err)
	}
	return cli.DownloadMedia(mediaID, key)
}

// GetParticipantThumbnail returns protojson GetThumbnailResponse with
// avatar image bytes for a participant.
func (c *Client) GetParticipantThumbnail(participantID string) ([]byte, error) {
	cli, err := c.getClient()
	if err != nil {
		return nil, err
	}
	resp, err := cli.GetParticipantThumbnail(participantID)
	if err != nil {
		return nil, err
	}
	return marshalProto(resp)
}

// MarkRead sends a read receipt for a message.
func (c *Client) MarkRead(conversationID, messageID string) error {
	cli, err := c.getClient()
	if err != nil {
		return err
	}
	return cli.MarkRead(conversationID, messageID)
}

// SetTyping notifies the conversation that the user is typing.
func (c *Client) SetTyping(conversationID string) error {
	cli, err := c.getClient()
	if err != nil {
		return err
	}
	return cli.SetTyping(conversationID, c.currentSIMPayload())
}

// SendReaction adds/removes/switches an emoji reaction on a message.
// action is one of the ReactionAction* constants.
func (c *Client) SendReaction(messageID, emoji string, action int) error {
	cli, err := c.getClient()
	if err != nil {
		return err
	}
	resp, err := cli.SendReaction(&gmproto.SendReactionRequest{
		MessageID:    messageID,
		ReactionData: gmproto.MakeReactionData(emoji),
		Action:       gmproto.SendReactionRequest_Action(action),
		SIMPayload:   c.currentSIMPayload(),
	})
	if err != nil {
		return err
	}
	if !resp.GetSuccess() {
		return errors.New("reaction was rejected")
	}
	return nil
}

// DeleteMessage deletes a message (mirrored to the phone).
func (c *Client) DeleteMessage(messageID string) error {
	cli, err := c.getClient()
	if err != nil {
		return err
	}
	resp, err := cli.DeleteMessage(messageID)
	if err != nil {
		return err
	}
	if !resp.GetSuccess() {
		return errors.New("delete was rejected")
	}
	return nil
}

func (c *Client) currentSIMPayload() *gmproto.SIMPayload {
	c.mu.Lock()
	defer c.mu.Unlock()
	sims := c.settings.GetSIMCards()
	if len(sims) == 0 {
		return nil
	}
	return sims[0].GetSIMData().GetSIMPayload()
}

func marshalProto(msg proto.Message) ([]byte, error) {
	return pjMarshal.Marshal(msg)
}

func randomTmpID() string {
	var buf [8]byte
	_, _ = rand.Read(buf[:])
	return "tmp_" + hex.EncodeToString(buf[:])
}
