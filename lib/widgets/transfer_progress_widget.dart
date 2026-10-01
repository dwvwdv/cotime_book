import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/transfer_state.dart';

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
    if (!transferState.isActive && transferState.status != TransferStatus.completed) {
      return const SizedBox.shrink();
    }

    final filled = (transferState.progress.clamp(0.0, 1.0) * segments).floor();

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
                  _statusText,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppTheme.ink,
                  ),
                ),
              ),
              if (transferState.isActive)
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
          if (transferState.isActive) ...[
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
          if (transferState.status == TransferStatus.completed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Book received successfully!',
                style: AppTheme.caption,
              ),
            ),
          if (transferState.status == TransferStatus.failed &&
              transferState.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                transferState.errorMessage!,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.ink,
                ),
              ),
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
      case TransferStatus.failed:
        return Icons.error_outline;
      default:
        return Icons.hourglass_top;
    }
  }

  String get _statusText {
    switch (transferState.status) {
      case TransferStatus.idle:
        return 'Idle';
      case TransferStatus.offering:
        return 'Offering...';
      case TransferStatus.accepting:
        return 'Accepting...';
      case TransferStatus.transferring:
        return transferState.isSending ? 'Sending book...' : 'Receiving book...';
      case TransferStatus.completed:
        return 'Transfer complete';
      case TransferStatus.failed:
        return 'Transfer failed';
    }
  }
}
