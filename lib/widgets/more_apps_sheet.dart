import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../providers/external_link_provider.dart';
import 'paper.dart';

/// An app by the same maker, shown under More Apps on the home screen.
class MakerApp {
  final String name;
  final String subtitle;
  final String description;
  final Uri storeUrl;

  const MakerApp({
    required this.name,
    required this.subtitle,
    required this.description,
    required this.storeUrl,
  });
}

/// The https link rather than `market://`: it opens Google Play where there
/// is one and a browser where there is not, as on many e-readers.
final List<MakerApp> makerApps = [
  MakerApp(
    name: '無感記帳',
    subtitle: 'Seamless Track · Android',
    description:
        'Bookkeeping that keeps itself: it reads the payment notifications '
        'on your phone and records each amount for you. Your accounts stay '
        'on your device.',
    storeUrl: Uri.parse(
      'https://play.google.com/store/apps/details'
      '?id=com.lazyrhythm.seamless_track',
    ),
  ),
];

/// Opens the maker's other apps in a dialog.
Future<void> showMoreAppsSheet({
  required BuildContext context,
  required OpenExternalLink openLink,
}) {
  return showPaperDialog<void>(
    context: context,
    builder: (_) => MoreAppsList(apps: makerApps, openLink: openLink),
  );
}

class MoreAppsList extends StatelessWidget {
  final List<MakerApp> apps;
  final OpenExternalLink openLink;

  const MoreAppsList({super.key, required this.apps, required this.openLink});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('More Apps', style: AppTheme.title),
        const SizedBox(height: 12),
        const Divider(thickness: AppTheme.heavyRuleWidth),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: apps.length,
            separatorBuilder: (_, _) => const Divider(),
            itemBuilder: (_, index) =>
                _MakerAppEntry(app: apps[index], openLink: openLink),
          ),
        ),
      ],
    );
  }
}

class _MakerAppEntry extends StatefulWidget {
  final MakerApp app;
  final OpenExternalLink openLink;

  const _MakerAppEntry({required this.app, required this.openLink});

  @override
  State<_MakerAppEntry> createState() => _MakerAppEntryState();
}

class _MakerAppEntryState extends State<_MakerAppEntry> {
  bool _opening = false;

  /// Set when the link had nowhere to go. Shown as text to copy, not as a
  /// passing message: on a device with no store and no browser, the link is
  /// the only way to get to the app.
  bool _couldNotOpen = false;

  Future<void> _open() async {
    setState(() {
      _opening = true;
      _couldNotOpen = false;
    });
    final opened = await widget.openLink(widget.app.storeUrl);
    if (!mounted) return;
    setState(() {
      _opening = false;
      _couldNotOpen = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            app.name,
            style: AppTheme.body.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(app.subtitle, style: AppTheme.caption),
          const SizedBox(height: 10),
          Text(app.description, style: AppTheme.body.copyWith(height: 1.5)),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: _opening ? null : _open,
            child: Text(_opening ? 'Opening...' : 'Get it on Google Play'),
          ),
          if (_couldNotOpen) ...[
            const SizedBox(height: 12),
            const PaperNotice(
              message:
                  'Google Play could not be opened on this device. '
                  'The link:',
              icon: Icons.link_off,
            ),
            const SizedBox(height: 6),
            SelectableText(app.storeUrl.toString(), style: AppTheme.caption),
          ],
        ],
      ),
    );
  }
}
