import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jarviscopilot_mobile/chat/chat_controller.dart';
import 'package:jarviscopilot_mobile/widgets/composer_attach.dart';

Uint8List _bytes(int n) => Uint8List.fromList(List.filled(n, 1));

void main() {
  test('an image attachment uploads exactly once', () async {
    final calls = <String>[];
    final out = await uploadChatAttachments(
      [PendingAttachment(name: 'a.jpg', bytes: _bytes(3), isImage: true)],
      (name, b) async {
        calls.add(name);
        return {'filename': name, 'path': '/u/$name', 'is_image': true};
      },
    );
    expect(calls, ['a.jpg']);
    expect(out.length, 1);
    expect(out.first['path'], '/u/a.jpg');
  });

  test('a video uploads the file AND a poster image (vision)', () async {
    final calls = <String>[];
    final out = await uploadChatAttachments(
      [
        PendingAttachment(
            name: 'clip.mov',
            bytes: _bytes(5),
            isVideo: true,
            posterBytes: _bytes(2)),
      ],
      (name, b) async {
        calls.add(name);
        return {'filename': name, 'path': '/u/$name', 'is_image': name.endsWith('.jpg')};
      },
    );
    expect(calls, ['clip.mov', 'clip.mov.poster.jpg']);
    expect(out.length, 2);
    expect(out[1]['is_image'], true); // poster is a vision image the model sees
  });

  test('a video without a poster uploads only the file', () async {
    final out = await uploadChatAttachments(
      [PendingAttachment(name: 'clip.mov', bytes: _bytes(5), isVideo: true)],
      (name, b) async => {'filename': name, 'path': '/u/$name'},
    );
    expect(out.length, 1);
  });

  test('a failed upload is skipped; the rest still send', () async {
    final out = await uploadChatAttachments(
      [
        PendingAttachment(name: 'bad.png', bytes: _bytes(1), isImage: true),
        PendingAttachment(name: 'ok.png', bytes: _bytes(1), isImage: true),
      ],
      (name, b) async {
        if (name == 'bad.png') throw Exception('boom');
        return {'filename': name, 'path': '/u/$name'};
      },
    );
    expect(out.length, 1);
    expect(out.first['path'], '/u/ok.png');
  });

  test('an empty upload result is not added', () async {
    final out = await uploadChatAttachments(
      [PendingAttachment(name: 'x', bytes: _bytes(1))],
      (name, b) async => <String, dynamic>{},
    );
    expect(out, isEmpty);
  });
}
