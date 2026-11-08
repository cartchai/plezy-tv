import 'player_base.dart';

/// Players whose video lives in a native surface behind the Flutter window,
/// and so must be told where to put it.
///
/// Constrained to [PlayerBase] (it only needs [PlayerBase.invoke]) because
/// the request is the same on every such platform — a Windows child HWND, a
/// Wayland subsurface and an Android surface container take identical
/// geometry — so the mixin carries the call instead of each platform
/// repeating it. `Video` keys its layout reporting off this type: mixing it
/// in is what says the player has a surface worth positioning.
///
/// Build #16: this used to be constrained to [PlayerNative] and mixed in
/// only by the Linux/Windows players, so on Android — where both backends
/// fit the video into the FULL window centered — `Video` never sent a rect
/// and the mini-player's picture sat mid-screen behind opaque Flutter UI
/// ("Video rect sent: no" could never be yes). The Android players now mix
/// it in too ([PlayerNativeAndroid], [PlayerAndroid]) with a native
/// `setVideoRect` handler that resizes the surface container to the rect.
mixin VideoRectSupport on PlayerBase {
  Future<void> setVideoRect({
    required int left,
    required int top,
    required int right,
    required int bottom,
    required double devicePixelRatio,
  }) async {
    await invoke('setVideoRect', {
      'left': left,
      'top': top,
      'right': right,
      'bottom': bottom,
      'devicePixelRatio': devicePixelRatio,
    });
  }
}
