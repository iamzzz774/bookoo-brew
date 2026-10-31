// Standalone generator deliberately does not require package resolution.
// ignore_for_file: avoid_relative_lib_imports
import 'dart:io';
import '../lib/web_cloud_config.dart';

void main() {
  stdout.write(
    webCloudConfigReadScript(
      origin: 'https://coffee.chu3.top',
      token: 'document_nonce_123',
      requestId: 'request_456',
    ),
  );
}
