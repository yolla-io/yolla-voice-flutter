# Yolla Voice for Flutter

Place phone calls from a Flutter app through the Yolla voice platform, on iOS and Android. The plugin carries
signalling and audio and does the system's part of a call itself; your app owns the user interface.

- Outgoing calls to phone numbers, with mute, hold, DTMF and automatic reconnection when the network changes
- CallKit on iOS; Telecom, the call notification and the foreground service on Android: calls show on the lock
  screen, go on in the background and give way to other calls, with no native code in your app
- Audio routes (earpiece, speaker, Bluetooth, wired) and the proximity sensor
- Call quality statistics and warnings
- Ringback, busy and end tones, with no audio files to ship

The plugin is a wrapper around the native [Yolla Voice SDK for iOS](https://github.com/yolla-io/yolla-voice-ios) and
the Yolla Voice SDK for Android.

## Requirements

- Flutter 3.50 or later
- iOS 17 or later, with Swift Package Manager (Flutter's default); CocoaPods is not supported
- Android 8.0 (API 26) or later
- A Yolla account, and a backend of yours that asks the Yolla platform for call tokens

## Installation

In `pubspec.yaml`:

```yaml
dependencies:
  yolla_voice:
    git:
      url: https://github.com/yolla-io/yolla-voice-flutter.git
      ref: 0.1.0
```

**iOS.** Set the deployment target of the app to iOS 17, and in `ios/Runner/Info.plist` add:

- `NSMicrophoneUsageDescription`: the text iOS shows when it asks for the microphone;
- the background modes `audio` and `voip` (`UIBackgroundModes`).

**Android.** Set `minSdk = 26` in `android/app/build.gradle.kts`. The plugin's manifest brings the permissions and the
call service; there is nothing to add to yours.

## How a call works

```
  your app  ──  "call +4915112345678"  ──▶  your backend  ──  API key  ──▶  Yolla platform
  your app  ◀──────  call token  ─────────  your backend  ◀──  call token  ──  Yolla platform
  your app  ──  connect(callToken)  ───────────────────────────────────────▶  Yolla platform
```

1. Your backend asks the Yolla platform for a **call token**: a short-lived JWT issued for one call, with the
   destination and the caller ID inside. API keys stay on your backend.
2. Your app gets the token from your backend and passes it to the plugin.
3. The plugin places the call and reports its progress in `VoiceClient.call`.

## Quick start

```dart
import 'package:yolla_voice/yolla_voice.dart';

final client = VoiceClient(); // every VoiceClient() is the same client

Future<void> dial(String number) async {
  final token = await fetchCallToken(to: number); // from your backend, one per call
  try {
    await client.connect(token);
  } on VoiceError catch (e) {
    // No call started: the microphone is not allowed, the token cannot be read, a call is already in progress.
    print('${e.code}: ${e.message}');
  }
}

// The call screen
ValueListenableBuilder<Call?>(
  valueListenable: client.call,
  builder: (context, call, _) => switch (call?.state) {
    null => const Text('No call'),
    CallState.connecting => const Text('Connecting…'),
    CallState.ringing => const Text('Ringing…'),
    CallState.connected => Text(call!.isOnHold ? 'On hold' : 'Connected'),
    CallState.reconnecting => const Text('Reconnecting…'),
    CallState.disconnected => Text('Ended: ${call!.endReason?.name} ${call.error?.code ?? ''}'),
  },
);

// During the call
await client.setMuted(true);
await client.setOnHold(true);
await client.sendDigits('1#');
await client.hangup();
```

## The API

- **`client.call`** is a `ValueListenable<Call?>` (and `client.calls` the same as a stream): `null` until the first
  call, then the call as it is now, a new value every time something about it changes. A `Call` is an immutable
  snapshot: state, end reason, error, `wasConnected`, mute, hold, early media, quality warnings.
- **The outcome of a call.** An ended call stays in `client.call` until the next `connect`. Record history and
  analytics in a listener that lives as long as the app, not a screen. `wasConnected` tells "never got through" from
  "dropped after the answer" when the end reason is `failed`.
- **`connect`** returns as soon as the call has started and throws `VoiceError` only when no call can start
  (`invalid_token`, `microphone_denied`, `call_in_progress`, `cancelled` when `hangup` came meanwhile); `client.call`
  does not change then. Everything after that, a failure of the set-up included, comes in `client.call`: a call that
  fails ends as `disconnected` with the reason `failed` and the error.
- **The token is single-use.** Ask your backend for a new one before every call.
- **`hangup`** ends the call at any moment and never throws; the end comes in `client.call` (`cancelled` before the
  answer, `localHangup` after it).
- **`setMuted`** is local and immediate, and works while the call is being set up. **`setOnHold`** and
  **`sendDigits`** need an answered call. They throw `VoiceError` (`invalid_call_state`, `sip_<status>`,
  `dtmf_unavailable`, `system_call_failed`).
- **`client.audioRoutes`** lists where the call's audio can go and where it goes; `selectAudioRoute` changes it. It
  is empty when there is no call.
- **`client.stats()`** gives the audio statistics at this moment; the values change once a second.
- New values may be added to the enums later: keep a default branch.

### Errors

`VoiceError.code` is what your code acts on; `message` is English text for the log, not for the user.

| Code | When |
|---|---|
| `invalid_token` | The call token cannot be read, has expired or was already used |
| `microphone_denied` | The user has not allowed the microphone; send them to the app's settings |
| `call_in_progress` | The client's call has not ended yet |
| `invalid_call_state` | There is no call, or it is not in a state that allows the command |
| `sip_<status>` | The network refused the call or the hold; `sipStatus` has the number (486 busy, 480 not available) |
| `timeout` | Nobody answered within 90 seconds, or the network did not answer a request |
| `media_failed`, `media_timeout` | The audio could not be set up, or the call could not be restored after a network change |
| `network_error`, `http_<status>`, `protocol_error` | The platform could not be reached or refused the request |
| `dtmf_unavailable` | This call cannot carry digits |
| `system_call_failed` | CallKit or Telecom did not take a command |
| `network_changed`, `ice_failed`, `signaling_reconnected` | Not failures: what was noticed, while the call is `reconnecting` |

## What the plugin does for you

- **Permissions.** When the first call is placed the plugin asks the user for the microphone, and on Android also
  for notifications (the call notification, Android 13+) and Bluetooth (headsets, Android 12+). Without the
  microphone `connect` throws `microphone_denied`; the other two are optional.
- **iOS.** Calls go through CallKit: the system's call screen, the lock screen, interruptions by other calls, the
  audio session. When CallKit refuses a call (it is not available to apps in mainland China) the call goes on without
  it and the plugin manages the audio session itself. Calls are not listed in the Phone app's recents.
- **Android.** Calls are self-managed Telecom calls (`androidx.core:core-telecom`), with a foreground service and an
  ongoing call notification with a "Hang up" action. On a device without Telecom the call goes on without it. To
  change the notification's small icon or the name of its channel, add a drawable `yolla_voice_ic_call` or a string
  `yolla_voice_notification_channel` to your app's resources.
- **The call outlives the screen.** The call belongs to the process, not to the Flutter engine: when the app's
  screen is closed during a call the call goes on, and a `VoiceClient` created later finds it in `client.call`.

## Example app

[`example/`](example) is a complete app: a dialer, a call screen with mute, hold, a DTMF keypad, audio routes and
quality indicators. It asks the Yolla demo backend for call tokens; the backend's credential is not in the
repository:

```sh
cd example
cp config/example.json config/local.json   # put the demo token in (ask Yolla for one); the file is git-ignored
flutter run --dart-define-from-file=config/local.json
```

Without the token the app says what to set; a call token pasted in its Settings works too.

## Privacy

The plugin adds nothing to what the native SDKs collect. To place calls they send the platform the dialled number, a
device identifier they generate, device and app information, call quality statistics and, when the platform asks for
it, their diagnostic log. See the native SDKs' documentation for the details your App Store privacy answers and Play
Data safety form need.

## Support

When you report a problem, include the SDK version (`await client.sdkVersion`), the call's `Call.callId`, when the
call was made, and the `code` and `message` of the `VoiceError` if there was one.

