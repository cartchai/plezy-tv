import '../player_native.dart';
import '../video_rect_support.dart';

/// Android mpv player: the plain mpv core plus native video-rect support
/// (build #16).
///
/// Same shape as [PlayerLinux]/[PlayerWindows] (`extends PlayerNative with
/// VideoRectSupport`). Before build #16 the factory returned a plain
/// [PlayerNative] on Android, so `Video` never sent a rect there and the
/// mini-player's picture sat in the middle of the full window behind opaque
/// Flutter UI. The native `setVideoRect` handler resizes the surface
/// container to the rect `Video` sends; the plain [PlayerNative] stays
/// rect-less for iOS/macOS (and the audio-only player), where no native
/// handler exists and `Video` must keep its plain branch.
class PlayerNativeAndroid extends PlayerNative with VideoRectSupport {
  PlayerNativeAndroid({super.hardwareDecoding});
}
