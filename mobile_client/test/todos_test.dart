import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/api/todos.dart';

/// Builds a `role: 'tool'` message whose JSON content carries [todos].
Map<String, dynamic> _toolMsg(List<Map<String, dynamic>> todos) => {
      'role': 'tool',
      'content': jsonEncode({'todos': todos}),
    };

void main() {
  group('extractTodos', () {
    test('returns the todos from a single tool message', () {
      final todos = [
        {'id': '1', 'content': 'Write the code', 'status': 'in_progress'},
        {'id': '2', 'content': 'Ship it', 'status': 'pending'},
      ];
      final messages = [
        {'role': 'user', 'content': 'do the thing'},
        _toolMsg(todos),
        {'role': 'assistant', 'content': 'on it'},
      ];
      final out = extractTodos(messages);
      expect(out.length, 2);
      expect(out[0]['content'], 'Write the code');
      expect(out[0]['status'], 'in_progress');
      expect(out[1]['status'], 'pending');
    });

    test('returns the NEWEST todos message when several are present', () {
      final older = [
        {'id': '1', 'content': 'old task', 'status': 'pending'},
      ];
      final newer = [
        {'id': '1', 'content': 'old task', 'status': 'completed'},
        {'id': '2', 'content': 'new task', 'status': 'in_progress'},
      ];
      final messages = [
        _toolMsg(older),
        {'role': 'assistant', 'content': 'progress'},
        _toolMsg(newer),
        {'role': 'assistant', 'content': 'more progress'},
      ];
      final out = extractTodos(messages);
      // Newest-first scan must land on `newer`, not `older`.
      expect(out.length, 2);
      expect(out[0]['status'], 'completed');
      expect(out[1]['content'], 'new task');
    });

    test('returns [] when no message carries a todos list', () {
      final messages = [
        {'role': 'user', 'content': 'hello'},
        {'role': 'assistant', 'content': 'hi there'},
        // A tool message with no todos in its JSON is ignored.
        {
          'role': 'tool',
          'content': jsonEncode({'result': 'ok'}),
        },
      ];
      expect(extractTodos(messages), isEmpty);
    });

    test('empty messages list returns []', () {
      expect(extractTodos(const []), isEmpty);
    });

    test('an empty todos array is treated as no list (keeps scanning)', () {
      final messages = [
        _toolMsg([
          {'id': '1', 'content': 'real task', 'status': 'pending'},
        ]),
        // A later tool message with an empty todos array must NOT shadow the
        // real list above (mirrors panels.js: requires a non-empty array).
        _toolMsg(const []),
      ];
      final out = extractTodos(messages);
      expect(out.length, 1);
      expect(out[0]['content'], 'real task');
    });

    test('tolerates already-decoded map content', () {
      final messages = [
        {
          'role': 'tool',
          'content': {
            'todos': [
              {'id': '1', 'content': 'decoded task', 'status': 'completed'},
            ],
          },
        },
      ];
      final out = extractTodos(messages);
      expect(out.length, 1);
      expect(out[0]['content'], 'decoded task');
    });
  });
}
