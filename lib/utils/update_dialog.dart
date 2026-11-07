import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../services/apk_installer.dart';
import '../services/apk_update_downloader.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'dialogs.dart';

/// Shows the update-available dialog (build #6, reworked build #10).
///
/// Build #10: on Android the APK is downloaded IN the app instead of
/// opening a browser — Android TV / Google TV has no browser download flow.
/// The dialog walks info → downloading (progress bar + bytes, Cancel) →
/// downloaded (verified against the release asset size) → Install, which
/// opens the system install prompt. A failed, cancelled or truncated
/// download shows a clear message with a retry. Dismissing the dialog
/// mid-download cancels it. On other platforms (and when the release has
/// no APK asset) the old browser flow stays: "Download APK" opens the
/// asset URL in the browser.
Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) => _UpdateAvailableDialog(
      updateInfo: updateInfo,
      title: title,
      dismissLabel: dismissLabel,
      showSkipVersion: showSkipVersion,
    ),
  );
}

enum _DownloadPhase { info, downloading, downloaded, failed }

class _UpdateAvailableDialog extends StatefulWidget {
  const _UpdateAvailableDialog({
    required this.updateInfo,
    required this.title,
    required this.dismissLabel,
    required this.showSkipVersion,
  });

  final Map<String, dynamic> updateInfo;
  final String title;
  final String dismissLabel;
  final bool showSkipVersion;

  @override
  State<_UpdateAvailableDialog> createState() => _UpdateAvailableDialogState();
}

class _UpdateAvailableDialogState extends State<_UpdateAvailableDialog> {
  _DownloadPhase _phase = _DownloadPhase.info;
  ApkDownloadController? _controller;
  File? _downloadedFile;
  int _received = 0;
  int _total = -1;
  String? _errorMessage;
  String? _installError;
  bool _installing = false;

  String get _latestVersion => widget.updateInfo['latestVersion'] as String;
  String get _releaseUrl => widget.updateInfo['releaseUrl'] as String;
  String? get _apkAssetUrl => widget.updateInfo['apkAssetUrl'] as String?;
  int? get _expectedSize => widget.updateInfo['apkAssetSize'] as int?;
  String get _releaseNotes => (widget.updateInfo['releaseNotes'] as String? ?? '').trim();

  bool get _inAppDownload =>
      defaultTargetPlatform == TargetPlatform.android && _apkAssetUrl != null;

  @override
  void dispose() {
    // Dismissing mid-download cancels it (the partial file is deleted by
    // the downloader).
    _controller?.cancel();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final apkAssetUrl = _apkAssetUrl;
    if (apkAssetUrl == null) return;
    final controller = ApkDownloadController();
    setState(() {
      _phase = _DownloadPhase.downloading;
      _controller = controller;
      _received = 0;
      _total = _expectedSize ?? -1;
      _errorMessage = null;
      _installError = null;
    });
    try {
      final cacheDir = await getTemporaryDirectory();
      final file = File('${cacheDir.path}/pleztv-update.apk');
      final downloaded = await ApkUpdateDownloader.download(
        url: Uri.parse(apkAssetUrl),
        expectedSizeBytes: _expectedSize,
        destination: file,
        controller: controller,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.downloaded;
        _downloadedFile = downloaded;
        _controller = null;
      });
    } on ApkDownloadCancelled {
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.failed;
        _errorMessage = t.update.downloadCancelled;
        _controller = null;
      });
    } on ApkDownloadSizeMismatch {
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.failed;
        _errorMessage = t.update.downloadSizeMismatch;
        _controller = null;
      });
    } on ApkDownloadFailed {
      if (!mounted) return;
      setState(() {
        _phase = _DownloadPhase.failed;
        _errorMessage = t.update.downloadFailed;
        _controller = null;
      });
    }
  }

  Future<void> _install() async {
    final file = _downloadedFile;
    if (file == null || _installing) return;
    setState(() {
      _installing = true;
      _installError = null;
    });
    try {
      final opened = await ApkInstaller.installApk(file);
      if (!mounted) return;
      if (opened) {
        // The system installer takes over from here.
        Navigator.pop(context);
      } else {
        setState(() {
          _installing = false;
          _installError = t.update.installUnavailable;
        });
      }
    } on ApkInstallException {
      if (!mounted) return;
      setState(() {
        _installing = false;
        _installError = t.update.installUnavailable;
      });
    }
  }

  Future<void> _openReleasePage() async {
    final url = Uri.parse(_releaseUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _openApkInBrowser() async {
    final apkAssetUrl = _apkAssetUrl;
    if (apkAssetUrl == null) return;
    final url = Uri.parse(apkAssetUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              t.update.versionAvailable(version: _latestVersion),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              t.update.currentVersion(version: widget.updateInfo['currentVersion']),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_releaseNotes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                t.update.releaseNotes,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(
                    _releaseNotes,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (_phase == _DownloadPhase.downloading) ...[
              Text(t.update.downloading, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: _total > 0 ? _received / _total : null,
              ),
              const SizedBox(height: 8),
              Text(
                t.update.downloadProgress(
                  downloaded: formatDownloadBytes(_received),
                  total: _total > 0 ? formatDownloadBytes(_total) : '…',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ] else if (_phase == _DownloadPhase.downloaded) ...[
              Text(t.update.downloadComplete, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 4),
              Text(t.update.installUpdateHint, style: Theme.of(context).textTheme.bodySmall),
              if (_installError != null) ...[
                const SizedBox(height: 8),
                Text(_installError!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ] else if (_phase == _DownloadPhase.failed) ...[
              Text(_errorMessage ?? t.update.downloadFailed, style: Theme.of(context).textTheme.bodySmall),
            ] else
              Text(
                _apkAssetUrl != null
                    ? (_inAppDownload ? t.update.inAppDownloadHint : t.update.installApkHint)
                    : t.update.noApkAttached,
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: [
        DialogActionButton(onPressed: () => Navigator.pop(context), label: widget.dismissLabel),
        if (widget.showSkipVersion)
          DialogActionButton(
            onPressed: () async {
              await UpdateService.skipVersion(_latestVersion);
              if (context.mounted) Navigator.pop(context);
            },
            label: t.update.skipVersion,
          ),
        DialogActionButton(onPressed: _openReleasePage, label: t.update.viewRelease),
        if (_phase == _DownloadPhase.downloading)
          DialogActionButton(
            onPressed: () => _controller?.cancel(),
            label: t.common.cancel,
          )
        else if (_phase == _DownloadPhase.downloaded)
          DialogActionButton(
            onPressed: _installing ? null : _install,
            label: t.update.install,
            isPrimary: true,
            // D-pad / TV: the Install button takes focus when it appears.
            autofocus: true,
          )
        else if (_phase == _DownloadPhase.failed)
          DialogActionButton(
            onPressed: _inAppDownload ? _startDownload : _openApkInBrowser,
            label: _inAppDownload ? t.update.download : t.update.downloadApk,
            isPrimary: true,
          )
        else if (_apkAssetUrl != null)
          DialogActionButton(
            onPressed: _inAppDownload ? _startDownload : _openApkInBrowser,
            label: _inAppDownload ? t.update.download : t.update.downloadApk,
            isPrimary: true,
          ),
      ],
    );
  }
}
