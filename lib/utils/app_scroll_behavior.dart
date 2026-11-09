import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// App-wide scroll behavior: the framework default lets touch, stylus,
/// trackpad and unknown pointers drag-scroll, but NOT the mouse. A Meta
/// Quest controller's laser pointer arrives as a mouse-kind pointer, so
/// without this a trigger-press-and-drag does nothing in every list in the
/// app. Adding mouse changes nothing for touch users, and matches what
/// desktop Flutter apps already do.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    // Quest laser pointer drags (and desktop mouse drags).
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    // VoiceAccess sends pointer events with unknown type when scrolling.
    PointerDeviceKind.unknown,
  };
}
