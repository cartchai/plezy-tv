import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/ids.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/media/media_person.dart';
import 'package:plezy/media/search_hit.dart';
import 'package:plezy/utils/search_sections.dart';

import '../test_helpers/media_items.dart';

void main() {
  group('groupSearchResults (build #8 Task 2)', () {
    String labelOf(item) => item.libraryTitle ?? item.serverName ?? item.kind.id;

    test('groups by library in Movies / TV / Live TV / other order', () {
      // Deliberately ranked out of order: the show ranks first, the movie
      // second — sections still come out Movies, TV Shows, Live TV.
      final hits = [
        MediaSearchHit(
          testMediaItem(
            id: 'show_1',
            backend: MediaBackend.plex,
            kind: MediaKind.show,
            title: 'Alpha Show',
            serverId: 'conn-xt-1',
            serverName: 'Trex',
            libraryId: 'series',
            libraryTitle: 'Trex — Series',
          ),
        ),
        MediaSearchHit(
          testMediaItem(
            id: 'movie_1',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'Alpha Movie',
            serverId: 'conn-xt-1',
            serverName: 'Trex',
            libraryId: 'movies',
            libraryTitle: 'Trex — Movies',
          ),
        ),
        MediaSearchHit(
          testMediaItem(
            id: 'ch_1',
            backend: MediaBackend.plex,
            kind: MediaKind.unknown,
            title: 'Alpha Channel',
            serverId: 'conn-m3u-1',
            serverName: 'Trex M3U',
            libraryId: 'iptv:conn-m3u-1:live',
            libraryTitle: 'Trex — Live TV',
          ),
        ),
        MediaSearchHit(
          testMediaItem(
            id: 'track_1',
            backend: MediaBackend.plex,
            kind: MediaKind.track,
            title: 'Alpha Theme',
            serverId: 'server_1',
            serverName: 'HOME PC',
            libraryId: '3',
            libraryTitle: 'Music',
          ),
        ),
      ];
      final sections = groupSearchResults(hits, libraryLabel: labelOf);
      expect(sections.map((s) => s.label), ['Trex — Movies', 'Trex — Series', 'Trex — Live TV', 'Music']);
      expect(sections[0].hits.map((h) => (h as MediaSearchHit).item.title), ['Alpha Movie']);
      expect(sections[1].hits.map((h) => (h as MediaSearchHit).item.title), ['Alpha Show']);
      expect(sections[2].hits.map((h) => (h as MediaSearchHit).item.title), ['Alpha Channel']);
      expect(sections[3].hits.map((h) => (h as MediaSearchHit).item.title), ['Alpha Theme']);
    });

    test('a Plex library keeps its own section apart from the IPTV one', () {
      final hits = [
        MediaSearchHit(
          testMediaItem(
            id: 'movie_1',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'Trex Movie',
            serverId: 'conn-xt-1',
            serverName: 'Trex',
            libraryId: 'movies',
            libraryTitle: 'Trex — Movies',
          ),
        ),
        MediaSearchHit(
          testMediaItem(
            id: 'movie_2',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'Plex Movie',
            serverId: 'server_1',
            serverName: 'HOME PC',
            libraryId: '1',
            libraryTitle: 'Movies',
          ),
        ),
      ];
      final sections = groupSearchResults(hits, libraryLabel: labelOf);
      expect(sections.map((s) => s.label), ['Movies', 'Trex — Movies']);
      expect(sections[0].hits.map((h) => (h as MediaSearchHit).item.title), ['Plex Movie']);
      expect(sections[1].hits.map((h) => (h as MediaSearchHit).item.title), ['Trex Movie']);
    });

    test('people land in a final People section', () {
      final hits = [
        MediaSearchHit(
          testMediaItem(
            id: 'movie_1',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'Alpha Movie',
            serverId: 'server_1',
            serverName: 'HOME PC',
            libraryId: '1',
            libraryTitle: 'Movies',
          ),
        ),
        PersonSearchHit(
          MediaPerson(
            id: 'person_1',
            name: 'Alpha Person',
            backend: MediaBackend.plex,
            serverId: ServerId('server_1'),
          ),
        ),
      ];
      final sections = groupSearchResults(hits, libraryLabel: labelOf);
      expect(sections.map((s) => s.label), ['Movies', 'People']);
      expect(sections[1].hits, hasLength(1));
    });

    test('ranked order inside a section is kept', () {
      final hits = [
        MediaSearchHit(
          testMediaItem(
            id: 'movie_2',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'Second Movie',
            serverId: 'server_1',
            serverName: 'HOME PC',
            libraryId: '1',
            libraryTitle: 'Movies',
          ),
        ),
        MediaSearchHit(
          testMediaItem(
            id: 'movie_1',
            backend: MediaBackend.plex,
            kind: MediaKind.movie,
            title: 'First Movie',
            serverId: 'server_1',
            serverName: 'HOME PC',
            libraryId: '1',
            libraryTitle: 'Movies',
          ),
        ),
      ];
      final sections = groupSearchResults(hits, libraryLabel: labelOf);
      expect(sections, hasLength(1));
      expect(
        sections.single.hits.map((h) => (h as MediaSearchHit).item.title),
        ['Second Movie', 'First Movie'],
      );
    });
  });
}
