import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';
import '../../providers.dart';
import '../../widgets/common.dart';
import '../projects/project_page.dart';

/// "My work": every open task across projects, grouped by urgency.
class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openTasksProvider).value ?? const [];

    final today = DateUtils.dateOnly(DateTime.now());
    final endOfWeek = today.add(const Duration(days: 7));

    final overdue = <TaskWithProject>[];
    final dueToday = <TaskWithProject>[];
    final upcoming = <TaskWithProject>[];
    final later = <TaskWithProject>[];
    for (final entry in open) {
      final due = entry.task.dueDate;
      if (due == null) {
        later.add(entry);
      } else if (DateUtils.dateOnly(due).isBefore(today)) {
        overdue.add(entry);
      } else if (DateUtils.dateOnly(due) == today) {
        dueToday.add(entry);
      } else if (DateUtils.dateOnly(due).isBefore(endOfWeek)) {
        upcoming.add(entry);
      } else {
        later.add(entry);
      }
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('My work'),
            Text(
              DateFormat.yMMMMEEEEd().format(DateTime.now()),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        toolbarHeight: 68,
      ),
      body: open.isEmpty
          ? const EmptyState(
              icon: Icons.wb_sunny_outlined,
              title: 'All clear',
              subtitle:
                  'No open tasks. Enjoy the calm, or head to Projects to plan what’s next.',
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _Section(
                  title: 'Overdue',
                  color: Theme.of(context).colorScheme.error,
                  entries: overdue,
                ),
                _Section(title: 'Today', entries: dueToday),
                _Section(title: 'Next 7 days', entries: upcoming),
                _Section(title: 'Later & unscheduled', entries: later),
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.entries, this.color});

  final String title;
  final List<TaskWithProject> entries;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            '$title · ${entries.length}',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
          ),
        ),
        for (final entry in entries)
          TaskListTile(task: entry.task, project: entry.project),
      ],
    );
  }
}
