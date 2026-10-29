import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/transfer_state.dart';
import '../l10n/l10n.dart';

class TransferProgressWidget extends StatelessWidget {
  /// Progress is drawn in this many whole steps.
  ///
  /// Chunks arrive every ~100ms. A continuous bar repaints on each one, which
  /// on e-ink is a refresh every 100ms for the whole transfer. Ten cells
  /// change at most ten times.
  static const int segments = 10;

  final TransferState transferState;

  const TransferProgressWidget({
    super.key,
    required this.transferState,
  });

  @override
  Widget build(BuildContext context) {
    if (transferState.status == TransferStatus.idle) {
      return const SizedBox.shrink();
    }

    final filled = (transferState.progress.clamp(0.0, 1.0) * segments).floor();
    final showProgress = transferState.status == TransferStatus.transferring;
    final l10n = context.l10n;
    final detail = _detailText(l10n);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.ink, width: AppTheme.ruleWidth),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(_icon, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusText(l10n),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              if (showProgress)
                Text(
                  '${filled * segments}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppTheme.ink,
                  ),
                ),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < segments; i++) ...[
                  if (i > 0) const SizedBox(width: 4),
                  Expanded(
                    child: Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: i < filled ? AppTheme.ink : AppTheme.paper,
                        border: Border.all(color: AppTheme.ink, width: 1),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
          if (detail != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(detail, style: AppTheme.caption),
            ),
        ],
      ),
    );
  }

  IconData get _icon {
    switch (transferState.status) {
      case TransferStatus.transferring:
        return transferState.isSending ? Icons.upload : Icons.download;
      case TransferStatus.completed:
        return Icons.check_circle_outline;
      case TransferStatus.waiting:
      case TransferStatus.idle:
        return Icons.hourglass_top;
    }
  }

  String _statusText(AppLocalizations l10n) {
    switch (transferState.status) {
      case TransferStatus.idle:
        return '';
      case TransferStatus.waiting:
        return l10n.waitingForTheBook;
      case TransferStatus.transferring:
        return transferState.isSending ? l10n.sendingBook : l10n.receivingBook;
      case TransferStatus.completed:
        return transferState.isSending ? l10n.bookSent : l10n.bookReceived;
    }
  }

  /// The second line. A receive never fails for good — it keeps asking — so
  /// this says what it is doing rather than reporting an error.
  String? _detailText(AppLocalizations l10n) {
    final message = transferState.message;
    if (message != null) return message;
    if (transferState.status == TransferStatus.completed) {
      return transferState.isSending
          ? l10n.missedPartsWillAsk
          : l10n.readyToReadSentence;
    }
    return null;
  }
}
