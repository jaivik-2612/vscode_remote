// Renders the real app at each platform's form factor and writes PNGs to
// docs/screenshots/. Not part of the regular suite — run explicitly:
//
//   flutter test tool/make_screenshots_test.dart
//
// (The native Linux screenshot is taken separately from the running release
// build under Xvfb; see docs/screenshots/README.md.)
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:waypoint/app.dart';
import 'package:waypoint/data/database.dart';
import 'package:waypoint/features/projects/project_page.dart';
import 'package:waypoint/providers.dart';

import 'demo_data.dart';

const _fontDir = '/opt/flutter/bin/cache/artifacts/material_fonts';
final _shotKey = GlobalKey();

void main() {
  setUpAll(() async {
    // Real fonts instead of the block-glyph test font. iOS/macOS/Windows
    // themes ask for system families that don't exist here, so register
    // Roboto under those names as well.
    const families = [
      'Roboto',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
      '.AppleSystemUIFont',
      '.SF UI Text',
      '.SF UI Display',
      '.SF Pro Text',
      '.SF Pro Display',
      'Segoe UI',
    ];
    for (final family in families) {
      final loader = FontLoader(family);
      for (final file in [
        'Roboto-Regular.ttf',
        'Roboto-Medium.ttf',
        'Roboto-Bold.ttf'
      ]) {
        loader.addFont(_load('$_fontDir/$file'));
      }
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(_load('$_fontDir/MaterialIcons-Regular.otf'));
    await icons.load();
    Directory('docs/screenshots').createSync(recursive: true);
  });

  // ignore: invalid_use_of_visible_for_testing_member
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('android — My work dashboard (phone)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDemoWorkspace(db);
    await _configure(tester, TargetPlatform.android, const Size(412, 915), 2.625);

    await tester.pumpWidget(_shell(db));
    await tester.pumpAndSettle();
    await _capture(tester, 'android_my_work.png', 2.625);
    await _unmount(tester);
  });

  testWidgets('ios — kanban board (phone)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final projectId = await seedDemoWorkspace(db);
    await _configure(tester, TargetPlatform.iOS, const Size(393, 852), 3);

    await tester.pumpWidget(_project(db, projectId));
    await tester.pumpAndSettle();
    await _capture(tester, 'ios_board.png', 3);
    await _unmount(tester);
  });

  testWidgets('macos — projects overview (desktop)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await seedDemoWorkspace(db);
    await _configure(tester, TargetPlatform.macOS, const Size(1280, 800), 2);

    await tester.pumpWidget(_shell(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Projects').last);
    await tester.pumpAndSettle();
    await _capture(tester, 'macos_projects.png', 2);
    await _unmount(tester);
  });

  testWidgets('windows — kanban board (desktop)', (tester) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final projectId = await seedDemoWorkspace(db);
    await _configure(tester, TargetPlatform.windows, const Size(1366, 768), 1.5);

    await tester.pumpWidget(_project(db, projectId));
    await tester.pumpAndSettle();
    await _capture(tester, 'windows_board.png', 1.5);
    await _unmount(tester);
  });
}

Future<ByteData> _load(String path) async {
  return ByteData.sublistView(File(path).readAsBytesSync());
}

Future<void> _configure(
  WidgetTester tester,
  TargetPlatform platform,
  Size logicalSize,
  double dpr,
) async {
  debugDefaultTargetPlatformOverride = platform;
  tester.view.physicalSize = logicalSize * dpr;
  tester.view.devicePixelRatio = dpr;
  addTearDown(tester.view.reset);
}

Widget _shell(AppDatabase db) => RepaintBoundary(
      key: _shotKey,
      child: ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: const WaypointApp(),
      ),
    );

Widget _project(AppDatabase db, String projectId) => RepaintBoundary(
      key: _shotKey,
      child: ProviderScope(
        overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: waypointTheme(Brightness.light),
          home: ProjectPage(projectId: projectId),
        ),
      ),
    );

Future<void> _capture(WidgetTester tester, String name, double dpr) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_shotKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: dpr);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('docs/screenshots/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

Future<void> _unmount(WidgetTester tester) async {
  // Must happen inside the test body: the framework checks this variable is
  // back to null before tearDown callbacks run.
  debugDefaultTargetPlatformOverride = null;
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 1));
}
