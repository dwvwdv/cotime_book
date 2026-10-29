import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_constants.dart';
import '../config/theme.dart';

class RoomCodeInput extends StatelessWidget {
  final TextEditingController controller;
  final String? errorText;

  const RoomCodeInput({
    super.key,
    required this.controller,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLength: AppConstants.roomCodeLength,
      // Codes are Latin letters and digits only. A plain text field opens
      // whatever keyboard was last used, which for most of our readers is a
      // Chinese IME: letters go into a composing buffer and come out as
      // candidates. visiblePassword is the one input type both Android IMEs
      // and iOS (ASCII-capable) answer with an English layout.
      keyboardType: TextInputType.visiblePassword,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontFamily: AppTheme.serif,
        fontSize: 28,
        fontWeight: FontWeight.w700,
        letterSpacing: 10,
        color: AppTheme.ink,
      ),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
        UpperCaseTextFormatter(),
      ],
      decoration: InputDecoration(
        labelText: 'Room code',
        hintText: 'ABC234',
        hintStyle: const TextStyle(
          color: AppTheme.inkFaint,
          letterSpacing: 10,
        ),
        counterText: '',
        errorText: errorText,
      ),
    );
  }
}

class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}
