import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../profiles/active_profile_binder.dart';
import '../../profiles/active_profile_provider.dart';
import '../../profiles/profile.dart';
import '../../profiles/profile_connection.dart';
import '../profile/profile_switch_screen.dart';
import 'connection_persistence.dart';

/// Shared persistence path for the IPTV add screens (M3U + Xtream Codes):
/// provision the optional first-run profile, connection, and ownership row,
/// then bind and pop only after durable success.
///
/// Mirrors the Jellyfin `_persistAndExit` flow in
/// `add_jellyfin_screen.dart`, minus the MediaBrowser auth pieces. IPTV
/// connections carry no per-profile token, so [userIdentifier] is the
/// Xtream username (or an empty string for M3U) and the token stays null.
///
/// Returns true when the connection was persisted and this route popped;
/// false when the flow bailed out before persisting (e.g. no profile to
/// bind to) so the caller can surface an error and keep the form visible.
Future<bool> persistAndExitIptvConnection({
  required BuildContext context,
  required Connection connection,
  required Profile? targetProfile,
  required String userIdentifier,
}) async {
  final activeProvider = context.read<ActiveProfileProvider>();
  await activeProvider.initialize();
  if (!context.mounted) return false;
  var boundProfile = targetProfile ?? activeProvider.active;
  if (targetProfile == null && activeProvider.active == null && activeProvider.profiles.isNotEmpty) {
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push<bool>(MaterialPageRoute(builder: (_) => const ProfileSwitchScreen(requireSelection: true)));
    if (!context.mounted) return false;
    boundProfile = activeProvider.active;
    if (boundProfile == null) return false;
  }

  Profile? firstRunProfile;
  if (targetProfile == null && boundProfile == null && activeProvider.profiles.isEmpty) {
    final now = DateTime.now();
    firstRunProfile = Profile.local(
      id: 'local-${const Uuid().v4()}',
      displayName: connection.displayName,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
    );
    boundProfile = firstRunProfile;
  }

  final bindProfile = boundProfile;
  if (bindProfile == null) return false;

  await persistAndBindConnection(
    context: context,
    connection: connection,
    bindToProfile: ProfileConnection(
      profileId: bindProfile.id,
      connectionId: connection.id,
      userToken: null,
      userIdentifier: userIdentifier,
      tokenAcquiredAt: DateTime.now(),
    ),
    firstRunProfile: firstRunProfile,
  );

  final boundToActive = bindProfile.id == activeProvider.activeId;
  if (!context.mounted) return false;
  if (boundToActive) {
    await context.read<ActiveProfileBinder>().rebindIfActive(bindProfile.id);
  }

  if (!context.mounted) return false;
  Navigator.of(context).pop(true);
  return true;
}
