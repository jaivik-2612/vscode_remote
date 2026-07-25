import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:waypoint/app.dart';
import 'package:waypoint/data/database.dart';
import 'package:waypoint/providers.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildApp(AppDatabase db) {
    return ProviderScope(
      overrides: [appDatabaseProvider.overrideWithValue(db)],
      child: const WaypointApp(),
    );
  }

  // Drift closes its query streams with a zero-duration timer; unmount the
  // tree and pump so it fires before the pending-timer invariant check.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('boots to the dashboard and navigates to projects',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(buildApp(db));
    await tester.pumpAndSettle();

    expect(find.text('My work'), findsWidgets);
    expect(find.text('All clear'), findsOneWidget);

    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();
    expect(find.text('No projects yet'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('creates a project through the dialog', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);

    await tester.pumpWidget(buildApp(db));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create a project'));
    // Bounded pumps instead of pumpAndSettle: the dialog's autofocused text
    // field keeps a cursor-blink timer running, so the tree never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(
        find.widgetWithText(TextField, 'Name'), 'Side project');
    await tester.tap(find.text('Create'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    // The card appearing proves the write went through; don't await drift
    // streams directly here — their scheduling timers never fire under the
    // test's fake async, which deadlocks the await.
    expect(find.text('Side project'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('dashboard shows open tasks with project context',
      (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final project = await db.createProject(name: 'Chores', color: 0xFF2196F3);
    await db.createTask(projectId: project.id, title: 'Water the plants');

    await tester.pumpWidget(buildApp(db));
    await tester.pumpAndSettle();

    expect(find.text('Water the plants'), findsOneWidget);
    expect(find.text('Chores'), findsOneWidget);

    await unmount(tester);
  });
}
