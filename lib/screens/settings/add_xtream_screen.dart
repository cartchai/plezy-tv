import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:uuid/uuid.dart';

import '../../connection/connection.dart';
import '../../exceptions/media_server_exceptions.dart';
import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../mixins/controller_disposer_mixin.dart';
import '../../profiles/profile.dart';
import '../../services/iptv/xtream_api.dart';
import '../../services/settings_service.dart';
import '../../utils/app_logger.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/focused_scroll_scaffold.dart';
import '../../widgets/loading_indicator_box.dart';
import 'async_form_state_mixin.dart';
import 'iptv_connection_persistence.dart';

/// Add an Xtream Codes account as a connection: the user gives it a NAME
/// (which becomes the library title) plus the server URL, username, and
/// password. The credentials are verified with a `player_api.php` auth
/// probe before anything is persisted; the connection is then stored via
/// [persistAndBindConnection] and bound to the target (or active) profile.
///
/// The password is never logged and never appears in any error message:
/// Xtream errors can embed the request URI, which carries the credentials
/// in the query string, so all failures map to fixed user-facing strings.
class AddXtreamScreen extends StatefulWidget {
  /// When set, the new connection is bound to this profile. When null,
  /// falls back to the currently active profile (typical for the global
  /// Connections screen entry point).
  final Profile? targetProfile;

  const AddXtreamScreen({super.key, this.targetProfile});

  @override
  State<AddXtreamScreen> createState() => _AddXtreamScreenState();
}

class _AddXtreamScreenState extends State<AddXtreamScreen> with AsyncFormStateMixin, ControllerDisposerMixin {
  late final _nameController = createTextEditingController();
  late final _urlController = createTextEditingController();
  late final _usernameController = createTextEditingController();
  late final _passwordController = createTextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'AddXtream:Name');
  final _urlFocus = FocusNode(debugLabel: 'AddXtream:Url');
  final _usernameFocus = FocusNode(debugLabel: 'AddXtream:Username');
  final _passwordFocus = FocusNode(debugLabel: 'AddXtream:Password');
  final _signInFocus = FocusNode(debugLabel: 'AddXtream:SignIn');
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nameFocus.dispose();
    _urlFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _signInFocus.dispose();
    super.dispose();
  }

  /// Auth probe: `player_api.php` with no action. A `user_info` object
  /// means the login works; null means the server rejected it.
  ///
  /// The probe sends the configured Xtream User-Agent (build #20): a panel
  /// that 403s the bare Dart UA would fail sign-in here even though the
  /// app itself would work, so the probe must present the same signature
  /// the app will use.
  /// The configured Xtream User-Agent for the sign-in probe (build #20).
  /// Falls back to VLC when Settings is not initialized yet.
  static String _configuredUserAgent() {
    final settings = SettingsService.instanceOrNull;
    if (settings == null) return XtreamUserAgent.vlc;
    return XtreamUserAgent.resolve(
      settings.read(SettingsService.iptvXtreamUserAgent),
      settings.read(SettingsService.iptvXtreamUserAgentCustom),
    );
  }

  Future<bool> _probe(String serverUrl, String username, String password) async {
    final api = XtreamApi(
      serverUrl: serverUrl,
      username: username,
      password: password,
      userAgent: _configuredUserAgent(),
    );
    try {
      final info = await api.getUserInfo();
      return info != null;
    } finally {
      api.close();
    }
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final name = _nameController.text.trim();
    final serverUrl = _urlController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    await runAsync<void>(
      () async {
        final authed = await _probe(serverUrl, username, password);
        if (!mounted) return;
        if (!authed) {
          setErrorText(t.addServer.invalidCredentials);
          return;
        }
        final connection = XtreamConnection(
          id: const Uuid().v4(),
          name: name,
          serverUrl: serverUrl,
          username: username,
          password: password,
          createdAt: DateTime.now(),
        );
        final ok = await persistAndExitIptvConnection(
          context: context,
          connection: connection,
          targetProfile: widget.targetProfile,
          userIdentifier: username,
        );
        if (!ok && mounted) setErrorText(t.messages.noProfilesAvailable);
      },
      errorMapper: (e) {
        // Fixed strings only: Xtream errors may embed the request URI,
        // which carries the username and password in the query string.
        if (e is MediaServerAuthException) return t.addServer.invalidCredentials;
        appLogger.e('Add Xtream failed', error: e.runtimeType);
        return t.addServer.xtreamProbeFailed;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FocusedScrollScaffold(
      title: Text(t.addServer.addXtreamTitle),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.all(16),
          sliver: SliverToBoxAdapter(
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: .stretch,
                children: [
                  FocusableTextFormField(
                    controller: _nameController,
                    focusNode: _nameFocus,
                    autofocus: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _urlFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.libraryName,
                      helperText: t.addServer.libraryNameHelper,
                      prefixIcon: const AppIcon(Symbols.label_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _urlController,
                    focusNode: _urlFocus,
                    tvTextInputPresentation: TvTextInputPresentation.platform,
                    keyboardType: TextInputType.url,
                    minLines: 1,
                    maxLines: 4,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _usernameFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.serverUrl,
                      prefixIcon: const AppIcon(Symbols.link_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _usernameController,
                    focusNode: _usernameFocus,
                    autocorrect: false,
                    enableSuggestions: false,
                    enabled: !busy,
                    textInputAction: TextInputAction.next,
                    onFieldSubmitted: busy ? null : (_) => _passwordFocus.requestFocus(),
                    decoration: InputDecoration(
                      labelText: t.addServer.username,
                      prefixIcon: const AppIcon(Symbols.person_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 12),
                  FocusableTextFormField(
                    controller: _passwordController,
                    focusNode: _passwordFocus,
                    obscureText: true,
                    enabled: !busy,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: busy ? null : (_) => _signIn(),
                    decoration: InputDecoration(
                      labelText: t.addServer.password,
                      prefixIcon: const AppIcon(Symbols.lock_rounded, fill: 1),
                    ),
                    validator: (v) => v == null || v.isEmpty ? t.addServer.required : null,
                  ),
                  const SizedBox(height: 16),
                  FocusableButton(
                    focusNode: _signInFocus,
                    useBackgroundFocus: true,
                    onPressed: busy ? null : _signIn,
                    child: FilledButton.icon(
                      onPressed: busy ? null : _signIn,
                      icon: busy ? const LoadingIndicatorBox() : const AppIcon(Symbols.login_rounded, fill: 1),
                      label: Text(t.addServer.signIn),
                    ),
                  ),
                  ...buildInlineError(theme),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
