import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Which variant of the shared credential form to render.
enum AuthFormMode {
  /// Email + password. Signing in to an existing account.
  login,

  /// Email + password + confirmation, with a live password-strength checklist.
  /// Used both for creating an account and for linking email/password onto an
  /// existing anonymous account.
  register,

  /// Password only, against a known email. Firebase requires a recent login
  /// before sensitive operations; the email is shown read-only so password
  /// managers can still pair the credential.
  reauth,
}

/// The one and only email/password form in the app.
///
/// Every credential entry point renders this widget:
///   * the login step of `WelcomePage` (onboarding) → [AuthFormMode.login]
///   * the "add email & password" upgrade sheet on the profile page →
///     [AuthFormMode.register]
///   * [AuthFormMode.reauth] has no caller yet. It exists for the operations
///     Firebase gates behind a recent login — changing email or password,
///     deleting an account client-side — so that flow doesn't get hand-rolled
///     again when it's needed.
///
/// Do not hand-roll another `TextField` pair somewhere else — add a mode here
/// instead. Keeping this in one place is what keeps the autofill behaviour
/// correct, and autofill is easy to break in ways that fail silently:
///
///   * All fields live in one [AutofillGroup] so the password manager can pair
///     the identifier with the secret.
///   * The email field advertises both [AutofillHints.username] and
///     [AutofillHints.email] — managers key saved credentials off `username`.
///   * The password field always uses [AutofillHints.password], never
///     `newPassword`. Android's autofill service (and most third-party
///     managers) do not offer fill suggestions for `AUTOFILL_HINT_NEW_PASSWORD`,
///     so a register form hinted that way silently shows nothing while the
///     email field above it fills fine.
///   * The confirmation field carries no hints at all. Two hinted password
///     fields in one group make the manager ambiguous about which to save.
///   * In [AuthFormMode.reauth] the email is a read-only field rather than
///     plain text: a disabled or absent username field leaves the manager with
///     nothing to match the saved password against.
///   * [TextInput.finishAutofillContext] fires on success *before* [onSuccess],
///     so the save-password prompt is requested while the route is still
///     mounted. Popping first swallows the prompt.
class AuthForm extends StatefulWidget {
  const AuthForm({
    super.key,
    required this.mode,
    required this.submitText,
    required this.onSubmit,
    this.onSuccess,
    this.leading,
    this.title,
    this.subtitle,
    this.initialEmail,
    this.belowFields,
    this.belowButton,
    this.padding = const EdgeInsets.symmetric(horizontal: 32),
    this.reserveErrorSpace = false,
    this.autofocus = false,
  });

  final AuthFormMode mode;

  /// Label of the submit button.
  final String submitText;

  /// Performs the actual auth call. Returns `null` on success, or a
  /// user-facing error message to display above the button.
  final Future<String?> Function(String email, String password) onSubmit;

  /// Invoked after a successful [onSubmit], once the autofill context has been
  /// finished. Use this to pop a sheet or navigate onward.
  final VoidCallback? onSuccess;

  /// Optional icon/graphic above the title.
  final Widget? leading;

  final String? title;
  final String? subtitle;

  /// Prefills the email field. Required for [AuthFormMode.reauth], where the
  /// field is read-only.
  final String? initialEmail;

  /// Slot between the fields and the submit button — e.g. "Forgot password?".
  final Widget? belowFields;

  /// Slot underneath the submit button — e.g. a Cancel action.
  final Widget? belowButton;

  final EdgeInsetsGeometry padding;

  /// Keeps a fixed gap where the error message would appear, so the submit
  /// button doesn't jump when an error shows up. Useful on full-screen layouts,
  /// unwanted in a bottom sheet that sizes itself to its content.
  final bool reserveErrorSpace;

  /// Focuses the first editable field on open.
  final bool autofocus;

  @override
  State<AuthForm> createState() => _AuthFormState();
}

class _AuthFormState extends State<AuthForm> {
  late final TextEditingController _emailCtrl;
  final _passCtrl = TextEditingController();
  final _pass2Ctrl = TextEditingController();

  final _emailNode = FocusNode();
  final _passNode = FocusNode();
  final _pass2Node = FocusNode();

  bool _passVisible = false;
  bool _pass2Visible = false;
  bool _loading = false;
  String? _error;

  bool get _isRegister => widget.mode == AuthFormMode.register;

  bool get _isReauth => widget.mode == AuthFormMode.reauth;

  @override
  void initState() {
    super.initState();
    _emailCtrl = TextEditingController(text: widget.initialEmail ?? '');
    if (_isRegister) {
      // Register mode validates live, so the button enables as criteria are met.
      for (final c in [_emailCtrl, _passCtrl, _pass2Ctrl]) {
        c.addListener(_rebuild);
      }
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _pass2Ctrl.dispose();
    _emailNode.dispose();
    _passNode.dispose();
    _pass2Node.dispose();
    super.dispose();
  }

  // ── validation (register mode only) ────────────────────────────────────────

  List<(String, bool)> get _passwordChecks {
    final p = _passCtrl.text;
    return [
      ('At least 8 characters', p.length >= 8),
      ('An uppercase letter', p.contains(RegExp(r'[A-Z]'))),
      ('A lowercase letter', p.contains(RegExp(r'[a-z]'))),
      ('A number', p.contains(RegExp(r'[0-9]'))),
    ];
  }

  bool get _emailValid {
    final email = _emailCtrl.text.trim();
    return email.contains('@') && email.contains('.');
  }

  bool get _passwordsMatch => _passCtrl.text == _pass2Ctrl.text;

  /// Outside register mode the server decides; the button stays enabled so the
  /// user gets a real error message instead of a dead button.
  bool get _canSubmit {
    if (_loading) return false;
    if (!_isRegister) return true;
    return _emailValid && _passwordChecks.every((c) => c.$2) && _passwordsMatch;
  }

  // ── submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    final err = await widget.onSubmit(_emailCtrl.text.trim(), _passCtrl.text);

    if (err == null) {
      // Ask the platform to offer saving the credential while this route is
      // still mounted, then hand control back to the caller.
      TextInput.finishAutofillContext();
      widget.onSuccess?.call();
      if (mounted) setState(() => _loading = false);
      return;
    }

    if (mounted) {
      setState(() {
        _loading = false;
        _error = err;
      });
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: widget.padding,
      child: AutofillGroup(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.leading != null) ...[
              widget.leading!,
              const SizedBox(height: 12),
            ],
            if (widget.title != null) ...[
              Text(widget.title!, textAlign: TextAlign.center, style: theme.textTheme.titleLarge),
              const SizedBox(height: 4),
            ],
            if (widget.subtitle != null) ...[
              Text(widget.subtitle!, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
            ] else
              const SizedBox(height: 10),

            // ── email ───────────────────────────────────────────────────────
            // Read-only rather than omitted in reauth mode: the password
            // manager needs a username field present to match on.
            TextField(
              controller: _emailCtrl,
              focusNode: _emailNode,
              enabled: !_loading,
              readOnly: _isReauth,
              canRequestFocus: !_isReauth,
              autofocus: widget.autofocus && !_isReauth,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              autofillHints: const [AutofillHints.username, AutofillHints.email],
              onSubmitted: (_) => _passNode.requestFocus(),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.email_outlined),
                hintText: 'Email',
              ),
            ),
            const SizedBox(height: 12),

            // ── password ────────────────────────────────────────────────────
            TextField(
              controller: _passCtrl,
              focusNode: _passNode,
              enabled: !_loading,
              obscureText: !_passVisible,
              autofocus: widget.autofocus && _isReauth,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: _isRegister ? TextInputAction.next : TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              onSubmitted: (_) => _isRegister ? _pass2Node.requestFocus() : _submit(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.lock_outline),
                hintText: 'Password',
                suffixIcon: ExcludeFocus(
                  child: IconButton(
                    icon: Icon(_passVisible ? Icons.visibility : Icons.visibility_off),
                    tooltip: _passVisible ? 'Hide password' : 'Show password',
                    onPressed: () => setState(() => _passVisible = !_passVisible),
                  ),
                ),
              ),
            ),

            if (_isRegister) ...[
              const SizedBox(height: 12),
              ..._passwordChecks.map((c) => _criterionRow(c.$1, c.$2)),
              const SizedBox(height: 12),

              // ── confirm password ──────────────────────────────────────────
              // Deliberately unhinted: a second hinted password field makes the
              // autofill service ambiguous about which value to save.
              TextField(
                controller: _pass2Ctrl,
                focusNode: _pass2Node,
                enabled: !_loading,
                obscureText: !_pass2Visible,
                autocorrect: false,
                enableSuggestions: false,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.lock_outline),
                  hintText: 'Confirm password',
                  suffixIcon: ExcludeFocus(
                    child: IconButton(
                      icon: Icon(_pass2Visible ? Icons.visibility : Icons.visibility_off),
                      tooltip: _pass2Visible ? 'Hide password' : 'Show password',
                      onPressed: () => setState(() => _pass2Visible = !_pass2Visible),
                    ),
                  ),
                ),
              ),
              if (_pass2Ctrl.text.isNotEmpty && !_passwordsMatch)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    "Passwords don't match.",
                    style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 10),
            ],

            if (widget.belowFields != null) widget.belowFields!,

            // ── error ───────────────────────────────────────────────────────
            if (_error != null && _error!.isNotEmpty) ...[
              const SizedBox(height: 12),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Center(
                    child: Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ] else
              SizedBox(height: widget.reserveErrorSpace ? 44 : 16),

            FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: _loading
                  ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(widget.submitText),
            ),

            if (widget.belowButton != null) widget.belowButton!,
          ],
        ),
      ),
    );
  }

  Widget _criterionRow(String label, bool met) {
    final scheme = Theme.of(context).colorScheme;
    const metColor = Color(0xFF1B9E3E);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            met ? Icons.check_circle : Icons.circle_outlined,
            size: 18,
            color: met ? metColor : scheme.outline,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: met ? metColor : scheme.onSurfaceVariant,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
