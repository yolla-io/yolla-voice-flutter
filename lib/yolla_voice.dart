//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

/// Phone calls through the Yolla voice platform.
///
/// Create a [VoiceClient], get a call token from your backend and pass it to [VoiceClient.connect]; follow the call
/// in [VoiceClient.call].
library;

export 'src/audio_route.dart';
export 'src/call.dart';
export 'src/call_stats.dart';
export 'src/voice_client.dart';
export 'src/voice_error.dart';
