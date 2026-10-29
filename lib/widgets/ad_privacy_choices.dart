import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../providers/ads_provider.dart';
import 'paper.dart';
import '../l10n/l10n.dart';

/// Where the consent asked for on start can be changed (GH-58). Google
/// requires it wherever the answer is needed — the EEA, the UK and
/// Switzerland — and it has to be reachable from every flow that shows an
/// ad: the reader's page turns and the TXT tool's save. Nothing elsewhere.
class AdPrivacyChoices extends ConsumerWidget {
  /// Runs before Google's form opens, e.g. to close the dialog this is in.
  final VoidCallback? onOpen;

  const AdPrivacyChoices({super.key, this.onOpen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final consent = ref.watch(adConsentProvider);
    if (consent == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: consent.privacyOptionsRequired,
      builder: (context, required, _) {
        if (!required) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 24),
            SectionHeader(label: context.l10n.ads),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                onOpen?.call();
                unawaited(consent.showPrivacyOptions());
              },
              child: Text(context.l10n.adPrivacyChoices),
            ),
            const SizedBox(height: 8),
            Text(context.l10n.adPrivacyChoicesHint, style: AppTheme.caption),
          ],
        );
      },
    );
  }
}
