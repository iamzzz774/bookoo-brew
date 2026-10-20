import 'dart:convert';

import 'package:bookoo_brew/web_download_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('assembles a chunked Brew Guide blob download', () {
    final assembler = WebDownloadAssembler();
    final bytes = utf8.encode('{"beans":["花香","柑橘"]}');
    final encoded = base64Encode(bytes);
    final splitAt = encoded.length ~/ 2;

    expect(
      assembler.addMessage(jsonEncode({
        'kind': 'start',
        'id': 'export-1',
        'fileName': 'brew-guide-data.json',
        'mimeType': 'application/json',
        'totalChunks': 2,
      })),
      isNull,
    );
    assembler.addMessage(jsonEncode({
      'kind': 'chunk',
      'id': 'export-1',
      'index': 0,
      'data': encoded.substring(0, splitAt),
    }));
    assembler.addMessage(jsonEncode({
      'kind': 'chunk',
      'id': 'export-1',
      'index': 1,
      'data': encoded.substring(splitAt),
    }));
    final payload = assembler.addMessage(jsonEncode({
      'kind': 'end',
      'id': 'export-1',
    }));

    expect(payload, isNotNull);
    expect(payload!.fileName, 'brew-guide-data.json');
    expect(payload.mimeType, 'application/json');
    expect(payload.bytes, bytes);
  });

  test('rejects an incomplete blob download', () {
    final assembler = WebDownloadAssembler();
    assembler.addMessage(jsonEncode({
      'kind': 'start',
      'id': 'export-2',
      'fileName': 'backup.json',
      'mimeType': 'application/json',
      'totalChunks': 1,
    }));

    expect(
      () => assembler.addMessage(
        jsonEncode({'kind': 'end', 'id': 'export-2'}),
      ),
      throwsFormatException,
    );
  });

  test('preserves binary ZIP exports and their file type', () {
    final assembler = WebDownloadAssembler();
    final zipBytes = <int>[0x50, 0x4b, 0x03, 0x04, 0x00, 0xff, 0x7f, 0x80];
    final encoded = base64Encode(zipBytes);
    assembler.addMessage(jsonEncode({
      'kind': 'start',
      'id': 'export-zip',
      'fileName': 'coffee-beans.brewbeans.zip',
      'mimeType': 'application/zip',
      'totalChunks': 1,
    }));
    assembler.addMessage(jsonEncode({
      'kind': 'chunk',
      'id': 'export-zip',
      'index': 0,
      'data': encoded,
    }));

    final payload = assembler.addMessage(
      jsonEncode({'kind': 'end', 'id': 'export-zip'}),
    );

    expect(payload!.fileName, 'coffee-beans.brewbeans.zip');
    expect(payload.mimeType, 'application/zip');
    expect(payload.bytes, zipBytes);
  });
}
