import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const kBg = Color(0xFFFFE3E3); // page background in the mockup
const kPink = Color(0xFFE23B83); // buttons
const kPlum = Color(0xFF8A0F4E); // titles, icons
const kPanel = Color(0xFFD9D9D9); // grey "Foto Wajah" box
const kIconColor = Color(0xFF881246); // every SVG icon is drawn in this colour (#881246)

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kPink, primary: kPink, surface: kBg);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    // every AppBar back button (Sign In, Sign Up, Encrypt photo, ...) uses assets/icons/back.svg
    actionIconTheme: ActionIconThemeData(
      backButtonIconBuilder: (_) => const SvgIcon('back', size: 28, fallback: Icons.arrow_back),
    ),
    appBarTheme: const AppBarTheme(backgroundColor: kBg, foregroundColor: kPlum, elevation: 0),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kPink,
        foregroundColor: Colors.white,
        minimumSize: const Size(96, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(foregroundColor: kPlum)),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withOpacity(0.7),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide.none),
    ),
  );
}

/// Your logo. Replace assets/images/logo.png with the real export from Figma (transparent PNG, ~600 px tall).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.height = 200});
  final double height;
  @override
  Widget build(BuildContext context) => Image.asset('assets/images/logo.png',
      height: height,
      errorBuilder: (_, e, ___) {
        debugPrint('Logo failed to load: $e');
        return Icon(Icons.face_retouching_natural, size: height * 0.6, color: kPlum);
      });
}

/// Set to false if your exported SVGs are only the glyph (no circle around them): the app then draws the ring itself.
const bool kSvgHasRing = false;

/// One of your SVG icons from assets/icons/ (delete, flip, profile, search-bug, camera).
class SvgIcon extends StatelessWidget {
  const SvgIcon(this.name, {super.key, this.size = 64, this.fallback = Icons.broken_image_outlined});
  final String name;
  final double size;
  final IconData fallback;
  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        'assets/icons/$name.svg',
        width: size,
        height: size,
        colorFilter: const ColorFilter.mode(kIconColor, BlendMode.srcIn), // recolours every opaque pixel
        // a missing or invalid file shows a plain pink square and prints the reason, instead of breaking the screen
        errorBuilder: (_, e, __) {
          debugPrint('Icon "$name" failed to load: $e');
          return Icon(fallback, size: size * 0.6, color: kPink);
        },
      );
}

/// Round icon + caption, as on the dashboard. Give [svg] (file name without .svg) or a Material [icon].
class IconAction extends StatelessWidget {
  const IconAction({super.key, this.svg, this.icon, required this.label, required this.onTap});
  final String? svg;
  final IconData? icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final ring = svg == null || !kSvgHasRing;
    final glyph = svg != null ? SvgIcon(svg!, size: ring ? 32 : 64) : Icon(icon, color: kPink, size: 30);
    return InkResponse(
      onTap: onTap,
      radius: 48,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ring
            ? Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kPlum, width: 3), color: kBg),
                child: Center(child: glyph))
            : glyph,
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(color: kPlum, fontSize: 15)),
      ]),
    );
  }
}
