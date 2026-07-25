import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';

/// The slowly shifting green/orange mesh gradient used behind onboarding, the
/// create-group flow and the app's loading state.
Widget animatedBackground() => AnimatedMeshGradient(
  colors: const [
    Color.fromARGB(255, 93, 246, 170),
    Color.fromARGB(255, 76, 216, 90),
    Color.fromARGB(255, 192, 223, 98),
    Color.fromARGB(255, 255, 161, 68),
  ],
  options: AnimatedMeshGradientOptions(speed: 0.1),
);
