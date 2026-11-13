import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n/strings.g.dart';
import '../media/iptv_client.dart';
import '../utils/snackbar_helper.dart';

/// The un-hide notice (1.2.4, catalog memory, Matt's prune decision):
/// when a toggle un-hides categories whose rows were pruned from the
/// disk cache + search index, the shows do not come back until a
/// re-sync — say so AT THE MOMENT of the toggle, with a Refresh action
/// that runs the sync right there. Never a system notification (his
/// notifications are blocked and this is in-app state), and never
/// buried in Settings.
///
/// Silent when nothing was un-hidden, when the rows are still on disk
/// (they come back in the toggle's background re-derive), or when the
/// client is M3U (no catalog sync to run — M3U rows are never pruned).
/// The check awaits the toggle's re-derive first, so it reads the
/// fresh memos, not the stale ones. The Refresh action fires a forced
/// sync and reports whether it finished; a failed refresh says so
/// instead of going quiet.
Future<void> maybeShowUnhideRefreshNotice(
  BuildContext context, {
  required IptvClient client,
  required Set<String> unhiddenCategoryIds,
}) async {
  if (unhiddenCategoryIds.isEmpty) return;
  final needsRefresh = await client.unhiddenCategoriesNeedRefresh(unhiddenCategoryIds);
  if (!context.mounted) return;
  if (!needsRefresh) return;
  showSnackBar(
    context,
    t.iptvCategories.unhiddenNeedsRefresh,
    duration: const Duration(seconds: 8),
    actionLabel: t.iptvCategories.unhiddenRefresh,
    onAction: () {
      unawaited(
        client.syncSearchIndex(force: true).then((result) {
          if (!context.mounted) return;
          if (result.hasFailure) {
            showErrorSnackBar(context, t.iptvCategories.unhiddenRefreshFailed);
          } else {
            showSnackBar(context, t.iptvCategories.unhiddenRefreshDone);
          }
        }).catchError((Object e) {
          if (!context.mounted) return;
          showErrorSnackBar(context, t.iptvCategories.unhiddenRefreshFailed);
        }),
      );
    },
  );
}
