import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/widgets/backend_badge.dart';

void main() {
  // Regression: the Xtream + M3U icons shipped in assets/ but were never
  // declared in pubspec.yaml, so every screen showing one of those badges
  // crashed on the phone with "Unable to load asset" (seen on-device
  // 2026-11-11). This direct bundle read is the real guard: the widget
  // test below passed even with the icons missing (the SVG load error
  // never reached the test), while the phone crashed — this load throws
  // exactly like the phone's PlatformAssetBundle.load does.
  test('backend badge icons are bundled', () async {
    for (final asset in [
      'assets/plex_chevron.svg',
      'assets/jellyfin_icon.svg',
      'assets/emby_icon.svg',
      'assets/m3u_icon.svg',
      'assets/xtream_icon.svg',
    ]) {
      await rootBundle.load(asset);
    }
  });

  Future<void> pumpBadge(WidgetTester tester, MediaBackend backend) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Center(child: BackendBadge(backend: backend))),
      ),
    );
  }

  // Plex/Jellyfin/Emby are the controls — their icons were declared.
  for (final backend in MediaBackend.values) {
    testWidgets(
      'BackendBadge renders for ${backend.name} without throwing',
      (tester) async {
        await pumpBadge(tester, backend);
        await tester.pumpAndSettle();
        expect(find.byType(SvgPicture), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
