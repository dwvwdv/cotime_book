import 'package:flutter/material.dart';
import '../config/theme.dart';

/// A monogram. Online members are solid ink, offline members are an outline:
/// the difference survives a grayscale panel, which a coloured dot does not.
class UserAvatar extends StatelessWidget {
  final String nickname;
  final double size;
  final bool isOnline;

  const UserAvatar({
    super.key,
    required this.nickname,
    this.size = 44,
    this.isOnline = true,
  });

  @override
  Widget build(BuildContext context) {
    final initials = nickname.isNotEmpty ? nickname[0].toUpperCase() : '?';

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isOnline ? AppTheme.ink : AppTheme.paper,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.ink, width: AppTheme.ruleWidth),
      ),
      alignment: Alignment.center,
      child: Text(
        initials,
        style: TextStyle(
          fontFamily: AppTheme.serif,
          color: isOnline ? AppTheme.paper : AppTheme.ink,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.45,
          height: 1,
        ),
      ),
    );
  }
}
