import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mesh_gradient/mesh_gradient.dart';

//TODO what happens when logged in on multiple devices

//TODO lock the creation of username and user_public docuemnt and only provide functions to change them

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return EmailPasswordForm(
      submitText: 'Login',
      onSubmit: (email, password) async {
        if(email.isEmpty || !email.contains("@")){
          return "Bitte gib eine gültige E-Mail-Adresse ein.";
        }
        if(password.isEmpty){
          return "Bitte gib ein Passwort ein.";
        }
        try {
          final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
        } on FirebaseAuthException catch (e) {
          print(e);
          if (e.code == 'user-not-found') {
            return 'Kein Benutzer mit dieser E-Mail-Adresse gefunden.';
          } else if (e.code == 'wrong-password' || e.code == 'invalid-credential') {
            return 'Falsche E-Mail-Adresse oder falsches Passwort.';
          } else if(e.code == 'invalid-email'){
            return 'Ungültige E-Mail-Adresse.';
          }
          return 'Anmeldung fehlgeschlagen. Bitte versuche es erneut.';
        }
        return null;
      },
    );
  }
}

class EmailPasswordForm extends StatefulWidget {
  const EmailPasswordForm({super.key, required this.submitText, required this.onSubmit, this.confirmPassword = false});

  final String submitText;
  final bool confirmPassword;
  final Future<String?> Function(String email, String password) onSubmit;

  @override
  State<EmailPasswordForm> createState() => _EmailPasswordFormState();
}

class _EmailPasswordFormState extends State<EmailPasswordForm> {
  bool passwordVisible = false;
  bool password2Visible = false;
  TextEditingController emailController = TextEditingController();
  TextEditingController passwordController = TextEditingController();
  TextEditingController password2Controller = TextEditingController();
  final FocusNode emailNode = FocusNode();
  final FocusNode passwordNode = FocusNode();
  final FocusNode password2Node = FocusNode();
  String? error;

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    password2Controller.dispose();
    emailNode.dispose();
    passwordNode.dispose();
    password2Node.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (widget.confirmPassword && passwordController.text != password2Controller.text) {
      setState(() {
        error = "Die Passwörter stimmen nicht überein.";
      });
      return;
    }
    error = await widget.onSubmit(emailController.text, passwordController.text);
    if (error == null) {
      TextInput.finishAutofillContext();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: AutofillGroup(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            focusNode: emailNode,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            onSubmitted: (_) => passwordNode.requestFocus(),
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.email_outlined),
              labelText: "Email",
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordController,
            focusNode: passwordNode,
            obscureText: !passwordVisible,
            textInputAction: widget.confirmPassword ? TextInputAction.next : TextInputAction.done,
            autofillHints: [widget.confirmPassword ? AutofillHints.newPassword : AutofillHints.password],
            onSubmitted: (_) => widget.confirmPassword ? password2Node.requestFocus() : _submit(),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.lock_outline),
              labelText: "Password",
              suffixIcon: ExcludeFocus(
                child: IconButton(
                  icon: Icon(passwordVisible ? Icons.visibility : Icons.visibility_off),
                  onPressed: () {
                    setState(() {
                      passwordVisible = !passwordVisible;
                    });
                  },
                ),
              ),
            ),
          ),
          if (widget.confirmPassword) ...[
            const SizedBox(height: 12),
            TextField(
              controller: password2Controller,
              focusNode: password2Node,
              obscureText: !password2Visible,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.lock_outline),
                labelText: "Confirm Password",
                suffixIcon: ExcludeFocus(
                  child: IconButton(
                    icon: Icon(password2Visible ? Icons.visibility : Icons.visibility_off),
                    onPressed: () {
                      setState(() {
                        password2Visible = !password2Visible;
                      });
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (error != null && error!.isNotEmpty) ...[
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.error.withOpacity(0.5),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Center(
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ] else
            const SizedBox(height: 44),
          FilledButton(
            onPressed: _submit,
            child: Text(widget.submitText),
          ),
        ],
      ),
    ),
    );
  }
}

Widget animatedBackground() => AnimatedMeshGradient(
  colors: const [
    Color.fromARGB(255, 93, 246, 170),
    Color.fromARGB(255, 76, 216, 90),
    Color.fromARGB(255, 192, 223, 98),
    Color.fromARGB(255, 255, 161, 68),
  ],
  options: AnimatedMeshGradientOptions(speed: 0.1),
);
