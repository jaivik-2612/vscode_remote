import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waypoint/data/database.dart';
import 'package:waypoint/data/workspace.dart';
import 'package:waypoint/sync/session.dart';

/// Real end-to-end LAN session: host + two clients over live WebSockets on
/// an ephemeral localhost port.
void main() {
  late AppDatabase hostDb;
  late HostSession host;

  setUp(() async {
    hostDb = AppDatabase(NativeDatabase.memory());
    host = HostSession(db: hostDb, hostName: 'Priya', port: 0);
    await host.start();
  });

  tearDown(() async {
    await host.stop();
    await hostDb.close();
  });

  Future<ClientSession> join(AppDatabase db, String name,
      {String? code}) async {
    final client = ClientSession(db: db);
    await client.connect(
      address: '127.0.0.1:${host.boundPort}',
      code: code ?? host.code,
      name: name,
    );
    return client;
  }

  Future<void> eventually(Future<bool> Function() check) async {
    for (var i = 0; i < 200; i++) {
      if (await check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('Condition not met within 5s');
  }

  test('join receives the host workspace snapshot and presence', () async {
    final project = await hostDb.createProject(name: 'Launch', color: 1);
    await hostDb.createTask(projectId: project.id, title: 'Ship it');

    final clientDb = AppDatabase(NativeDatabase.memory());
    addTearDown(clientDb.close);
    final client = await join(clientDb, 'Sam');
    addTearDown(client.close);

    expect((await clientDb.watchProjects().first).single.name, 'Launch');
    expect((await clientDb.watchTasksForProject(project.id).first).single.title,
        'Ship it');
    expect(client.members.map((m) => m.name), containsAll(['Priya', 'Sam']));
    expect(client.members.singleWhere((m) => m.isHost).name, 'Priya');
  });

  test('wrong join code is rejected', () async {
    final clientDb = AppDatabase(NativeDatabase.memory());
    addTearDown(clientDb.close);
    await expectLater(
      join(clientDb, 'Mallory', code: 'WRONG1'),
      throwsA(isA<SessionRejectedException>()),
    );
  });

  test('edits relay live: client -> host -> other client, and host -> all',
      () async {
    final dbA = AppDatabase(NativeDatabase.memory());
    final dbB = AppDatabase(NativeDatabase.memory());
    addTearDown(dbA.close);
    addTearDown(dbB.close);

    final clientA = await join(dbA, 'Ana');
    final clientB = await join(dbB, 'Ben');
    addTearDown(clientA.close);
    addTearDown(clientB.close);

    // Ana creates a project + task; ops flow through her Workspace.
    final workspaceA = Workspace(dbA, onOps: clientA.sendOps);
    final project =
        await workspaceA.createProject(name: 'Sprint 12', color: 2);
    await workspaceA.createTask(projectId: project.id, title: 'From Ana');

    await eventually(() async =>
        (await hostDb.watchTasksForProject(project.id).first).isNotEmpty);
    await eventually(() async =>
        (await dbB.watchTasksForProject(project.id).first).isNotEmpty);
    expect((await dbB.watchProjects().first).single.name, 'Sprint 12');

    // The host edits too; everyone sees it.
    final hostWorkspace = Workspace(hostDb, onOps: host.broadcastOps);
    await hostWorkspace.createTask(
        projectId: project.id, title: 'From the host');
    await eventually(() async =>
        (await dbA.watchTasksForProject(project.id).first).length == 2);
    await eventually(() async =>
        (await dbB.watchTasksForProject(project.id).first).length == 2);
  });

  test('members update when a client leaves', () async {
    final dbA = AppDatabase(NativeDatabase.memory());
    final dbB = AppDatabase(NativeDatabase.memory());
    addTearDown(dbA.close);
    addTearDown(dbB.close);

    final clientA = await join(dbA, 'Ana');
    final clientB = await join(dbB, 'Ben');
    addTearDown(clientB.close);

    await eventually(() async => clientB.members.length == 3);
    await clientA.close();
    await eventually(() async => clientB.members.length == 2);
    expect(clientB.members.map((m) => m.name), isNot(contains('Ana')));
  });
}
