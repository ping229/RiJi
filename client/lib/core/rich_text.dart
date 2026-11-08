/// 富文本的极简标记语言（需求 3.2）。
///
/// 为什么用标记而不是"所见即所得"编辑器：
/// Flutter 没有可直接用的块级富文本编辑器，自研光标/选区的代价极高且容易出 bug。
/// 用标记 + 渲染的方式，输入稳定、数据天然是纯文本（对同步与加密友好），
/// 并且可以随时在"编辑"和"预览"之间切换。
///
/// 支持的语法：
///   行级：`# 标题`、`## 二级标题`、`- 列表`、`1. 有序列表`、`- [ ] 待办`、
///         `> 引用`、``` 代码块 ```、`--- 分隔线`
///   行内：`**粗体**`、`*斜体*`、`__下划线__`、`~~删除线~~`、`` `代码` ``、`[文字](链接)`
library;

enum LineKind { paragraph, heading1, heading2, bullet, ordered, todo, quote, code, divider }

class RichSpan {
  const RichSpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.code = false,
    this.link,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final bool code;
  final String? link;

  RichSpan merge(RichSpan other) => RichSpan(
        text + other.text,
        bold: bold || other.bold,
        italic: italic || other.italic,
        underline: underline || other.underline,
        strike: strike || other.strike,
        code: code || other.code,
        link: link ?? other.link,
      );
}

class RichLine {
  const RichLine(this.kind, this.spans, {this.listIndex, this.checked});

  final LineKind kind;
  final List<RichSpan> spans;

  /// 有序列表的序号（从 1 开始）
  final int? listIndex;

  /// 待办项是否已勾选（仅 LineKind.todo 有意义）
  final bool? checked;

  String get plainText => spans.map((s) => s.text).join();
}

class RichTextParser {
  /// 把一段纯文本解析成"行 + 行内样式"
  static List<RichLine> parse(String source) {
    final lines = source.split('\n');
    final result = <RichLine>[];
    var inCodeBlock = false;
    final codeBuffer = <String>[];

    for (final raw in lines) {
      final line = raw.trimRight();

      // 代码块围栏
      if (line.trimLeft().startsWith('```')) {
        if (inCodeBlock) {
          result.add(RichLine(LineKind.code, [RichSpan(codeBuffer.join('\n'), code: true)]));
          codeBuffer.clear();
          inCodeBlock = false;
        } else {
          inCodeBlock = true;
        }
        continue;
      }
      if (inCodeBlock) {
        codeBuffer.add(line);
        continue;
      }

      final trimmed = line.trimLeft();

      if (trimmed == '---' || trimmed == '***') {
        result.add(const RichLine(LineKind.divider, []));
        continue;
      }
      if (trimmed.startsWith('## ')) {
        result.add(RichLine(LineKind.heading2, parseInline(trimmed.substring(3))));
        continue;
      }
      if (trimmed.startsWith('# ')) {
        result.add(RichLine(LineKind.heading1, parseInline(trimmed.substring(2))));
        continue;
      }
      if (trimmed.startsWith('> ')) {
        result.add(RichLine(LineKind.quote, parseInline(trimmed.substring(2))));
        continue;
      }
      // 待办：- [ ] / - [x]
      final todoMatch = RegExp(r'^-\s\[([ xX])\]\s?(.*)$').firstMatch(trimmed);
      if (todoMatch != null) {
        result.add(RichLine(
          LineKind.todo,
          parseInline(todoMatch.group(2) ?? ''),
          checked: todoMatch.group(1)!.toLowerCase() == 'x',
        ));
        continue;
      }
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
        result.add(RichLine(LineKind.bullet, parseInline(trimmed.substring(2))));
        continue;
      }
      final orderedMatch = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(trimmed);
      if (orderedMatch != null) {
        result.add(RichLine(
          LineKind.ordered,
          parseInline(orderedMatch.group(2) ?? ''),
          listIndex: int.tryParse(orderedMatch.group(1) ?? '') ?? 1,
        ));
        continue;
      }

      result.add(RichLine(LineKind.paragraph, parseInline(line)));
    }

    // 代码块没闭合也要把内容留住，不能吞掉
    if (inCodeBlock && codeBuffer.isNotEmpty) {
      result.add(RichLine(LineKind.code, [RichSpan(codeBuffer.join('\n'), code: true)]));
    }
    return result;
  }

  /// 解析行内标记。按"先长后短"的顺序匹配，避免 `**` 被当成两个 `*`。
  static List<RichSpan> parseInline(String text) {
    final spans = <RichSpan>[];
    final buffer = StringBuffer();
    var i = 0;
    var bold = false;
    var italic = false;
    var underline = false;
    var strike = false;
    var code = false;

    void flush() {
      if (buffer.isEmpty) return;
      spans.add(RichSpan(
        buffer.toString(),
        bold: bold,
        italic: italic,
        underline: underline,
        strike: strike,
        code: code,
      ));
      buffer.clear();
    }

    while (i < text.length) {
      final rest = text.substring(i);

      if (rest.startsWith('**')) {
        flush();
        bold = !bold;
        i += 2;
        continue;
      }
      if (rest.startsWith('__')) {
        flush();
        underline = !underline;
        i += 2;
        continue;
      }
      if (rest.startsWith('~~')) {
        flush();
        strike = !strike;
        i += 2;
        continue;
      }
      if (rest.startsWith('`')) {
        flush();
        code = !code;
        i += 1;
        continue;
      }
      if (rest.startsWith('*')) {
        flush();
        italic = !italic;
        i += 1;
        continue;
      }
      // 链接 [文字](地址)
      if (rest.startsWith('[')) {
        final match = RegExp(r'^\[([^\]]*)\]\(([^)]*)\)').firstMatch(rest);
        if (match != null) {
          flush();
          spans.add(RichSpan(
            match.group(1) ?? '',
            bold: bold,
            italic: italic,
            underline: true,
            strike: strike,
            link: match.group(2) ?? '',
          ));
          i += match.group(0)!.length;
          continue;
        }
      }

      buffer.write(text[i]);
      i += 1;
    }
    flush();

    if (spans.isEmpty) return [RichSpan(text)];
    // 合并相邻同样式片段，减少 span 数量
    final merged = <RichSpan>[spans.first];
    for (var k = 1; k < spans.length; k += 1) {
      final prev = merged.last;
      final cur = spans[k];
      final sameStyle = prev.bold == cur.bold &&
          prev.italic == cur.italic &&
          prev.underline == cur.underline &&
          prev.strike == cur.strike &&
          prev.code == cur.code &&
          prev.link == cur.link;
      if (sameStyle) {
        merged[merged.length - 1] = prev.merge(cur);
      } else {
        merged.add(cur);
      }
    }
    return merged;
  }

  /// 把选中的文字用标记包裹（工具栏按钮用）
  static String wrapSelection(String text, int start, int end, String marker) {
    final safeStart = start.clamp(0, text.length);
    final safeEnd = end.clamp(safeStart, text.length);
    final selected = text.substring(safeStart, safeEnd);
    final before = text.substring(0, safeStart);
    final after = text.substring(safeEnd);
    return '$before$marker$selected$marker$after';
  }

  /// 切换某一行的待办勾选状态。lineIndex 是整段文本的行号（从 0 开始）。
  /// 不是待办行就原样返回，绝不误改其他内容。
  static String toggleTodoAt(String source, int lineIndex) {
    final lines = source.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return source;
    final match = RegExp(r'^(\s*-\s\[)([ xX])(\](?:.*))$').firstMatch(lines[lineIndex]);
    if (match == null) return source;
    final next = match.group(2)!.toLowerCase() == 'x' ? ' ' : 'x';
    lines[lineIndex] = '${match.group(1)}$next${match.group(3)}';
    return lines.join('\n');
  }

  /// 在行首加前缀（标题、列表、引用）
  static String prefixLine(String text, int caret, String prefix) {
    final lineStart = text.lastIndexOf('\n', caret > 0 ? caret - 1 : 0) + 1;
    final needsNewline = lineStart >= text.length;
    if (needsNewline) return '$text\n$prefix';
    return '${text.substring(0, lineStart)}$prefix${text.substring(lineStart)}';
  }
}
