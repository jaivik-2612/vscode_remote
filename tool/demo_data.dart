import 'package:waypoint/data/database.dart';
import 'package:waypoint/data/enums.dart';

/// Seeds a demo workspace; returns the id of the "Website redesign" project.
Future<String> seedDemoWorkspace(AppDatabase db) async {
  final now = DateTime.now();
  DateTime day(int offset) =>
      DateTime(now.year, now.month, now.day).add(Duration(days: offset));

  final web = await db.createProject(
    name: 'Website redesign',
    description: 'Q3 marketing site refresh',
    color: 0xFF2196F3,
  );
  final mobile = await db.createProject(
    name: 'Mobile app',
    description: 'v2.0 release',
    color: 0xFF6750A4,
  );
  final launch = await db.createProject(
    name: 'Launch campaign',
    description: 'Social, email and podcast push',
    color: 0xFFFF9800,
  );

  final design = await db.createLabel('design', 0xFFE91E63);
  final content = await db.createLabel('content', 0xFF009688);
  final dev = await db.createLabel('dev', 0xFF2196F3);

  // Website redesign — a busy board across all four columns.
  await db.createTask(
    projectId: web.id,
    title: 'Collect brand assets',
    status: TaskStatus.backlog,
  );
  await db.createTask(
    projectId: web.id,
    title: 'Competitive teardown',
    notes: 'Five sites max, focus on pricing pages.',
    status: TaskStatus.backlog,
    priority: TaskPriority.low,
  );
  final landing = await db.createTask(
    projectId: web.id,
    title: 'Design new landing page',
    notes: 'Hero, social proof, pricing grid.',
    priority: TaskPriority.high,
    dueDate: day(1),
  );
  await db.setTaskLabels(landing.id, {design.id});
  await db.addSubtask(landing.id, 'Hero section');
  await db.addSubtask(landing.id, 'Pricing grid');
  await db.addSubtask(landing.id, 'Mobile layout');
  final copy = await db.createTask(
    projectId: web.id,
    title: 'Write pricing page copy',
    priority: TaskPriority.medium,
    dueDate: day(3),
  );
  await db.setTaskLabels(copy.id, {content.id});
  final cms = await db.createTask(
    projectId: web.id,
    title: 'Migrate blog to new CMS',
    notes: '214 posts, keep slugs stable.',
    status: TaskStatus.inProgress,
    priority: TaskPriority.urgent,
    dueDate: day(0),
  );
  await db.setTaskLabels(cms.id, {dev.id, content.id});
  await db.createTask(
    projectId: web.id,
    title: 'Rebuild nav component',
    status: TaskStatus.inProgress,
    priority: TaskPriority.low,
  );
  for (final title in ['Kickoff workshop', 'Sitemap approved']) {
    final done = await db.createTask(projectId: web.id, title: title);
    await db.moveTask(done.id, TaskStatus.done, 0);
  }

  // Mobile app.
  final crash = await db.createTask(
    projectId: mobile.id,
    title: 'Fix login crash on Android 15',
    status: TaskStatus.inProgress,
    priority: TaskPriority.urgent,
    dueDate: day(-1),
  );
  await db.setTaskLabels(crash.id, {dev.id});
  await db.createTask(
    projectId: mobile.id,
    title: 'Push notification opt-in flow',
    status: TaskStatus.inProgress,
    priority: TaskPriority.medium,
    dueDate: day(2),
  );
  await db.createTask(
    projectId: mobile.id,
    title: 'App store screenshots',
    priority: TaskPriority.low,
  );
  final beta = await db.createTask(
    projectId: mobile.id,
    title: 'Beta signup flow',
  );
  await db.moveTask(beta.id, TaskStatus.done, 0);

  // Launch campaign.
  await db.createTask(
    projectId: launch.id,
    title: 'Draft launch email',
    priority: TaskPriority.high,
    dueDate: day(0),
  );
  await db.createTask(
    projectId: launch.id,
    title: 'Book podcast ads',
    dueDate: day(5),
  );
  await db.createTask(
    projectId: launch.id,
    title: 'Landing page A/B test plan',
    status: TaskStatus.backlog,
  );

  return web.id;
}
