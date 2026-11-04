// This file is a part of media_kit (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'package:flutter/widgets.dart';
import 'package:media_kit_video_tvos/media_kit_video.dart';

/// {@template no_video_controls}
///
/// Disables [Video] controls.
///
/// {@endtemplate}
class NoVideoControls extends StatelessWidget {
  const NoVideoControls(this.state, {super.key});

  final VideoState state;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
