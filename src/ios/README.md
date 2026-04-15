## ArdopKit (iOS embedded) — client integration guide

This folder contains the iOS “embedded host” build of **ardopcf** packaged as an XCFramework. It is designed to be linked into an iOS app (no TCP host ports, no rig control).

The goal of this README is to describe the **sequence a client app should follow** and what **events/data** to expect back.

### What you link

- **XCFramework**: `build/ArdopKit.xcframework` (build it with `make xcframework-ios`)
- **Public header**: `ArdopKit.h`

### CocoaPods

The repository includes **`ArdopKit.podspec`** at the **repository root**. It vendors `build/ArdopKit.xcframework` and runs `make xcframework-ios` in `prepare_command` if that folder is missing (so `pod install` can build the binary from source on a Mac with Xcode).

**Podfile** (develop against a local checkout):

```ruby
platform :ios, '18.5'

target 'YourApp' do
  use_frameworks! :linkage => :static

  pod 'ArdopKit', :path => '../ardop'   # path to this repo root (where ArdopKit.podspec lives)
end
```

**Podfile** (install from a git revision; same repo layout):

```ruby
platform :ios, '18.5'

target 'YourApp' do
  use_frameworks! :linkage => :static

  pod 'ArdopKit', :git => 'https://github.com/ORG/REPO.git', :branch => 'develop'
end
```

**Publishing**: To push this pod to the CocoaPods trunk, you normally need a **git tag** that contains either a prebuilt `build/ArdopKit.xcframework` or a `prepare_command` that succeeds on CI. Replace `s.source` in the podspec with `:git` + `:tag` when you are ready to publish; the comment in the podspec explains this.

**Swift**: Import the module after linking the pod:

```swift
import ArdopKit
```

### What ArdopKit does (high level)

- Runs the ARDOP modem loop (`ardopmain()`) on a background thread.
- Captures mic audio and plays speaker/headset audio using `AVAudioSession` + `AVAudioEngine`.
- Provides an in-process “host interface”:
  - **App → modem**: submit command strings and push outbound payload bytes.
  - **Modem → app**: receive text/status lines and tagged payload bytes.

### iOS app prerequisites

- **Info.plist** must include:
  - `NSMicrophoneUsageDescription`
- Your app must request mic permission before expecting RX to work.

### Core integration pattern

1) Create the modem object and set a delegate.

2) Start the modem.

3) Send a small set of “setup” commands:
   - Set your station identity (`MYCALL`, optionally `GRIDSQUARE`).
   - Configure audio routing using ARDOP “host commands” (capture/playback).
   - Run `INITIALIZE`.

4) Enter one of two operating modes:
   - **ARQ connected mode** (session / link establishment, used for reliable transfer).
   - **FEC mode** (unconnected broadcast-style frames).

5) When you want to transmit user payload bytes, call `pushData:` and let the modem decide framing.

6) Consume delegate callbacks:
   - Use text lines for UI status / progress.
   - Use tagged data messages for received payload bytes.

### Suggested call sequence (typical app startup)

The exact commands you use can evolve, but this is a solid baseline:

1. **Start**:
   - `-[ArdopKit startWithConfiguration:]`

2. **Initialize modem state**:
   - `-[ArdopKit initializeModem]` which sends `INITIALIZE`

3. **Set station identity** (recommended before ARQ):
   - `-[ArdopKit setMyCall:@"N0CALL"]` which sends `MYCALL N0CALL`
   - `-[ArdopKit setGridSquare:@"AA00aa"]` which sends `GRIDSQUARE AA00aa` (optional)

4. **Select audio devices / routes** (important):
   - Use host commands like `CAPTURE ...` and `PLAYBACK ...`.
   - On iOS, the “device string” is interpreted as “use system route” for any non-`NOSOUND` value.
     - `CAPTURE NONE` closes capture.
     - `PLAYBACK NONE` closes playback.
     - `CAPTURE NOSOUND` / `PLAYBACK NOSOUND` disables hardware I/O (diagnostic).

5. **Switch protocol mode as needed** (examples):
   - ARQ connected workflow typically uses `ARQCALL <TARGET> <ATTEMPTS>` (see “ARQ link establishment” below).
   - FEC workflows use `FECMODE ...` and send frames without a connection.

### Delegate callbacks you’ll receive

Implement `ArdopKitDelegate` methods to receive events:

- **Run state**:
  - `ardopKitDidStart:` / `ardopKitDidStop:`
  - `ardopKit:didChangeRunState:` (Running/Stopped)

- **Text messages** (`ArdopKitTextMessage`):
  - `message.kind`:
    - `ArdopHostTextKindText`: normal status output (OK to show in UI at a low verbosity)
    - `ArdopHostTextKindReply`: command replies (good to show in a debug console)
    - `ArdopHostTextKindTextQuiet`: internal/debug-ish chatter (usually hide unless “verbose”)
  - `message.text` is a single line of ASCII-ish status text (NUL-terminated; may be truncated).

- **Data messages** (`ArdopKitDataMessage`):
  - `message.tag` is a 3-character tag describing the payload class.
  - `message.data` is the raw bytes for that tag.

### Data tags (what they mean)

The modem emits received bytes through the host interface with a short tag:

- **`"ARQ"`**: received payload bytes from an ARQ session (reliable/connected).
- **`"FEC"`**: received payload bytes from FEC frames (unconnected).
- **`"ERR"`**: a received frame failed decode / integrity checks (generally not user-facing; useful for diagnostics/quality).
- **`"IDF"`**: station ID / identification frames (usually UI-visible only in a “monitor” view).

What to surface to the user:

- **Show**:
  - ARQ connect/disconnect state, retries, and a simple “link quality” indicator (derived from text messages).
  - Received payload data for `"ARQ"`/`"FEC"` (your app decides how to interpret bytes).
- **Usually hide** (or put behind a “Diagnostics” toggle):
  - `"ERR"` and verbose/quiet text chatter.
  - Raw `"IDF"` bytes unless your users want a monitor waterfall-style experience.

### ARQ link establishment (what to track)

For an end-user, “connected” ARQ should feel like a chat/file-transfer connection:

- **Client action**: send `ARQCALL <TARGET> <ATTEMPTS>`
- **What to track in UI**:
  - “Connecting…” when you issue the command
  - “Connected” when the modem reports a successful session (via text)
  - “Disconnected” when you send `DISCONNECT` or the modem reports link loss/timeouts
  - Optional: a retry counter and timeout progress (helpful on HF)

What you’ll observe:

- A series of **text messages** showing retries, leader detection, session negotiation, and state transitions.
- Once connected, you should receive `"ARQ"` tagged data for inbound payload.

### Sending and receiving application payload bytes

- **To send**: call `-[ArdopKit pushData:]` with raw bytes.
  - The modem queues bytes and will transmit when appropriate for the current mode/state.
  - You can use the `"BUFFER <n>"` style text updates (from the core) to show queue depth if desired.

- **To receive**:
  - Handle `didReceiveDataMessage:`
  - For `"ARQ"` and `"FEC"` tags, treat `message.data` as your application payload.

### Logging / user experience tips

- Maintain two UI surfaces:
  - **Status**: short, user-friendly connection + TX/RX indicators.
  - **Diagnostics console**: raw text lines + tags for troubleshooting.

- Avoid showing every line: the modem can be chatty. A good heuristic:
  - Show `Reply` lines and a curated subset of `Text` lines.
  - Hide `TextQuiet` unless a “Verbose logging” toggle is enabled.

### Notes / limitations (current)

- The wrapper and audio engine handle basic operation but do not yet implement full iOS interruption/route-change recovery (e.g. phone calls, unplugging audio interfaces). If your app targets real-world use, you’ll likely want to restart audio/modem on interruption events.
- Rig control (serial/CM108/hamlib) is intentionally out of scope for iOS in this embedded build.

