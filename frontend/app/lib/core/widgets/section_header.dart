import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// A standard section header displaying a title, an optional count badge
/// (e.g. "Friends (5)"), and an optional trailing action widget (e.g. "Invite").
class SectionHeader extends StatelessWidget {
  final String title;
  final int? count;
  final Widget? trailing;
  final TextStyle? style;
  final EdgeInsetsGeometry padding;

  const SectionHeader({
    super.key,
    required this.title,
    this.count,
    this.trailing,
    this.style,
    this.padding = AppDimens.sectionHeaderPadding,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle = style ?? theme.textTheme.titleMedium;
    final headerText = count == null ? title : '$title ($count)';

    final titleWidget = Text(headerText, style: textStyle);
    final trailingWidget = trailing;

    if (trailingWidget == null) {
      return Padding(
        padding: padding,
        child: titleWidget,
      );
    }

    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(child: titleWidget),
          trailingWidget,
        ],
      ),
    );
  }
}
