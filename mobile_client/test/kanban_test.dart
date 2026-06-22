import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/kanban.dart';

void main() {
  group('kanbanTaskId', () {
    test('reads the `id` field', () {
      expect(kanbanTaskId({'id': 't_1', 'title': 'A'}), 't_1');
    });

    test('falls back to `task_id`', () {
      expect(kanbanTaskId({'task_id': 't_2'}), 't_2');
    });

    test('prefers `id` over `task_id` when both present', () {
      expect(kanbanTaskId({'id': 't_a', 'task_id': 't_b'}), 't_a');
    });

    test('returns empty string when neither key is present', () {
      expect(kanbanTaskId({'title': 'no id'}), '');
    });

    test('stringifies non-string ids', () {
      expect(kanbanTaskId({'id': 42}), '42');
    });
  });

  group('kanbanTaskColumn', () {
    test('reads `status` (the bridge column key)', () {
      expect(kanbanTaskColumn({'status': 'ready'}), 'ready');
    });

    test('tolerates a `column` alias', () {
      expect(kanbanTaskColumn({'column': 'done'}), 'done');
    });

    test('prefers `column` over `status` when both present', () {
      expect(kanbanTaskColumn({'column': 'todo', 'status': 'done'}), 'todo');
    });

    test('falls back to `todo` when missing or blank', () {
      expect(kanbanTaskColumn({'title': 'x'}), 'todo');
      expect(kanbanTaskColumn({'status': '   '}), 'todo');
    });

    test('trims surrounding whitespace', () {
      expect(kanbanTaskColumn({'status': '  blocked '}), 'blocked');
    });
  });

  group('groupTasksByColumn', () {
    test('buckets tasks by column in the given column order', () {
      final tasks = [
        {'id': '1', 'status': 'todo'},
        {'id': '2', 'status': 'done'},
        {'id': '3', 'status': 'todo'},
      ];
      final grouped = groupTasksByColumn(tasks, kanbanColumns);
      expect(grouped['todo']!.map((t) => t['id']).toList(), ['1', '3']);
      expect(grouped['done']!.map((t) => t['id']).toList(), ['2']);
    });

    test('every requested column gets a (possibly empty) bucket', () {
      final grouped = groupTasksByColumn(const [], kanbanColumns);
      for (final c in kanbanColumns) {
        expect(grouped.containsKey(c), isTrue);
        expect(grouped[c], isEmpty);
      }
    });

    test('drops tasks whose column is not in the requested set', () {
      final tasks = [
        {'id': '1', 'status': 'review'}, // not in kanbanColumns
        {'id': '2', 'status': 'todo'},
      ];
      final grouped = groupTasksByColumn(tasks, kanbanColumns);
      final all = grouped.values.expand((l) => l).toList();
      expect(all.map((t) => t['id']).toList(), ['2']);
    });

    test('ignores non-map entries defensively', () {
      final tasks = [
        'garbage',
        42,
        {'id': '1', 'status': 'ready'},
      ];
      final grouped = groupTasksByColumn(tasks, kanbanColumns);
      expect(grouped['ready']!.map((t) => t['id']).toList(), ['1']);
    });

    test('returns String-keyed maps, not the original Map type', () {
      final grouped = groupTasksByColumn(
        [
          {'id': '1', 'status': 'todo'}
        ],
        kanbanColumns,
      );
      expect(grouped['todo']!.first, isA<Map<String, dynamic>>());
    });
  });

  group('kanbanFlattenTasks', () {
    test('flattens the bridge {columns: [{name, tasks}]} shape', () {
      final board = {
        'columns': [
          {
            'name': 'todo',
            'tasks': [
              {'id': '1'},
              {'id': '2'}
            ]
          },
          {
            'name': 'done',
            'tasks': [
              {'id': '3'}
            ]
          },
        ],
      };
      final out = kanbanFlattenTasks(board);
      expect(out.map((t) => t['id']).toList(), ['1', '2', '3']);
    });

    test('tolerates a bare {tasks: [...]} shape', () {
      final out = kanbanFlattenTasks({
        'tasks': [
          {'id': 'a'},
          {'id': 'b'}
        ]
      });
      expect(out.map((t) => t['id']).toList(), ['a', 'b']);
    });

    test('returns empty for an empty/garbage board', () {
      expect(kanbanFlattenTasks({}), isEmpty);
      expect(kanbanFlattenTasks({'columns': 'nope'}), isEmpty);
    });
  });

  group('kanbanSlugify', () {
    test('lowercases and hyphenates', () {
      expect(kanbanSlugify('My Cool Board'), 'my-cool-board');
    });

    test('strips leading/trailing separators and collapses runs', () {
      expect(kanbanSlugify('  Hello!!  World  '), 'hello-world');
    });

    test('falls back to "board" for empty input', () {
      expect(kanbanSlugify('   '), 'board');
      expect(kanbanSlugify('!!!'), 'board');
    });
  });
}
