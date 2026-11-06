import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'dialogs.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) {
      final latestVersion = updateInfo['latestVersion'] as String;
      final releaseUrl = updateInfo['releaseUrl'] as String;
      final apkAssetUrl = updateInfo['apkAssetUrl'] as String?;
      final releaseNotes = (updateInfo['releaseNotes'] as String? ?? '').trim();

      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.update.versionAvailable(version: latestVersion),
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                t.update.currentVersion(version: updateInfo['currentVersion']),
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              if (releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  t.update.releaseNotes,
                  style: Theme.of(dialogContext).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: SingleChildScrollView(
                    child: Text(
                      releaseNotes,
                      style: Theme.of(dialogContext).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                apkAssetUrl != null ? t.update.installApkHint : t.update.noApkAttached,
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          DialogActionButton(onPressed: () => Navigator.pop(dialogContext), label: dismissLabel),
          if (showSkipVersion)
            DialogActionButton(
              onPressed: () async {
                await UpdateService.skipVersion(latestVersion);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.update.skipVersion,
            ),
          DialogActionButton(
            onPressed: () async {
              final url = Uri.parse(releaseUrl);
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            label: t.update.viewRelease,
          ),
          if (apkAssetUrl != null)
            DialogActionButton(
              onPressed: () async {
                final url = Uri.parse(apkAssetUrl);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.update.downloadApk,
              isPrimary: true,
            ),
        ],
      );
    },
  );
}
