import 'dart:io';

import 'package:flutter/services.dart';

/// Which landscape side to turn the screen to, from the accelerometer's
/// gravity along the phone's width ([x], m/s²): positive with its left
/// edge down, negative with its right edge down. Null in between (held
/// upright, or lying flat): stay on the current side.
///
/// Android and iOS name the two sides the other way round: Flutter's
/// landscapeLeft is the screen turned so its top is on the left on Android,
/// but UIKit's landscape left (its top on the right) on an iPhone. Picked
/// as on Android, an iPhone's player turned upside down from how it was
/// held.
DeviceOrientation? landscapeSideFor(double x) {
  final leftEdgeDown = x > 4.0;
  final rightEdgeDown = x < -4.0;
  if (!leftEdgeDown && !rightEdgeDown) return null;
  final topOnLeft = leftEdgeDown;
  if (Platform.isIOS) {
    return topOnLeft
        ? DeviceOrientation.landscapeRight
        : DeviceOrientation.landscapeLeft;
  }
  return topOnLeft
      ? DeviceOrientation.landscapeLeft
      : DeviceOrientation.landscapeRight;
}
