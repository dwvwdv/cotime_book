import 'package:flutter/material.dart';

import '../models/page_info.dart';

/// The page in its chapter, and how far into the book: "3 / 12" over "45%".
///
/// One width whatever it says, so the buttons beside it never move as the
/// numbers grow.
class PageCounter extends StatelessWidget {
  static const double width = 72;

  final PageInfo? info;
  final Color ink;

  const PageCounter({super.key, required this.info, required this.ink});

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    final progress = info?.progressLabel;
    return SizedBox(
      width: width,
      child: info == null
          ? null
          : Semantics(
              label:
                  'Page ${info.page} of ${info.pages} in this chapter'
                  '${progress == null ? '' : ', $progress of the book'}',
              excludeSemantics: true,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      info.pageLabel,
                      style: TextStyle(
                        color: ink,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (progress != null)
                    Text(progress, style: TextStyle(color: ink, fontSize: 13)),
                ],
              ),
            ),
    );
  }
}
