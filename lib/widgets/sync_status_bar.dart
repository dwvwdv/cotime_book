import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/page_sync_state.dart';

class SyncStatusBar extends StatelessWidget {
  /// Every state renders at exactly this height.
  ///
  /// The bar sits directly above the EPUB viewer, so any change in its height
  /// resizes the WebView, and epub.js answers a resize by re-paginating and
  /// reporting a new location. That relocation used to land in the middle of
  /// a page turn — the bar grows when a request starts and shrinks when it
  /// ends — and overwrote this reader's CFI with a freshly paginated one that
  /// no other reader shares, so its next request was rejected as stale.
  static const double height = 60;

  final PageSyncState syncState;
  final List<Map<String, dynamic>> onlineUsers;

  /// False while the room channel is being rebuilt.
  final bool isConnected;
  final VoidCallback? onConfirm;
  final VoidCallback? onDecline;

  /// Foreground and background, so the bar follows the reading theme (an
  /// inverted night page should not sit under a white bar).
  final Color ink;
  final Color paper;

  const SyncStatusBar({
    super.key,
    required this.syncState,
    required this.onlineUsers,
    this.isConnected = true,
    this.onConfirm,
    this.onDecline,
    this.ink = AppTheme.ink,
    this.paper = AppTheme.paper,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (syncState.errorMessage != null) {
      return _buildErrorBar(syncState.errorMessage!);
    }
    switch (syncState.status) {
      case SyncStatus.idle:
        return _buildIdleBar();
      case SyncStatus.requesting:
        return _buildRequestingBar();
      case SyncStatus.confirming:
        return _buildConfirmingBar();
      case SyncStatus.waiting:
        return _buildWaitingBar();
      case SyncStatus.turning:
        return _buildTurningBar();
    }
  }

  Widget _frame({required Widget child, bool inverted = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: inverted ? ink : paper,
        border: Border(
          bottom: BorderSide(color: ink, width: AppTheme.ruleWidth),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: child,
    );
  }

  TextStyle _text({bool bold = false, Color? color}) => TextStyle(
    color: color ?? ink,
    fontSize: 15,
    height: 1.25,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
  );

  Widget _buildIdleBar() {
    if (!isConnected) {
      // "0 readers ready" during a reconnect reads as everyone having left.
      return _frame(
        child: Row(
          children: [
            Icon(Icons.sync, size: 20, color: ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Reconnecting to the room...',
                style: _text(bold: true),
              ),
            ),
          ],
        ),
      );
    }
    final readyReaderCount = onlineUsers
        .where(
          (user) =>
              user['is_reading'] == true && user['reader_ready'] == true,
        )
        .map((user) => user['user_id'])
        .whereType<String>()
        .toSet()
        .length;
    return _frame(
      child: Row(
        children: [
          Icon(Icons.people_outline, size: 20, color: ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text('$readyReaderCount readers ready', style: _text()),
          ),
          Icon(Icons.check, size: 18, color: ink),
          const SizedBox(width: 4),
          Text('Synced', style: _text(bold: true)),
        ],
      ),
    );
  }

  Widget _buildErrorBar(String message) {
    // No red on e-ink: a heavy bar on the leading edge and bold type carry
    // the urgency instead.
    return Container(
      decoration: BoxDecoration(
        color: paper,
        border: Border(
          left: BorderSide(color: ink, width: 6),
          bottom: BorderSide(color: ink, width: AppTheme.heavyRuleWidth),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Icon(Icons.sync_problem, size: 22, color: ink),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: _text(bold: true),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestingBar() {
    final request = syncState.currentRequest;
    if (request == null) return _frame(child: const SizedBox.shrink());

    final pending = request.pendingUserIds;
    final pendingNames = _getUserNames(pending);

    return _frame(
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 20, color: ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Waiting for ${pendingNames.join(", ")}...',
              style: _text(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _CountBadge(
            label:
                '${request.validConfirmationCount}/${request.requiredUserIds.length}',
            ink: ink,
            paper: paper,
          ),
        ],
      ),
    );
  }

  Widget _buildConfirmingBar() {
    final request = syncState.currentRequest;
    if (request == null) return _frame(child: const SizedBox.shrink());

    final direction =
        request.direction == PageTurnDirection.next ? 'next' : 'previous';

    // The one state that needs this reader to act, so it is the one that
    // inverts: on a grayscale page, a solid bar is the loudest thing there is.
    return _frame(
      inverted: true,
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${request.requestedByNickname} wants to go to $direction page',
              style: _text(bold: true, color: paper),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: onDecline,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(64, 44),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                backgroundColor: ink,
                foregroundColor: paper,
                side: BorderSide(color: paper, width: AppTheme.ruleWidth),
              ),
              child: const Text('Wait'),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: onConfirm,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(72, 44),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                backgroundColor: paper,
                foregroundColor: ink,
                side: BorderSide(color: paper, width: AppTheme.ruleWidth),
              ),
              child: const Text('Turn'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingBar() {
    final request = syncState.currentRequest;
    if (request == null) return _frame(child: const SizedBox.shrink());

    return _frame(
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 20, color: ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Waiting for others to confirm... '
              '${request.validConfirmationCount}/${request.requiredUserIds.length}',
              style: _text(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurningBar() {
    return _frame(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 20, color: ink),
          const SizedBox(width: 8),
          Text('Turning page...', style: _text(bold: true)),
        ],
      ),
    );
  }

  List<String> _getUserNames(Set<String> userIds) {
    return userIds.map((id) {
      final user = onlineUsers.firstWhere(
        (u) => u['user_id'] == id,
        orElse: () => {'nickname': 'Unknown'},
      );
      return user['nickname'] as String? ?? 'Unknown';
    }).toList();
  }
}

class _CountBadge extends StatelessWidget {
  final String label;
  final Color ink;
  final Color paper;

  const _CountBadge({
    required this.label,
    required this.ink,
    required this.paper,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ink,
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: paper,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
