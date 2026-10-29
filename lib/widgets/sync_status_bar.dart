import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/page_sync_state.dart';
import '../l10n/l10n.dart';

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

  /// Opens the room's member list. The whole bar is the button, except
  /// while it asks this reader to answer a request and holds buttons of its
  /// own.
  final VoidCallback? onShowMembers;

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
    this.onShowMembers,
    this.ink = AppTheme.ink,
    this.paper = AppTheme.paper,
  });

  @override
  Widget build(BuildContext context) {
    final onShowMembers = this.onShowMembers;
    final content = _buildContent(context.l10n);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: onShowMembers == null || syncState.status == SyncStatus.confirming
          ? content
          : Semantics(
              button: true,
              label: context.l10n.roomMembers,
              // No ripple: e-ink.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onShowMembers,
                child: content,
              ),
            ),
    );
  }

  Widget _buildContent(AppLocalizations l10n) {
    if (syncState.errorMessage != null) {
      return _buildErrorBar(syncState.errorMessage!);
    }
    switch (syncState.status) {
      case SyncStatus.idle:
        return _buildIdleBar(l10n);
      case SyncStatus.requesting:
        return _buildRequestingBar(l10n);
      case SyncStatus.confirming:
        return _buildConfirmingBar(l10n);
      case SyncStatus.waiting:
        return _buildWaitingBar(l10n);
      case SyncStatus.turning:
        return _buildTurningBar(l10n);
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

  Widget _buildIdleBar(AppLocalizations l10n) {
    if (!isConnected) {
      // "0 readers ready" during a reconnect reads as everyone having left.
      return _frame(
        child: Row(
          children: [
            Icon(Icons.sync, size: 20, color: ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(l10n.reconnectingToRoom, style: _text(bold: true)),
            ),
          ],
        ),
      );
    }
    final reconnecting = syncState.readersReconnecting;
    if (reconnecting.isNotEmpty) {
      // Not silent: turns are held until they are back, and the bar says why.
      return _frame(
        child: Row(
          children: [
            Icon(Icons.hourglass_top, size: 20, color: ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.waitingForReconnect(reconnecting.join(l10n.listSeparator)),
                style: _text(bold: true),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    if (syncState.adBreak) {
      final inAd = syncState.readersInAd;
      return _frame(
        child: Row(
          children: [
            Icon(Icons.hourglass_top, size: 20, color: ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                inAd.isEmpty
                    ? l10n.adBreakEllipsis
                    : l10n.adBreakWaitingFor(inAd.join(l10n.listSeparator)),
                style: _text(bold: true),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }
    final readyReaderCount = onlineUsers
        .where(
          (user) => user['is_reading'] == true && user['reader_ready'] == true,
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
            child: Text(l10n.readersReady(readyReaderCount), style: _text()),
          ),
          Icon(Icons.check, size: 18, color: ink),
          const SizedBox(width: 4),
          Text(l10n.synced, style: _text(bold: true)),
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

  Widget _buildRequestingBar(AppLocalizations l10n) {
    final request = syncState.currentRequest;
    if (request == null) return _frame(child: const SizedBox.shrink());

    final pending = request.pendingUserIds;
    final pendingNames = _getUserNames(pending, l10n);

    return _frame(
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 20, color: ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.waitingForNames(pendingNames.join(l10n.listSeparator)),
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

  Widget _buildConfirmingBar(AppLocalizations l10n) {
    final request = syncState.currentRequest;
    if (request == null) return _frame(child: const SizedBox.shrink());

    // The one state that needs this reader to act, so it is the one that
    // inverts: on a grayscale page, a solid bar is the loudest thing there is.
    return _frame(
      inverted: true,
      child: Row(
        children: [
          Expanded(
            child: Text(
              describeRequest(request, l10n: l10n),
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
              child: Text(l10n.wait),
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
              child: Text(request.isJump ? l10n.go : l10n.turn),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingBar(AppLocalizations l10n) {
    final request = syncState.currentRequest;
    if (request == null) return _frame(child: const SizedBox.shrink());

    return _frame(
      child: Row(
        children: [
          Icon(Icons.hourglass_top, size: 20, color: ink),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.waitingForOthersToConfirm(
                request.validConfirmationCount,
                request.requiredUserIds.length,
              ),
              style: _text(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTurningBar(AppLocalizations l10n) {
    return _frame(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.check_circle_outline, size: 20, color: ink),
          const SizedBox(width: 8),
          Text(
            syncState.currentRequest?.isJump == true
                ? l10n.jumpingToPage
                : l10n.turningPage,
            style: _text(bold: true),
          ),
        ],
      ),
    );
  }

  List<String> _getUserNames(Set<String> userIds, AppLocalizations l10n) {
    return userIds.map((id) {
      final user = onlineUsers.firstWhere(
        (u) => u['user_id'] == id,
        orElse: () => const {},
      );
      return user['nickname'] as String? ?? l10n.unknownMember;
    }).toList();
  }
}

/// What [request] asks this reader to agree to, in words.
String describeRequest(PageTurnRequest request, {AppLocalizations? l10n}) {
  final strings = l10n ?? appStrings;
  final who = request.requestedByNickname;
  switch (request.direction) {
    case PageTurnDirection.next:
      return strings.wantsNextPage(who);
    case PageTurnDirection.previous:
      return strings.wantsPreviousPage(who);
    case PageTurnDirection.jump:
      final target = request.targetLabel;
      if (target == null) return strings.wantsJumpElsewhere(who);
      final progress = target.progressLabel;
      return progress == null
          ? strings.wantsJumpToPage(who, target.pageLabel)
          : strings.wantsJumpToPageWithProgress(
              who,
              target.pageLabel,
              progress,
            );
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
