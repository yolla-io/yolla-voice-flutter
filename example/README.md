# Yolla Voice example

A dialer built on the `yolla_voice` plugin: it asks a backend for a call token, places the call and shows it.

```sh
cp config/example.json config/local.json   # put the demo token in (ask Yolla for one); the file is git-ignored
flutter run --dart-define-from-file=config/local.json
```

| File | What it shows |
|---|---|
| `lib/app_model.dart` | Where the client lives, placing a call, following `client.call`, the commands |
| `lib/token_provider.dart` | The request to the app's backend for a call token |
| `lib/in_call_screen.dart` | A call screen: state, mute, hold, DTMF, audio routes, quality |
| `lib/dialer_screen.dart`, `lib/settings_screen.dart` | The dialer and where the token comes from |

The demo backend's token is a credential of the demo only: a production app authorises the token request with the
user's own session. The app is under the MIT License.
