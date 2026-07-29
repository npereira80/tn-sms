module gmbridge

go 1.25.0

// Dependencies are resolved by Scripts/build-gmbridge.sh, which pins
// mautrix-gmessages to a known-working commit and runs `go mod tidy`.

require (
	github.com/rs/zerolog v1.35.1
	go.mau.fi/mautrix-gmessages v0.2605.1-0.20260617204914-3433cc07d5ea
	google.golang.org/protobuf v1.36.11
)

require (
	github.com/google/uuid v1.6.0 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	go.mau.fi/util v0.9.10 // indirect
	golang.org/x/crypto v0.54.0 // indirect
	golang.org/x/exp v0.0.0-20260611194520-c48552f49976 // indirect
	golang.org/x/mobile v0.0.0-20260709172247-6129f5bee9d5 // indirect
	golang.org/x/mod v0.38.0 // indirect
	golang.org/x/net v0.57.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/sys v0.47.0 // indirect
	golang.org/x/text v0.40.0 // indirect
	golang.org/x/tools v0.48.0 // indirect
)

tool golang.org/x/mobile/cmd/gobind
