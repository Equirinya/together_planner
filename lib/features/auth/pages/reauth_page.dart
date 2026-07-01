import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'package:couple_planner/features/auth/pages/login_page.dart' show animatedBackground;

/// Asks the signed-in user to confirm their password. Firebase requires a
/// recent login before sensitive operations (changing email/password, deleting
/// the account); call this first and only proceed when it returns true.
///
/// Returns true on successful reauthentication, false if cancelled/failed.
Future<bool> reauthenticate(BuildContext context) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null || user.email == null) return false;
  final ok = await Navigator.of(context).push<bool>(
    MaterialPageRoute(fullscreenDialog: true, builder: (_) => const ReauthPage()),
  );
  return ok ?? false;
}

class ReauthPage extends StatefulWidget {
  const ReauthPage({super.key});

  @override
  State<ReauthPage> createState() => _ReauthPageState();
}

class _ReauthPageState extends State<ReauthPage> {
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;
  bool _loading = false;
  String? _error;

  String get _email => FirebaseAuth.instance.currentUser?.email ?? '';

  @override
  void dispose() {
    _passwordCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || user.email == null) {
      if (mounted) Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cred = EmailAuthProvider.credential(email: user.email!, password: _passwordCtrl.text);
      await user.reauthenticateWithCredential(cred);
      if (mounted) Navigator.of(context).pop(true);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        switch (e.code) {
          case 'wrong-password':
          case 'invalid-credential':
            _error = 'Incorrect password.';
            break;
          case 'too-many-requests':
            _error = 'Too many attempts. Please try again later.';
            break;
          case 'network-request-failed':
            _error = "You're not connected to the internet.";
            break;
          default:
            _error = 'Could not confirm your identity. Please try again.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  Future<void> _forgotPassword() async {
    if (_email.isEmpty) return;
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: _email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Password reset email sent to $_email.')),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not send the reset email.')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return Scaffold(
      body: Stack(
        children: [
          SizedBox(width: size.width, height: size.height, child: animatedBackground()),
          Container(width: size.width, height: size.height, color: Colors.black.withAlpha(60)),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Icon(Icons.lock_outline, size: 36),
                        const SizedBox(height: 12),
                        Text("Confirm it's you", textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 8),
                        Text(
                          'For your security, please enter the password for $_email to continue.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 20),
                        TextField(
                          controller: _passwordCtrl,
                          enabled: !_loading,
                          obscureText: _obscure,
                          autofocus: true,
                          onSubmitted: (_) => _confirm(),
                          decoration: InputDecoration(
                            labelText: 'Password',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                              onPressed: () => setState(() => _obscure = !_obscure),
                            ),
                            errorText: _error,
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(onPressed: _loading ? null : _forgotPassword, child: const Text('Forgot password?')),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: _loading ? null : _confirm,
                          child: _loading
                              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Text('Confirm'),
                        ),
                        TextButton(
                          onPressed: _loading ? null : () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
