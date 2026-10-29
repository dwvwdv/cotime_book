import 'package:flutter/material.dart';

import '../config/app_constants.dart';
import '../config/theme.dart';
import '../l10n/l10n.dart';

/// The app's name as the home screen opens with it: 頁間 as a seal beside the
/// English name, the way a book's title page carries the press's mark.
///
/// The two names used to be stacked as two headings, a 36px bold 頁間 over a
/// bold CoTime Book, and read as two titles competing for one line. As a seal
/// 頁間 is the mark rather than a second title, and stays the first thing
/// on the page. White on black is the one emphasis Paper has besides weight,
/// so it holds on a grayscale panel.
class Masthead extends StatelessWidget {
  const Masthead({super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const NameSeal(),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                AppConstants.appNameEnglish,
                style: TextStyle(
                  fontFamily: AppTheme.serif,
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                  color: AppTheme.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                context.l10n.mastheadTagline,
                style: const TextStyle(
                  fontFamily: AppTheme.serif,
                  fontStyle: FontStyle.italic,
                  fontSize: 17,
                  color: AppTheme.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 頁間 set top to bottom in a square-cornered seal: ink ground, paper
/// characters, and a paper rule just inside the edge like a carved border.
/// Read out as one word.
class NameSeal extends StatelessWidget {
  const NameSeal({super.key});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: AppConstants.appName,
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: AppTheme.ink,
          borderRadius: BorderRadius.circular(AppTheme.radius),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(
              color: AppTheme.paper,
              width: AppTheme.ruleWidth,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final character in AppConstants.appName.characters)
                Text(
                  character,
                  style: const TextStyle(
                    fontFamily: AppTheme.serif,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                    color: AppTheme.paper,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
