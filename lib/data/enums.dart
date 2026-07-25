import 'package:flutter/material.dart';

/// Workflow column a task lives in. Fixed set for v1; custom columns are on
/// the roadmap and will migrate these to per-project columns.
enum TaskStatus {
  backlog('Backlog', Icons.inbox_outlined),
  todo('To do', Icons.radio_button_unchecked),
  inProgress('In progress', Icons.play_circle_outline),
  done('Done', Icons.check_circle_outline);

  const TaskStatus(this.label, this.icon);

  final String label;
  final IconData icon;

  bool get isOpen => this != TaskStatus.done;
}

enum TaskPriority {
  none('None', Color(0xFF9E9E9E)),
  low('Low', Color(0xFF4CAF50)),
  medium('Medium', Color(0xFF2196F3)),
  high('High', Color(0xFFFF9800)),
  urgent('Urgent', Color(0xFFF44336));

  const TaskPriority(this.label, this.color);

  final String label;
  final Color color;
}

/// Colors a project can be tagged with (stored by index-independent ARGB
/// value so reordering this list never corrupts saved data).
const List<Color> projectColors = [
  Color(0xFF6750A4),
  Color(0xFF2196F3),
  Color(0xFF009688),
  Color(0xFF4CAF50),
  Color(0xFFFF9800),
  Color(0xFFF44336),
  Color(0xFFE91E63),
  Color(0xFF795548),
];
