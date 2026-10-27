import 'package:flutter/material.dart';
import '../config/theme.dart';

/// Shows a message without the slide-in, which on e-ink is a dozen partial
/// refreshes and a ghost of the bar left behind on the way out.
void showPaperMessage(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: duration),
    snackBarAnimationStyle: AnimationStyle.noAnimation,
  );
}

/// A dialog that floats over the page, appears in one frame, and closes
/// from a button in its corner.
///
/// Not a bottom sheet: a tall sheet runs up under the status bar, which
/// puts its close button where nobody can tap it, and a swipe down — how a
/// phone closes a sheet — is registered late and coarsely on an e-reader's
/// panel. Nothing dims the page behind it (a translucent scrim dithers into
/// gray noise on e-ink); its heavy frame sets it apart instead. A tap
/// outside it closes it too, and so does Back.
///
/// It keeps clear of the system bars and of the keyboard, so what it holds
/// only has to fit the height it is given: a list or a form scrolls in it.
Future<T?> showPaperDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: const Color(0x00000000),
    transitionDuration: Duration.zero,
    pageBuilder: (dialogContext, _, _) => SafeArea(
      child: PaperDialog(child: Builder(builder: builder)),
    ),
  );
}

/// The frame [showPaperDialog] puts its content in.
class PaperDialog extends StatelessWidget {
  /// Big enough to hit with a thumb on a panel that registers taps loosely.
  static const double closeButtonSize = 56;

  final Widget child;

  const PaperDialog({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      // Moves out of the keyboard's way in one step: no animation on e-ink.
      insetAnimationDuration: Duration.zero,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Close',
                iconSize: 30,
                style: IconButton.styleFrom(
                  minimumSize: const Size.square(closeButtonSize),
                ),
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
            // Whatever height the button leaves: content that sizes itself
            // to a share of the screen must not push the button off it.
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// An all-caps label with a rule under it, the way a book sets a part title.
class SectionHeader extends StatelessWidget {
  final String label;
  final Widget? trailing;

  const SectionHeader({super.key, required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: const BoxDecoration(border: Border(bottom: AppTheme.rule)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(child: Text(label.toUpperCase(), style: AppTheme.overline)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// A boxed note for errors and warnings. E-ink has no red, so urgency is a
/// heavy left bar and bold text rather than a colour.
class PaperNotice extends StatelessWidget {
  final String message;
  final IconData icon;

  /// Shows a close button when set.
  final VoidCallback? onDismiss;

  const PaperNotice({
    super.key,
    required this.message,
    this.icon = Icons.error_outline,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: AppTheme.ink, width: 5),
          top: AppTheme.rule,
          right: AppTheme.rule,
          bottom: AppTheme.rule,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: AppTheme.ink,
              ),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              onPressed: onDismiss,
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 24),
            ),
        ],
      ),
    );
  }
}
