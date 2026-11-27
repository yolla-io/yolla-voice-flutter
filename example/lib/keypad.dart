//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'package:material_ui/material_ui.dart';

/// A phone keypad: the dialer types a number with it, the call screen sends DTMF digits.
class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onKey, this.showsBackspace = true});

  static const backspace = '⌫';
  final ValueChanged<String> onKey;
  final bool showsBackspace;

  @override
  Widget build(BuildContext context) {
    final rows = [
      ['1', '2', '3'],
      ['4', '5', '6'],
      ['7', '8', '9'],
      ['*', '0', '#'],
      if (showsBackspace) ['+', '', backspace],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in rows)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              for (final key in row)
                SizedBox(
                  width: 72,
                  height: 56,
                  child: key.isEmpty
                      ? null
                      : TextButton(
                          key: ValueKey('key $key'),
                          onPressed: () => onKey(key),
                          child: Text(key, style: Theme.of(context).textTheme.headlineSmall),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}
