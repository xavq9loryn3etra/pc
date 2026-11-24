import 'dart:math' as math;

import 'package:flutter/cupertino.dart' show CupertinoPageRoute;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'floating_bottom_nav_bar.dart';
import 'glass_blur.dart';
import 'screen_scaffold.dart';
import 'screen_shade.dart';

/// The pieces Settings and its pages are built from, grouped like Apple's
/// settings: each section's rows on one frosted card, a short note under
/// it.

/// A section's name above its card, in small capitals.
class SettingsSectionLabel extends StatelessWidget {
  final String text;
  final double topPadding;

  const SettingsSectionLabel(this.text, {super.key, this.topPadding = 24});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // In line with the rows' content, inside their card.
      padding: EdgeInsets.fromLTRB(32, topPadding, 16, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white38,
          fontSize: 12,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// A short note under a card, or between parts of a page.
class SettingsNote extends StatelessWidget {
  final String text;
  final Color color;

  const SettingsNote(this.text, {super.key, this.color = Colors.white54});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 16, 0),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12.5, height: 1.35),
      ),
    );
  }
}

/// One section's rows on a rounded card, divided by hairlines, with an
/// optional short note under it.
class SettingsGroup extends StatelessWidget {
  final List<Widget> children;
  final String? footnote;

  const SettingsGroup({super.key, required this.children, this.footnote});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsCard(
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  // From the rows' text, not their icon, as on iOS.
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: SettingsRow.textInset,
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                children[i],
              ],
            ],
          ),
        ),
        if (footnote != null) SettingsNote(footnote!),
      ],
    );
  }
}

/// A frosted glass card, as the start screen's mode panel and the tab
/// bar: the glass tint and its light edge, over the tab's glow — no live
/// blur of its own, which re-blurred every card on every frame of a
/// scroll.
class SettingsCard extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;

  const SettingsCard({
    super.key,
    required this.child,
    this.radius = 20,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      // A phone's margins in a wide window's side column too, as Ask's.
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: kGlassTint,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: kGlassEdge),
        ),
        clipBehavior: Clip.antiAlias,
        child: padding == null ? child : Padding(padding: padding!, child: child),
      ),
    );
  }
}

/// A row on a [SettingsGroup] card: an icon, a title (and a line under
/// it, if [subtitle]) and, optionally, a control or value at its end.
class SettingsRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? subtitleColor;
  final Color titleColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const SettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.subtitleColor,
    this.titleColor = Colors.white,
    this.trailing,
    this.onTap,
  });

  /// Where the title starts: the divider between rows lines up with it.
  static const double textInset = 16 + 22 + 14;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      mouseCursor: onTap == null
          ? SystemMouseCursors.basic
          : WidgetStateMouseCursor.clickable,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Icon(icon, color: Colors.white70, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: subtitle == null ? null : 1,
                      overflow: subtitle == null ? null : TextOverflow.ellipsis,
                      style: TextStyle(color: titleColor, fontSize: 15),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: subtitleColor ?? Colors.white54,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A row's end that opens another page: an optional value, and a chevron.
class SettingsChevron extends StatelessWidget {
  final String? value;
  final Color valueColor;

  const SettingsChevron({super.key, this.value, this.valueColor = Colors.white54});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null)
          Text(value!, style: TextStyle(color: valueColor, fontSize: 15)),
        const Icon(Icons.chevron_right_rounded, color: Colors.white38, size: 20),
      ],
    );
  }
}

/// A setting's row with its on/off switch; tapping anywhere on the row
/// flips it.
class SettingsSwitchRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final ValueListenable<bool> value;
  final ValueChanged<bool> onChanged;

  const SettingsSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: value,
      builder: (context, on, _) => SettingsRow(
        icon: icon,
        title: title,
        onTap: () => onChanged(!on),
        trailing: GlassSwitch(value: on, onChanged: onChanged),
      ),
    );
  }
}

/// Opens [page] (one of Settings' own pages) over Settings, sliding in as
/// a title's page does — in the side column, on a wide window.
Future<void> openSettingsPage(BuildContext context, Widget page) =>
    Navigator.of(context).push(CupertinoPageRoute<void>(builder: (_) => page));

/// One of Settings' own pages (Sync, Gemini key): a back button and its
/// title at the top, over the Settings tab's glow, and [children] in a
/// column at a readable width.
class SettingsPage extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const SettingsPage({super.key, required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return ScreenScaffold(
      // Always shown, even in a wide window's side column (where Settings'
      // own title is left out): it holds the way back.
      titleIsLabel: false,
      title: Text(title),
      leading: Padding(
        padding: const EdgeInsets.only(left: 12),
        child: Center(
          child: GlassCircleButton(
            icon: GlassCircleButton.backIcon,
            iconSize: GlassCircleButton.backIconSize,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ),
      ),
      leadingWidth: 64,
      bottomNavTab: BottomNavTab.settings,
      glow: TabGlow.forMode,
      // Settings' glow is already showing: it doesn't bloom again here.
      glowBlooms: false,
      body: (context, isDesktop, padding) {
        final side = math.max(0.0, (MediaQuery.sizeOf(context).width - 720) / 2);
        return ListView(
          padding: padding.copyWith(
            top: SideColumnScope.inColumn(context) ? 76 : 100,
            left: side,
            right: side,
            // 16 at the side column's foot, as at its sides.
            bottom: padding.bottom +
                (SideColumnScope.inColumn(context) ? 16 : 24),
          ),
          children: children,
        );
      },
    );
  }
}
