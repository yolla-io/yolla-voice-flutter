## 0.1.0

The first version: outgoing calls through the Yolla voice platform with a call token, on iOS and Android.

- `VoiceClient`: `connect`, `hangup`, mute, hold, DTMF, call statistics, audio routes.
- The call as a stream of immutable snapshots (`VoiceClient.call`).
- CallKit on iOS; Telecom, the call notification and the foreground service on Android; the plugin asks for the
  permissions a call needs.
