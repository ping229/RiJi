/// 富文本渲染：把标记文本画成带样式的正文。
library;

import 'package:flutter/material.dart';

import '../../core/rich_text.dart';

class RichTextView extends StatelessWidget {
  const RichTextView({super.key, required this.text, this.baseStyle, this.onToggleTodo});

  final String text;
  final TextStyle? baseStyle;

  /// 点勾选框时回调，参数是该待办行在整段文本中的行号
  final void Function(int lineIndex)? onToggleTodo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = baseStyle ?? theme.textTheme.bodyLarge?.copyWith(height: 1.7, fontSize: 16);
    final lines = RichTextParser.parse(text);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < lines.length; i += 1)
          _buildLine(context, i, lines[i], base, theme),
      ],
    );
  }

  Widget _buildLine(BuildContext context, int lineIndex, RichLine line, TextStyle? base, ThemeData theme) {
    switch (line.kind) {
      case LineKind.divider:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Divider(height: 1),
        );
      case LineKind.code:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            line.plainText,
            style: const TextStyle(fontFamily: 'Consolas', fontSize: 13.5, height: 1.5),
          ),
        );
      case LineKind.heading1:
        return Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 6),
          child: _styled(line, base?.copyWith(fontSize: 24, fontWeight: FontWeight.bold, height: 1.4), theme),
        );
      case LineKind.heading2:
        return Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: _styled(line, base?.copyWith(fontSize: 19, fontWeight: FontWeight.w600, height: 1.45), theme),
        );
      case LineKind.quote:
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.only(left: 12),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.5), width: 3)),
          ),
          child: _styled(line, base?.copyWith(color: theme.colorScheme.outline, fontStyle: FontStyle.italic), theme),
        );
      case LineKind.bullet:
        return Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('•  ', style: base),
              Expanded(child: _styled(line, base, theme)),
            ],
          ),
        );
      case LineKind.ordered:
        return Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${line.listIndex ?? 1}.  ', style: base),
              Expanded(child: _styled(line, base, theme)),
            ],
          ),
        );
      case LineKind.todo:
        final checked = line.checked ?? false;
        final canToggle = onToggleTodo != null;
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              checked ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: checked ? theme.colorScheme.primary : theme.colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _styled(
                line,
                checked
                    ? base?.copyWith(
                        decoration: TextDecoration.lineThrough,
                        color: theme.colorScheme.outline,
                      )
                    : base,
                theme,
              ),
            ),
          ],
        );
        return Padding(
          padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
          child: canToggle
              ? InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: () => onToggleTodo!(lineIndex),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: row,
                  ),
                )
              : row,
        );
      case LineKind.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _styled(line, base, theme),
        );
    }
  }

  Widget _styled(RichLine line, TextStyle? base, ThemeData theme) {
    if (line.spans.isEmpty) return const SizedBox(height: 8);
    return Text.rich(
      TextSpan(
        children: [
          for (final span in line.spans)
            TextSpan(
              text: span.text,
              style: TextStyle(
                fontWeight: span.bold ? FontWeight.bold : null,
                fontStyle: span.italic ? FontStyle.italic : null,
                decoration: _decoration(span),
                fontFamily: span.code ? 'Consolas' : null,
                color: span.link != null ? theme.colorScheme.primary : null,
                backgroundColor: span.code
                    ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7)
                    : null,
              ),
            ),
        ],
      ),
      style: base,
    );
  }

  TextDecoration _decoration(RichSpan span) {
    var decoration = TextDecoration.none;
    if (span.underline || span.link != null) decoration = TextDecoration.underline;
    if (span.strike) {
      decoration = decoration == TextDecoration.none
          ? TextDecoration.lineThrough
          : TextDecoration.combine([decoration, TextDecoration.lineThrough]);
    }
    return decoration;
  }
}
