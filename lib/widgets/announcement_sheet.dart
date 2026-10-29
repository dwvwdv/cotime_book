import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/announcement.dart';
import '../services/announcement_service.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

/// Opens the announcements in a sheet.
Future<void> showAnnouncementSheet({
  required BuildContext context,
  required AnnouncementService announcements,
}) {
  return showPaperDialog<void>(
    context: context,
    builder: (sheetContext) => SizedBox(
      // A fixed height, so the sheet does not jump from one line of
      // "Loading..." to the full list: every resize is a refresh on e-ink.
      height: MediaQuery.of(sheetContext).size.height * 0.75,
      child: AnnouncementList(announcements: announcements),
    ),
  );
}

/// The announcements, newest first. Expands to the height it is given.
class AnnouncementList extends StatefulWidget {
  final AnnouncementService announcements;

  const AnnouncementList({super.key, required this.announcements});

  @override
  State<AnnouncementList> createState() => _AnnouncementListState();
}

class _AnnouncementListState extends State<AnnouncementList> {
  List<Announcement>? _announcements;
  String? _error;

  /// A retry must not be overwritten by the slower attempt it replaced.
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _announcements = null;
      _error = null;
    });
    try {
      final announcements = await widget.announcements.list();
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _announcements = announcements);
    } catch (error) {
      debugPrint('Unable to load the announcements: $error');
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = context.l10n.announcementsLoadFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(context.l10n.news, style: AppTheme.title),
        const SizedBox(height: 12),
        const Divider(thickness: AppTheme.heavyRuleWidth),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return ListView(
        padding: const EdgeInsets.only(top: 12),
        children: [
          PaperNotice(message: _error!, icon: Icons.wifi_off),
          const SizedBox(height: 8),
          TextButton(onPressed: _load, child: Text(context.l10n.tryAgain)),
        ],
      );
    }
    final announcements = _announcements;
    if (announcements == null) {
      // Text, not a spinner: e-ink.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(context.l10n.loading, style: AppTheme.body),
      );
    }
    if (announcements.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Text(context.l10n.noAnnouncements, style: AppTheme.body),
      );
    }
    return ListView.separated(
      itemCount: announcements.length,
      separatorBuilder: (_, _) => const Divider(),
      itemBuilder: (context, index) =>
          _AnnouncementEntry(announcement: announcements[index]),
    );
  }
}

class _AnnouncementEntry extends StatelessWidget {
  final Announcement announcement;

  const _AnnouncementEntry({required this.announcement});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            announcement.title,
            style: AppTheme.body.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(announcement.dateLabel, style: AppTheme.caption),
          if (announcement.content.isNotEmpty) ...[
            const SizedBox(height: 10),
            SelectableText(
              announcement.content,
              style: AppTheme.body.copyWith(height: 1.5),
            ),
          ],
        ],
      ),
    );
  }
}
