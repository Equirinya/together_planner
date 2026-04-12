import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:mesh_gradient/mesh_gradient.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';
import '../main.dart';

//TODO what happens when logged in on multiple devices

//TODO lock the creation of username and user_public docuemnt and only provide functions to change them


class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onFinished, required this.infoText});

  final VoidCallback onFinished;
  final String infoText;

  @override
  Widget build(BuildContext context) {
    var size = MediaQuery.of(context).size;
    double smallerSide = min(size.width, size.height);
    return OnboardingFlowPage(
      onFinished: onFinished,
      loginFlowText: "Einloggen",
      signUpFlowText: "Registrieren",
      startInfoText: infoText,
      logo: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: smallerSide / 4,
            width: smallerSide / 4,
            child: ColorFiltered(
                colorFilter: ColorFilter.mode(Colors.black, BlendMode.srcIn), //Theme.of(context).colorScheme.primary
                child: Image.asset("assets/icon/icon_transparent.png")),
          ),
          Text("Welcome to Together Planner!", style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.black)),
        ],
      ),
    );
  }
}

class OnboardingFlowPage extends StatefulWidget {
  const OnboardingFlowPage(
      {super.key,
      required this.onFinished,
      required this.loginFlowText,
      required this.signUpFlowText,
      this.extraFlowButtons = const [],
      required this.logo,
      this.startInfoText = ""});

  final VoidCallback onFinished;
  final String? loginFlowText; //if null no login Button is shown
  final String? signUpFlowText; //if null no signUpButton is shown
  final List<Widget> extraFlowButtons;
  final Widget logo;
  final String startInfoText;

  @override
  State<OnboardingFlowPage> createState() => _OnboardingFlowPageState();
}

class _OnboardingFlowPageState extends State<OnboardingFlowPage> {
  int? flow; //null: flow selection, 0: login, 1: signup
  int stage =
      0; //login: 1: email/password, signIn: 0: email/password, 1: username
  String username = "";
  int usernameError = 0;
  bool loading = false;
  StreamSubscription<User?>? streamSub;

  void close() {
    Navigator.of(context).pop();
    widget.onFinished();
    // Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => HomePage()));
  }

  void signIn() async {
    var db = FirebaseFirestore.instance;
    var auth = FirebaseAuth.instance;
    var prefs = await SharedPreferences.getInstance();
    if (username.length < 3) {
      setState(() {
        usernameError = 2;
      });
    } else {
      setState(() {
        usernameError = 0;
        loading = true;
      });
      if (false)//((numberOfNameAppearances.count ?? 0) > 0)
      {
        setState(() {
          usernameError = 1;
        });
      } else {

        var currentUser = auth.currentUser;
        int retries = 0;
        const maxRetries = 100;
        while (currentUser == null && retries < maxRetries) {
          await Future.delayed(const Duration(milliseconds: 500));
          currentUser = auth.currentUser;
          retries++;
        }
        if (currentUser == null) {
          print("User creation timed out.");
          setState(() {
            loading = false;
          });
          return;
        }

        final userDoc = <String, dynamic>{
          'username': username,
          'createdAt': FieldValue.serverTimestamp(),
          'lastLogin': FieldValue.serverTimestamp(),
        };
        final userNameDoc = <String, dynamic>{
          'uid': auth.currentUser!.uid,
          'createdAt': FieldValue.serverTimestamp(),
        };
        final userPublicDoc = <String, dynamic>{
          'username': username,
          'updatedAt': FieldValue.serverTimestamp(),
        };

        print("usernameDoc");
        print(userNameDoc);


        db.collection('users').doc(auth.currentUser!.uid).set(userDoc);
        db.collection('usernames').doc(username).set(userNameDoc);
        db.collection('users_public').doc(auth.currentUser!.uid).set(userPublicDoc);

        setState(() {
          loading = false;
        });

        prefs.setBool("userCreated", true);
        stage == 2;
        close();
      }
    }
  }

  void back() async {
    if(stage>0){
      try{
        await FirebaseAuth.instance.currentUser?.delete();
        await FirebaseAuth.instance.signOut();
        await Future.delayed(const Duration(milliseconds: 300));
      } catch(e){
        print(e);
      }
    }
    if (stage == 0)
      flow = null;
    else
      stage -= 1;

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    Size size = MediaQuery.of(context).size;
    var isPortrait = MediaQuery.of(context).orientation == Orientation.portrait;
    double smallerDim = min(size.width, size.height);

    List<(String, List<Widget>)> loginPages = [
      (
        "Willkommen zurück!\nMelde dich mit deinem Quiz Studio Account an.",
        [
          StatefulBuilder(builder: (context, setState) {
            if (Firebase.apps.isEmpty) {
              loading = true;
              Firebase.initializeApp(
                options: DefaultFirebaseOptions.currentPlatform,
              ).then((value) => setState(() => loading = false));
            } else {
              streamSub?.cancel();
              streamSub = FirebaseAuth.instance.authStateChanges().listen((User? user) async {
                if (FirebaseAuth.instance.currentUser != null) {
                  close();
                  streamSub?.cancel();
                  var prefs = await SharedPreferences.getInstance();
                  prefs.setBool("userCreated", true);
                }
              });
            }
            if (loading) return const CupertinoActivityIndicator();
            return LoginPage();
          }),
        ]
      )
    ];

    List<(String, List<Widget>)> signInPages = [
      (
        "",
        [
          StatefulBuilder(builder: (context, setRegisterState) {
            if (Firebase.apps.isEmpty) {
              loading = true;
              Firebase.initializeApp(
                options: DefaultFirebaseOptions.currentPlatform,
              ).then((value) => setRegisterState(() => loading = false));
            } else {
              streamSub?.cancel();
              streamSub = FirebaseAuth.instance.authStateChanges().listen((User? user) async {
                if (FirebaseAuth.instance.currentUser != null) {
                  if(kDebugMode) {
                    print("User logged in: ${FirebaseAuth.instance.currentUser}");
                  }
                  setState(() => stage = 1);
                  streamSub?.cancel();
                }
              });
            }
            if (loading) return const CupertinoActivityIndicator();
            return SignUpPage();
          }),
        ]
      ),
      (
        "Wähle deinen Benutzernamen",
        [
          const SizedBox(
            height: 32,
          ),
          Icon(
            Icons.badge_outlined,
            size: 32,
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text("Choose your username",
                style: Theme.of(context).textTheme.headlineMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: TextField(
              enabled: !loading,
              onChanged: (str) {
                if (str.length > 127) {
                  username = str.substring(0, 127);
                } else {
                  username = str;
                }
                setState(() {
                  usernameError = 0;
                });
              },
              decoration: const InputDecoration(
                border: UnderlineInputBorder(),
                labelText: 'Username',
              ),
            ),
          ),
          Visibility(
            visible: usernameError == 1,
            maintainSize: false,
            child: Text(
              "Dein Name wird schon verwendet, bitte wähle einen anderen!",
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: Colors.red),
            ),
          ),
          Visibility(
            visible: usernameError == 2,
            maintainSize: false,
            child: Text(
              "Bitte wähle einen längeren Namen",
              style: Theme.of(context).textTheme.bodySmall!.copyWith(color: Colors.red),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: loading ? CupertinoActivityIndicator() : FilledButton(
              onPressed: signIn,
              child: const Text("Sign In"),
            ),
          ),
        ]
      )
    ];

    (String, List<Widget>) currentPage;

    if (flow == null) {
      currentPage = (
        widget.startInfoText,
        [
          if (widget.loginFlowText != null)
            OnboardingButton(
              onPressed: () {
                setState(() {
                  flow = 0;
                  stage = 0;
                });
              },
              text: widget.loginFlowText!,
            ),
          if (widget.signUpFlowText != null)
            OnboardingButton(
              onPressed: () {
                setState(() {
                  flow = 1;
                  stage = 0;
                });
              },
              text: widget.signUpFlowText!,
            ),
          ...widget.extraFlowButtons
        ]
      );
    } else {
      List<(String, List<Widget>)> pages = [loginPages, signInPages][flow!];
      currentPage = pages[max(0, min(stage, pages.length - 1))];
    }

    //widget to be shown on top in portrait view and on left side in landscape
    Widget firstHalfWidget = Column(
      children: [
        widget.logo,
        if (currentPage.$1.isNotEmpty)
          KeyboardVisibilityBuilder(builder: (context, isKeyboardVisible) {
            if (isKeyboardVisible) return const SizedBox();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const Icon(Icons.info),
                  const SizedBox(width: 8),
                  Flexible(
                      child: Text(
                    currentPage.$1,
                    style: const TextStyle(color: Colors.black, fontSize: 15),
                  )),
                ],
              ),
            );
          })
      ],
    );

    return PopScope(
      canPop: stage == 0,
      child: Scaffold(
        body: Theme(
          data: ThemeData(
              colorScheme:
                  ColorScheme.fromSeed(seedColor: Colors.white, dynamicSchemeVariant: DynamicSchemeVariant.monochrome, brightness: Brightness.light).copyWith(onSurfaceVariant: Colors.black, onSurface: Colors.black, secondary: Colors.black, outline: Colors.black, onBackground: Colors.black),

          ),
          child: Stack(
            children: [
              SizedBox(
                width: size.width,
                height: size.height,
                child: animatedBackground(),
              ),
              Container(
                width: size.width,
                height: size.height,
                color: Colors.black.withAlpha(50),
              ),
              if (isPortrait)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    SizedBox(height: size.height * 0.1),
                    SizedBox(
                        width: size.width * 1,
                        child: firstHalfWidget),
                    SizedBox(height: size.height * 0.05),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: currentPage.$2,
                        ),
                      ),
                    )
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Column(
                      mainAxisSize: MainAxisSize.max,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: size.width * 0.4,
                          child: firstHalfWidget,
                        ),
                      ],
                    ),
                    SizedBox(
                      width: size.width * 0.6,
                      child: SingleChildScrollView(
                        child: Column(
                          children: currentPage.$2,
                        ),
                      ),
                    )
                  ],
                ),
              if (flow != null)
                KeyboardVisibilityBuilder(builder: (context, isKeyboardVisible) {
                  if (isKeyboardVisible) return const SizedBox();
                  return Align(
                    alignment: Alignment.bottomLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: TextButton(onPressed: () => back(), child: const Text("Zurück")),
                    ),
                  );
                })
            ],
          ),
        ),
      ),
    );
  }
}

class OnboardingText extends StatelessWidget {
  const OnboardingText({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Text(
        text,
        style: const TextStyle(color: Colors.black, fontSize: 15),
      ),
    );
  }
}

class OnboardingButton extends StatelessWidget {
  const OnboardingButton({super.key, this.onPressed, required this.text});

  final VoidCallback? onPressed;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
      child: ElevatedButton(
        onPressed: onPressed,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 60),
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 15),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

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
          } else if (e.code == 'wrong-password') {
            return 'Falsches Passwort.';
          } else if(e.code == 'invalid-email'){
            return 'Ungültige E-Mail-Adresse.';
          }
        }
        return null;
      },
    );
  }
}

class ReauthenticatePage extends StatelessWidget {
  const ReauthenticatePage({super.key, required this.onReauthenticated});

  final Function onReauthenticated;

  @override
  Widget build(BuildContext context) {
    if (FirebaseAuth.instance.currentUser == null) {
      return const Text("Du bist nicht angemeldet.");
    }
    String currentEmail = FirebaseAuth.instance.currentUser!.email!;
    return SingleChildScrollView(
      child: EmailPasswordForm(
        submitText: 'Login',
        onSubmit: (email, password) async {
          if (email != currentEmail) {
            return 'Die E-Mail-Adresse stimmt nicht mit der des angemeldeten Benutzers überein.';
          }
          try {
            final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
            onReauthenticated();
          } on FirebaseAuthException catch (e) {
            if (e.code == 'user-not-found') {
              return 'Kein Benutzer mit dieser E-Mail-Adresse gefunden.';
            } else if (e.code == 'wrong-password') {
              return 'Falsches Passwort.';
            } else if(e.code == 'invalid-email'){
              return 'Ungültige E-Mail-Adresse.';
            }
          }
          return null;
        },
      ),
    );
  }
}

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  bool acceptedTerms = false;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EmailPasswordForm(
            submitText: "Registrieren",
            confirmPassword: true,
            onSubmit: (email, password) async {
              if(email.isEmpty){
                return "Bitte gib eine E-Mail-Adresse ein.";
              }
              if(password.isEmpty){
                return "Bitte gib ein Passwort ein.";
              }

              // if (!acceptedTerms) {
              //   return "Bitte akzeptiere die Bedingungen.";
              // }

              final connectivityResult = await (Connectivity().checkConnectivity());
              if (connectivityResult == ConnectivityResult.none) {
                return "Du bist nicht mit dem Internet verbunden";
              }

              await Firebase.initializeApp(
                options: DefaultFirebaseOptions.currentPlatform,
              );

              try {
                final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(
                  email: email,
                  password: password,
                );
              } on FirebaseAuthException catch (e) {
                if (e.code == 'weak-password') {
                  return 'Das Passwort ist zu schwach.';
                } else if (e.code == 'email-already-in-use') {
                  return 'Es existiert bereits ein Benutzer mit dieser E-Mail-Adresse.';
                }
              } catch (e) {
                print(e);
                return 'Ein unbekannter Fehler ist aufgetreten.';
              }
              return null;
            },
          ),
          // TODO Row(
          //   children: [
          //     Checkbox(
          //         value: acceptedTerms,
          //         onChanged: (value) => setState(() {
          //               acceptedTerms = value ?? false;
          //             })),
          //     Expanded(child: Text("Ich akzeptiere die Datenschutzerklärung und allgemeinen Geschäftsbedingungen.", style: TextStyle(color: Colors.black),))
          //   ],
          // )
        ],
      ),
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
  String? error;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 10),
          TextField(
            controller: emailController,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: "Email",
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: passwordController,
            keyboardType: TextInputType.visiblePassword,
            obscureText: !passwordVisible,
            decoration: InputDecoration(
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
            const SizedBox(height: 10),
            TextField(
              controller: password2Controller,
              obscureText: !password2Visible,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
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
            Text(
              error!,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.error),
            ),
            const SizedBox(height: 10),
          ],
          ElevatedButton(
            onPressed: () async {
              if (widget.confirmPassword && passwordController.text != password2Controller.text) {
                setState(() {
                  error = "Die Passwörter stimmen nicht überein.";
                });
                return;
              }
              error = await widget.onSubmit(emailController.text, passwordController.text);
              setState(() {});
            },
            child: Text(widget.submitText),
          ),
        ],
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