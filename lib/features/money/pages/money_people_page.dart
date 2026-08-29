import 'dart:async';

import 'package:flutter/material.dart';

import 'package:couple_planner/features/money/money_context.dart';
import 'package:couple_planner/features/money/models/money_person.dart';

/// Who can appear on an expense: the group's members, plus placeholders for
/// people who have no account yet.
///
/// A placeholder is linked to a real account by [MoneyPerson.claimedBy]. The
/// newcomer normally does that themselves from the banner on the Money tab;
/// this screen is the manual override, and the only place a link can be undone.
class MoneyPeoplePage extends StatefulWidget {
  const MoneyPeoplePage({super.key, required this.ctx});

  final MoneyContext ctx;

  @override
  State<MoneyPeoplePage> createState() => _MoneyPeoplePageState();
}

class _MoneyPeoplePageState extends State<MoneyPeoplePage> {
  bool _busy = false;

  /// This page is the one place that edits people, so it watches them itself
  /// rather than rendering the snapshot it was pushed with — otherwise an add,
  /// rename or link would only appear after leaving and coming back.
  StreamSubscription<List<MoneyPerson>>? _peopleSub;
  List<MoneyPerson>? _people;

  MoneyContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    _peopleSub = ctx.repo.watchPeople().listen((people) {
      if (mounted) setState(() => _people = people);
    }, onError: (Object e) => debugPrint('money people: $e'));
  }

  @override
  void dispose() {
    _peopleSub?.cancel();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action, String failure) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(failure)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askName({String initial = ''}) async {
    final controller = TextEditingController(text: initial);
    try {
      return await _nameDialog(controller, initial);
    } finally {
      controller.dispose();
    }
  }

  Future<String?> _nameDialog(TextEditingController controller, String initial) {
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(initial.isEmpty ? 'Add a person' : 'Rename'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _addPerson() async {
    final name = await _askName();
    if (name == null || name.isEmpty) return;
    await _run(() => ctx.repo.addPerson(name), 'Could not add that person.');
  }

  Future<void> _linkTo(MoneyPerson person) async {
    final uid = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Link ${person.name} to'),
        children: [
          for (final memberUid in ctx.directory.memberUids)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(memberUid),
              child: Text(ctx.directory.properNameFor(memberUid)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('Nobody (unlink)'),
          ),
        ],
      ),
    );
    if (uid == null) return;
    await _run(
      () => ctx.repo.setPersonClaim(person.id, uid.isEmpty ? null : uid),
      'Could not change that link.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final ghosts = List<MoneyPerson>.of(_people ?? ctx.directory.people)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return Scaffold(
      appBar: AppBar(title: const Text('People')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _busy ? null : _addPerson,
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add person'),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 96),
        children: [
          const _Header('Members'),
          for (final uid in ctx.directory.memberUids)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(ctx.directory.properNameFor(uid)),
              subtitle: uid == ctx.myUid ? const Text('you') : null,
              trailing: Text(ctx.format.format(ctx.netFor(uid))),
            ),
          const _Header('Not in the group yet'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Add someone here to split with them before they have an '
              'account. When they join they can pick themselves, and their '
              'history moves over.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          if (ghosts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text('Nobody yet.', style: TextStyle(fontSize: 13)),
            ),
          for (final person in ghosts) _personTile(person),
        ],
      ),
    );
  }

  Widget _personTile(MoneyPerson person) {
    final claimedName =
        person.isClaimed ? ctx.directory.properNameFor(person.claimedBy!) : null;

    return ListTile(
      leading: CircleAvatar(
        child: Icon(person.isClaimed ? Icons.link : Icons.person_outline),
      ),
      title: Text(
        person.name,
        style: TextStyle(
          decoration: person.archived ? TextDecoration.lineThrough : null,
        ),
      ),
      subtitle: Text(
        claimedName != null
            ? 'linked to $claimedName'
            : (person.archived ? 'archived' : 'not linked to an account'),
        style: const TextStyle(fontSize: 12),
      ),
      trailing: PopupMenuButton<String>(
        enabled: !_busy,
        onSelected: (action) async {
          switch (action) {
            case 'rename':
              final name = await _askName(initial: person.name);
              if (name == null || name.isEmpty) return;
              await _run(() => ctx.repo.renamePerson(person.id, name),
                  'Could not rename.');
            case 'archive':
              await _run(
                  () => ctx.repo.setPersonArchived(person.id, !person.archived),
                  'Could not archive.');
            case 'claim':
              await _run(() => ctx.repo.setPersonClaim(person.id, ctx.myUid),
                  'Could not link you to that person.');
            case 'link':
              await _linkTo(person);
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(
            value: 'archive',
            child: Text(person.archived ? 'Unarchive' : 'Archive'),
          ),
          if (!person.isClaimed)
            const PopupMenuItem(value: 'claim', child: Text("That's me")),
          if (ctx.isAdmin)
            const PopupMenuItem(value: 'link', child: Text('Link to a member…')),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
