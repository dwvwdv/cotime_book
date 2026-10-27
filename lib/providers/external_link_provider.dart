import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens [uri] in another app. Answers false when nothing on the device
/// could open it.
typedef OpenExternalLink = Future<bool> Function(Uri uri);

final externalLinkProvider = Provider<OpenExternalLink>((ref) {
  return openExternalLink;
});

/// Hands [uri] to the system, outside this app: a Play Store link opens in
/// Google Play, or in a browser where there is none.
Future<bool> openExternalLink(Uri uri) async {
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (error) {
    // Many e-readers have neither Google Play nor a browser: Android has no
    // app for the link and the plugin throws instead of answering false.
    debugPrint('Unable to open $uri: $error');
    return false;
  }
}
