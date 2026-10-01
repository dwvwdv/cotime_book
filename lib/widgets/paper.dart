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

/// A bottom sheet that appears in one frame. It overlays the page instead of
/// dimming it: a translucent scrim dithers into gray noise on e-ink.
Future<T?> showPaperSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: AnimationStyle.noAnimation,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: builder(sheetContext),
      ),
    ),
  );
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

  const PaperNotice({
    super.key,
    required this.message,
    this.icon = Icons.error_outline,
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
        ],
      ),
    );
  }
}
