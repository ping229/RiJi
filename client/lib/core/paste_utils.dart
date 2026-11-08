/// 粘贴处理（需求 3.4：提供"仅粘贴纯文本"选项）。
///
/// Flutter 的剪贴板只提供纯文本，所以"仅纯文本"在这里的真实含义是
/// **把粘贴进来的文本清理干净**：从网页复制的内容常带全角空格、零宽字符、
/// Windows 换行、以及一堆多余空行，直接粘进日记会让排版乱掉。
library;

class PasteUtils {
  /// 常见零宽与方向控制字符：肉眼不可见，但会破坏光标与搜索
  static final RegExp _invisible = RegExp('[\u200B-\u200F\u202A-\u202E\u2060\uFEFF]');

  /// 清理粘贴文本
  static String clean(String input) {
    if (input.isEmpty) return input;

    var text = input;

    // 1. 统一换行符
    text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // 2. 去掉零宽字符与方向控制符
    text = text.replaceAll(_invisible, '');

    // 3. 不间断空格与全角空格转普通空格（保留中文之间的全角空格语义会更好，
    //    但网页复制出来的全角空格几乎都是排版残留）
    text = text.replaceAll('\u00A0', ' ');

    // 4. 制表符转两个空格（编辑器里 tab 表现不稳定）
    text = text.replaceAll('\t', '  ');

    // 5. 去掉每行行尾空白
    text = text
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ ]+$'), ''))
        .join('\n');

    // 6. 连续 3 个以上空行压成 1 个空行
    text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');

    // 7. 首尾空白整体修剪
    return text.trim();
  }

  /// 把清理后的文本插入到光标处（替换选区），返回新的文本与光标位置
  static ({String text, int caret}) insert(String source, int start, int end, String pasted) {
    final safeStart = start.clamp(0, source.length);
    final safeEnd = end.clamp(safeStart, source.length);
    final before = source.substring(0, safeStart);
    final after = source.substring(safeEnd);
    final inserted = clean(pasted);
    return (text: '$before$inserted$after', caret: before.length + inserted.length);
  }
}
