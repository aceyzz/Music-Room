import 'package:flutter/material.dart';

import 'package:app/core/models/event/event_settings.dart';
import 'package:app/core/theme/app_dimens.dart';
import 'package:app/core/widgets/fitted_segment_label.dart';

/// Settings section allowing the host to configure who can discover the event.
class EventVisibilitySection extends StatelessWidget {
  final EventVisibility visibility;
  final bool enabled;
  final ValueChanged<EventVisibility> onChanged;

  const EventVisibilitySection({
    super.key,
    required this.visibility,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Who can find it', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppDimens.spacingXS),
        SegmentedButton<EventVisibility>(
          segments: [
            for (final v in EventVisibility.values)
              ButtonSegment(value: v, label: FittedSegmentLabel(v.label)),
          ],
          selected: {visibility},
          onSelectionChanged: enabled ? (picked) => onChanged(picked.single) : null,
        ),
        const SizedBox(height: AppDimens.spacingXXS),
        Text(visibility.description, style: hint),
      ],
    );
  }
}
