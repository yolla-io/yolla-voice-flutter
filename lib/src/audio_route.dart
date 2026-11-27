//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// This file is part of the Yolla Voice plugin for Flutter. See the LICENSE file in the repository root.
//

import 'package:flutter/foundation.dart';

/// What kind of output an [AudioRoute] is. Later versions can add values: keep a default branch.
enum AudioRouteKind { earpiece, speaker, bluetooth, wired, other }

/// A place the call's audio can go: the earpiece, the speaker, a headset.
@immutable
class AudioRoute {
  const AudioRoute({required this.id, required this.kind, required this.name});

  /// Identifies the route among [AudioRoutes.available] for as long as it is there.
  final String id;
  final AudioRouteKind kind;

  /// The system's name for it ("Speaker", the headset's name), in the system's language where it has one.
  final String name;

  @override
  bool operator ==(Object other) => other is AudioRoute && other.id == id && other.kind == kind && other.name == name;

  @override
  int get hashCode => Object.hash(id, kind, name);

  @override
  String toString() => 'AudioRoute(${kind.name}: $name)';
}

/// The audio routes of the call in progress: `VoiceClient.audioRoutes`. Empty when there is no call.
@immutable
class AudioRoutes {
  const AudioRoutes({this.available = const [], this.current});

  final List<AudioRoute> available;

  /// The route in use; null when it is not known (yet).
  final AudioRoute? current;

  @override
  bool operator ==(Object other) =>
      other is AudioRoutes && listEquals(other.available, available) && other.current == current;

  @override
  int get hashCode => Object.hash(Object.hashAll(available), current);
}
