import 'package:flutter/material.dart';

import 'package:app/core/theme/app_dimens.dart';

/// The frame every single-form page shares (sign in, sign up, reset, verify):
/// a narrow, centred, scrollable column, so a form reads the same on a phone
/// and on a desktop window.
///
/// Pass [formKey] to wrap the column in a [Form]; leave it null for a page
/// that only shows text and buttons.
class FormPage extends StatelessWidget {
  final GlobalKey<FormState>? formKey;
  final List<Widget> children;
  final double maxWidth;

  /// Optional, for pages reached by a push that want a back arrow.
  final PreferredSizeWidget? appBar;

  const FormPage({
    super.key,
    required this.children,
    this.formKey,
    this.maxWidth = 400,
    this.appBar,
  });

  @override
  Widget build(BuildContext context) {
    Widget content = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    if (formKey != null) {
      content = Form(key: formKey, child: content);
    }

    return Scaffold(
      appBar: appBar,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: AppDimens.spacingL,
              vertical: AppDimens.spacingM,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Vertical gaps between form rows. Named so pages don't scatter literal sizes.
abstract final class FormGap {
  static const Widget small = SizedBox(height: AppDimens.spacingS);
  static const Widget field = SizedBox(height: AppDimens.spacingM);
  static const Widget section = SizedBox(height: AppDimens.spacingL);
  static const Widget large = SizedBox(height: AppDimens.spacingXL);
  static const Widget inline = SizedBox(width: 12.0);
}
