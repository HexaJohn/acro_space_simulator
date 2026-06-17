import 'package:flutter/material.dart';

/// Shared visual language for the menu/feature screens: a dark "mission control"
/// palette with cyan accents, used so every screen reads as one app.
class AppTheme {
  static const bg = Color(0xFF05080F);
  static const panel = Color(0xFF0E1622);
  static const panelLight = Color(0xFF16202E);
  static const accent = Color(0xFF4FC3F7); // cyan
  static const accent2 = Color(0xFF7FE0A0); // green
  static const warn = Color(0xFFFF8C66);
  static const danger = Color(0xFFFF6B6B);
  static const textDim = Color(0xFF8499AE);
  static const text = Color(0xFFD7E3F0);

  static const title = TextStyle(
    color: text,
    fontSize: 20,
    fontWeight: FontWeight.bold,
    letterSpacing: 1.5,
  );
  static const heading = TextStyle(
    color: accent,
    fontSize: 14,
    fontWeight: FontWeight.bold,
    letterSpacing: 1.2,
  );
  static const body = TextStyle(color: text, fontSize: 13);
  static const dim = TextStyle(color: textDim, fontSize: 12);
  static const mono = TextStyle(
    color: text,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// A bordered content panel used across screens.
  static BoxDecoration panelBox({Color? border}) => BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border ?? const Color(0xFF223247)),
      );

  /// Standard screen scaffold with a back button + title bar.
  static Widget scaffold({
    required BuildContext context,
    required String title,
    required Widget body,
    List<Widget>? actions,
    Color? accentColor,
  }) {
    final a = accentColor ?? accent;
    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: panel,
                border: Border(bottom: BorderSide(color: a, width: 2)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: text),
                    onPressed: () => Navigator.of(context).maybePop(),
                    tooltip: 'Back',
                  ),
                  const SizedBox(width: 4),
                  Text(title,
                      style: AppTheme.title.copyWith(color: a, fontSize: 16)),
                  const Spacer(),
                  if (actions != null) ...actions,
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}
