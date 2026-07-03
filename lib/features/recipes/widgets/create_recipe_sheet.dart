import 'package:flutter/material.dart';

/// What the user chose in the create-recipe menu.
enum CreateRecipeType { blank, photo, text }

/// The result popped by [CreateRecipeSheet].
class CreateRecipeResult {
  const CreateRecipeResult(this.type, [this.text]);
  final CreateRecipeType type;
  final String? text;
}

/// Text-first create menu (design 3): a focused field for a name, description
/// or link, with a photo and a blank-recipe option beneath it. The AI-driven
/// options are only offered when [aiEnabled].
class CreateRecipeSheet extends StatefulWidget {
  const CreateRecipeSheet({super.key, required this.aiEnabled});

  final bool aiEnabled;

  @override
  State<CreateRecipeSheet> createState() => _CreateRecipeSheetState();
}

class _CreateRecipeSheetState extends State<CreateRecipeSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submitText() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(context, CreateRecipeResult(CreateRecipeType.text, text));
  }

  Widget _option(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(height: 8),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 4, 16, 16 + insets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.aiEnabled) ...[
            TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submitText(),
              decoration: InputDecoration(
                hintText: 'Name, description or link…',
                prefixIcon: const Icon(Icons.auto_awesome),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _submitText,
                ),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              if (widget.aiEnabled) ...[
                Expanded(
                  child: _option(Icons.photo_camera, 'From photo',
                      () => Navigator.pop(context, const CreateRecipeResult(CreateRecipeType.photo))),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: _option(Icons.edit_note, 'Blank recipe', () {
                  final text = _controller.text.trim();
                  Navigator.pop(
                    context,
                    CreateRecipeResult(CreateRecipeType.blank, text.isEmpty ? null : text),
                  );
                }),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
