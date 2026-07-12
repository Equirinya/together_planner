import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

/// Blocking loading dialog shown while an idea dragged onto a day is generated,
/// before the cooking-plan tile appears and the add-to-shopping-list dialog opens.
class GeneratingDialog extends StatelessWidget {
  const GeneratingDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return const Dialog(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CupertinoActivityIndicator(),
            SizedBox(width: 16),
            Flexible(child: Text('Generating recipe…')),
          ],
        ),
      ),
    );
  }
}
