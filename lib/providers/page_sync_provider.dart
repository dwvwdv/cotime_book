import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/page_info.dart';
import '../models/page_sync_state.dart';
import '../services/page_sync_service.dart';
import '../services/realtime_service.dart';

final pageSyncProvider = StateNotifierProvider<PageSyncNotifier, PageSyncState>(
  (ref) {
    return PageSyncNotifier();
  },
);

class PageSyncNotifier extends StateNotifier<PageSyncState> {
  PageSyncService? _service;
  StreamSubscription<PageSyncState>? _subscription;
  int _lifecycleGeneration = 0;

  void Function(PageTurnCommand command)? onExecuteTurn;
  void Function(SharedPosition position)? onPositionChanged;
  void Function(String requestId)? onTurnAbandoned;
  bool Function(SharedPosition position)? onAdBreak;
  void Function()? onAdHoldExpired;

  PageSyncNotifier() : super(const PageSyncState.idle());

  SharedPosition? get position => _service?.position;

  bool get isHoldingForAd => _service?.isHoldingForAd ?? false;

  Future<void> initialize({
    required RealtimeService realtimeService,
    required String currentUserId,
    required String currentNickname,
    required SharedPosition initialPosition,
  }) async {
    final generation = ++_lifecycleGeneration;
    await _stopResources(clearCallbacks: false);
    if (!mounted || generation != _lifecycleGeneration) return;
    state = const PageSyncState.idle();

    final service = PageSyncService(
      transport: RealtimePageSyncTransport(realtimeService),
      currentUserId: currentUserId,
      currentNickname: currentNickname,
      initialPosition: initialPosition,
    );
    _service = service;
    service.onExecuteTurn = (command) => onExecuteTurn?.call(command);
    service.onPositionChanged = (position) => onPositionChanged?.call(position);
    service.onTurnAbandoned = (requestId) => onTurnAbandoned?.call(requestId);
    service.onAdBreak = (position) => onAdBreak?.call(position) ?? false;
    service.onAdHoldExpired = () => onAdHoldExpired?.call();

    _subscription = service.stateStream.listen((syncState) {
      if (mounted && identical(_service, service)) state = syncState;
    });
    service.initialize();
  }

  void setViewerReady(bool isReady) => _service?.setViewerReady(isReady);

  Future<bool> requestPageTurn({required PageTurnDirection direction}) async {
    return await _service?.requestPageTurn(direction: direction) ?? false;
  }

  Future<bool> requestJump({required String targetCfi, PageInfo? label}) async {
    return await _service?.requestJump(targetCfi: targetCfi, label: label) ??
        false;
  }

  Future<bool> confirmPageTurn() async {
    return await _service?.confirmPageTurn() ?? false;
  }

  Future<void> declinePageTurn() async {
    await _service?.declinePageTurn();
  }

  SharedPosition? completeTurn(String requestId, String targetCfi) {
    return _service?.completeTurn(requestId, targetCfi);
  }

  void abandonTurn(String requestId, {String? reason}) =>
      _service?.abandonTurn(requestId, reason: reason);

  void endAdBreak() => _service?.endAdBreak();

  Future<void> stop({bool clearCallbacks = true}) async {
    _lifecycleGeneration++;
    try {
      await _service?.leave();
    } catch (_) {
      // Leaving must not be held up by a failed withdrawal broadcast.
    }
    await _stopResources(clearCallbacks: clearCallbacks);
  }

  Future<void> _stopResources({required bool clearCallbacks}) async {
    final subscription = _subscription;
    final service = _service;
    _subscription = null;
    _service = null;
    await subscription?.cancel();
    await service?.dispose();
    if (clearCallbacks) {
      onExecuteTurn = null;
      onPositionChanged = null;
      onTurnAbandoned = null;
      onAdBreak = null;
      onAdHoldExpired = null;
    }
    if (mounted) state = const PageSyncState.idle();
  }

  @override
  void dispose() {
    _lifecycleGeneration++;
    unawaited(_subscription?.cancel());
    unawaited(_service?.dispose());
    _subscription = null;
    _service = null;
    onExecuteTurn = null;
    onPositionChanged = null;
    onTurnAbandoned = null;
    onAdBreak = null;
    onAdHoldExpired = null;
    super.dispose();
  }
}
