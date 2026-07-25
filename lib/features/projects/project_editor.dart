import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/database.dart';
import '../../data/enums.dart';
import '../../sync/session_controller.dart';
import '../../widgets/common.dart';

/// Create ([project] == null) or edit a project.
Future<Project?> showProjectEditor(BuildContext context, {Project? project}) {
  return showDialog<Project?>(
    context: context,
    builder: (context) => _ProjectEditorDialog(project: project),
  );
}

class _ProjectEditorDialog extends ConsumerStatefulWidget {
  const _ProjectEditorDialog({this.project});

  final Project? project;

  @override
  ConsumerState<_ProjectEditorDialog> createState() =>
      _ProjectEditorDialogState();
}

class _ProjectEditorDialogState extends ConsumerState<_ProjectEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late int _color;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.project?.name ?? '');
    _description =
        TextEditingController(text: widget.project?.description ?? '');
    _color = widget.project?.color ?? projectColors.first.toARGB32();
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final db = ref.read(workspaceProvider);
    final Project result;
    if (widget.project == null) {
      result = await db.createProject(
        name: name,
        description: _description.text.trim(),
        color: _color,
      );
    } else {
      result = widget.project!.copyWith(
        name: name,
        description: _description.text.trim(),
        color: _color,
      );
      await db.updateProject(result);
    }
    if (mounted) Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.project == null ? 'New project' : 'Edit project'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            ColorPickerRow(
              selected: _color,
              onSelected: (value) => setState(() => _color = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.project == null ? 'Create' : 'Save'),
        ),
      ],
    );
  }
}
