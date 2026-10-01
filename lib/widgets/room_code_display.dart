import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/theme.dart';
import 'paper.dart';

/// The room code set in separate cells, so it can be read aloud or copied by
/// hand across the room without miscounting characters.
class RoomCodeDisplay extends StatelessWidget {
  final String code;

  const RoomCodeDisplay({super.key, required this.code});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Room code $code. Tap to copy.',
      child: InkWell(
        onTap: () {
          Clipboard.setData(ClipboardData(text: code));
          showPaperMessage(
            context,
            'Room code copied',
            duration: const Duration(seconds: 2),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < code.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      Container(
                        width: 42,
                        height: 54,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: AppTheme.ink,
                            width: AppTheme.ruleWidth,
                          ),
                          borderRadius: BorderRadius.circular(AppTheme.radius),
                        ),
                        child: Text(
                          code[i],
                          style: const TextStyle(
                            fontFamily: AppTheme.serif,
                            fontSize: 30,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.ink,
                            height: 1,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.copy, size: 16, color: AppTheme.inkMuted),
                  SizedBox(width: 6),
                  Text('Tap to copy', style: AppTheme.caption),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
