import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/announcement_service.dart';

final announcementServiceProvider = Provider<AnnouncementService>((ref) {
  return SupabaseAnnouncementService();
});
