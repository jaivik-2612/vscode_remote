// Seeds a demo workspace into a database file on disk. Used to prepare a
// running desktop build for screenshots:
//
//   SEED_DB_PATH=/path/to/waypoint.sqlite flutter test tool/seed_db_test.dart
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waypoint/data/database.dart';

import 'demo_data.dart';

void main() {
  test('seed database file', () async {
    final path = Platform.environment['SEED_DB_PATH'];
    if (path == null) {
      markTestSkipped('SEED_DB_PATH not set');
      return;
    }
    final db = AppDatabase(NativeDatabase(File(path)));
    await seedDemoWorkspace(db);
    await db.close();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
