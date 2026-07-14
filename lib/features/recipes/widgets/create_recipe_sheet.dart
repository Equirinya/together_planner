import 'package:flutter/material.dart';
import 'package:couple_planner/features/ai/ai_access.dart';
import 'package:couple_planner/features/settings/ai_feature_settings.dart';

/// What the user chose in the create-recipe menu.
enum CreateRecipeType { blank, photo, text }

/// The result popped by [CreateRecipeSheet].
class CreateRecipeResult {
  const CreateRecipeResult(this.type, [this.text]);
  final CreateRecipeType type;
  final String? text;
}

/// Create-recipe menu: a blank recipe is the default action. AI-driven
/// creation (from a photo or from text/a link) is offered underneath as a
/// secondary option, only when the user's plan allows recipe generation.
class CreateRecipeSheet extends StatefulWidget {
  const CreateRecipeSheet({super.key, required this.access});

  final AiAccess access;

  @override
  State<CreateRecipeSheet> createState() => _CreateRecipeSheetState();
}

class _CreateRecipeSheetState extends State<CreateRecipeSheet> {
  final _controller = TextEditingController();
  String? _textError;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _createBlank() {
    final text = _controller.text.trim();
    Navigator.pop(
      context,
      CreateRecipeResult(CreateRecipeType.blank, text.isEmpty ? null : text),
    );
  }

  void _createWithAi(CreateRecipeType type) {
    final text = _controller.text.trim();
    if (type == CreateRecipeType.text && text.length < 3) {
      setState(() {
        _textError = text.isEmpty
            ? 'Please enter some text'
            : 'Please enter at least 3 characters';
      });
      return;
    }
    Navigator.pop(context, CreateRecipeResult(type, text.isEmpty ? null : text));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final insets = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + insets),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('New recipe', style: theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          TextField(
            controller: _controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onChanged: (_) {
              if (_textError != null) setState(() => _textError = null);
            },
            onSubmitted: (_) => _createBlank(),
            decoration: InputDecoration(
              labelText: 'Name',
              hintText: "e.g. Grandma's lasagna",
              errorText: _textError,
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _createBlank,
            icon: const Icon(Icons.add),
            label: const Text('Create recipe'),
          ),
          if (widget.access.canGenerateRecipes && AiFeatureSettings.generationEnabled.value) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(child: Divider(color: cs.outlineVariant)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or use AI',
                    style: theme.textTheme.labelMedium
                        ?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                Expanded(child: Divider(color: cs.outlineVariant)),
              ],
            ),
            const SizedBox(height: 16),
            if (!widget.access.hasGenerationQuota)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  "You've used all your AI generations for this month.",
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.access.hasGenerationQuota
                        ? () => _createWithAi(CreateRecipeType.photo)
                        : null,
                    icon: const Icon(Icons.photo_camera_outlined),
                    label: const Text('From photo'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.access.hasGenerationQuota
                        ? () => _createWithAi(CreateRecipeType.text)
                        : null,
                    icon: const Icon(Icons.auto_awesome_outlined),
                    label: const Text('From text'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
