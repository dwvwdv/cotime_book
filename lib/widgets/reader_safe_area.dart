import 'package:flutter/widgets.dart';

/// The reader's safe area: the same size with the keyboard up or down.
///
/// While the keyboard is up, Flutter reports the bottom system padding (the
/// navigation bar) as 0, since the keyboard covers it. A plain [SafeArea]
/// then grows the viewer by that much, which is a new `page_fit` and a new
/// page for the whole room (issue #20) — and lays the jump preview out
/// again, taking the focus from the page box being typed in, which closes
/// the keyboard and shrinks it back, again and again. The bottom inset is
/// kept at the navigation bar's whatever the keyboard does.
class ReaderSafeArea extends StatelessWidget {
  final Widget child;

  const ReaderSafeArea({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(maintainBottomViewPadding: true, child: child);
  }
}
