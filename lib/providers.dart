import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/backup.dart';
import 'data/database.dart';
import 'sync/sync_service.dart';

/// Overridden with an in-memory database in tests.
final appDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase.open();
  ref.onDispose(db.close);
  return db;
});

final backupCodecProvider = Provider<BackupCodec>(
  (ref) => BackupCodec(ref.watch(appDatabaseProvider)),
);

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = LocalOnlySyncService();
  ref.onDispose(service.dispose);
  return service;
});

final syncStatusProvider = StreamProvider<SyncStatus>(
  (ref) => ref.watch(syncServiceProvider).status,
);

// -----------------------------------------------------------------------------
// Projects
// -----------------------------------------------------------------------------

final projectsProvider = StreamProvider<List<Project>>(
  (ref) => ref.watch(appDatabaseProvider).watchProjects(),
);

final archivedProjectsProvider = StreamProvider<List<Project>>(
  (ref) => ref.watch(appDatabaseProvider).watchProjects(archived: true),
);

final projectProvider = StreamProvider.family<Project?, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchProject(id),
);

final projectProgressProvider = StreamProvider<Map<String, ProjectProgress>>(
  (ref) => ref.watch(appDatabaseProvider).watchProjectProgress(),
);

// -----------------------------------------------------------------------------
// Tasks
// -----------------------------------------------------------------------------

final projectTasksProvider = StreamProvider.family<List<Task>, String>(
  (ref, projectId) =>
      ref.watch(appDatabaseProvider).watchTasksForProject(projectId),
);

final openTasksProvider = StreamProvider<List<TaskWithProject>>(
  (ref) => ref.watch(appDatabaseProvider).watchOpenTasks(),
);

final taskProvider = StreamProvider.family<Task?, String>(
  (ref, id) => ref.watch(appDatabaseProvider).watchTask(id),
);

final subtasksProvider = StreamProvider.family<List<Subtask>, String>(
  (ref, taskId) => ref.watch(appDatabaseProvider).watchSubtasks(taskId),
);

// -----------------------------------------------------------------------------
// Labels
// -----------------------------------------------------------------------------

final labelsProvider = StreamProvider<List<Label>>(
  (ref) => ref.watch(appDatabaseProvider).watchLabels(),
);

final taskLabelsProvider = StreamProvider.family<List<Label>, String>(
  (ref, taskId) => ref.watch(appDatabaseProvider).watchLabelsForTask(taskId),
);

// -----------------------------------------------------------------------------
// Search
// -----------------------------------------------------------------------------

class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) => state = query;
}

final searchQueryProvider =
    NotifierProvider<SearchQueryNotifier, String>(SearchQueryNotifier.new);

final searchResultsProvider = StreamProvider<List<TaskWithProject>>((ref) {
  final query = ref.watch(searchQueryProvider).trim();
  if (query.isEmpty) return const Stream.empty();
  return ref.watch(appDatabaseProvider).searchTasks(query);
});

// -----------------------------------------------------------------------------
// Settings
// -----------------------------------------------------------------------------

class ThemeModeNotifier extends Notifier<ThemeMode> {
  static const _prefKey = 'themeMode';

  @override
  ThemeMode build() {
    _load();
    return ThemeMode.system;
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefKey);
    if (saved != null) {
      state = ThemeMode.values.asNameMap()[saved] ?? ThemeMode.system;
    }
  }

  Future<void> set(ThemeMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, mode.name);
  }
}

final themeModeProvider =
    NotifierProvider<ThemeModeNotifier, ThemeMode>(ThemeModeNotifier.new);
