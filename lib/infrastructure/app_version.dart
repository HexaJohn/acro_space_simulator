import 'package:package_info_plus/package_info_plus.dart';

/// App version label shown in the UI (e.g. 'v0.3.0+175'), sourced from the
/// pubspec version at runtime. Loaded once by [loadAppVersion] in main(); empty
/// until then (and in tests, which don't call main()).
String appVersionLabel = '';

Future<void> loadAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    appVersionLabel = 'v${info.version}+${info.buildNumber}';
  } catch (_) {
    // PackageInfo can fail in unusual embeddings; leave the label empty rather
    // than block startup.
  }
}
