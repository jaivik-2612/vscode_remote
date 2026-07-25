import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../widgets/common.dart';
import '../projects/project_page.dart';

class SearchPage extends ConsumerWidget {
  const SearchPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ref.watch(searchQueryProvider);
    final results = ref.watch(searchResultsProvider).value ?? const [];

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Search tasks…',
            prefixIcon: const Icon(Icons.search),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide.none,
            ),
            filled: true,
            isDense: true,
          ),
          onChanged: (value) =>
              ref.read(searchQueryProvider.notifier).set(value),
        ),
        toolbarHeight: 68,
      ),
      body: query.trim().isEmpty
          ? const EmptyState(
              icon: Icons.search,
              title: 'Search everything',
              subtitle: 'Find tasks by title or notes, across all projects.',
            )
          : results.isEmpty
              ? const EmptyState(
                  icon: Icons.search_off,
                  title: 'No matches',
                  subtitle: 'Try a different search term.',
                )
              : ListView(
                  children: [
                    for (final entry in results)
                      TaskListTile(task: entry.task, project: entry.project),
                  ],
                ),
    );
  }
}
