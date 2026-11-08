/// 恢复短语：把 32 字节的恢复密钥编码成 16 个人能抄下来的词。
///
/// 为什么自己造一套而不是用 BIP39：
///   * 不引入额外依赖与授权问题
///   * 16 个词 × 8 bit = 128 bit 熵，足够抵抗暴力猜测
///   * 词表 256 个，两两可区分，抄写不易错
///
/// 注意：词表顺序即编码，**永远不能重排或增删**，否则老短语会解不开。
library;

import 'dart:typed_data';

/// 256 个易读英文单词（顺序固定）
const List<String> recoveryWordlist = [
  'acid', 'aged', 'also', 'area', 'army', 'away', 'baby', 'back',
  'ball', 'band', 'bank', 'base', 'bath', 'bear', 'beat', 'been',
  'beer', 'belt', 'best', 'bill', 'bird', 'blow', 'blue', 'boat',
  'body', 'bomb', 'bond', 'bone', 'book', 'boom', 'boot', 'born',
  'boss', 'both', 'bowl', 'bulk', 'burn', 'bush', 'busy', 'cake',
  'call', 'calm', 'came', 'camp', 'card', 'care', 'case', 'cash',
  'cast', 'cell', 'chat', 'chip', 'city', 'club', 'coal', 'coat',
  'code', 'cold', 'come', 'cook', 'cool', 'cope', 'copy', 'core',
  'cost', 'crew', 'crop', 'dark', 'data', 'date', 'dawn', 'days',
  'dead', 'deal', 'dean', 'dear', 'debt', 'deep', 'deny', 'desk',
  'dial', 'diet', 'disc', 'disk', 'does', 'done', 'door', 'dose',
  'down', 'draw', 'drew', 'drop', 'drug', 'dual', 'duke', 'dust',
  'duty', 'each', 'earn', 'ease', 'east', 'easy', 'edge', 'else',
  'even', 'ever', 'face', 'fact', 'fail', 'fair', 'fall', 'farm',
  'fast', 'fear', 'feed', 'feel', 'feet', 'fell', 'felt', 'file',
  'fill', 'film', 'find', 'fine', 'fire', 'firm', 'fish', 'five',
  'flat', 'flow', 'food', 'foot', 'ford', 'form', 'fort', 'four',
  'free', 'from', 'fuel', 'full', 'fund', 'gain', 'game', 'gate',
  'gave', 'gear', 'gene', 'gift', 'girl', 'give', 'glad', 'goal',
  'goes', 'gold', 'gone', 'good', 'gray', 'grew', 'grow', 'gulf',
  'hair', 'half', 'hall', 'hand', 'hang', 'hard', 'harm', 'hate',
  'have', 'head', 'hear', 'heat', 'held', 'hell', 'help', 'here',
  'hero', 'high', 'hill', 'hire', 'hold', 'hole', 'holy', 'home',
  'hope', 'host', 'hour', 'huge', 'hung', 'hunt', 'idea', 'inch',
  'into', 'iron', 'item', 'jack', 'jane', 'jean', 'john', 'join',
  'jump', 'jury', 'just', 'keen', 'keep', 'kent', 'kept', 'kick',
  'kind', 'king', 'knee', 'knew', 'know', 'lack', 'lady', 'laid',
  'land', 'lane', 'last', 'late', 'lawn', 'lead', 'left', 'less',
  'life', 'lift', 'like', 'line', 'link', 'list', 'live', 'load',
  'loan', 'lock', 'long', 'look', 'loss', 'lost', 'love', 'luck',
  'made', 'mail', 'main', 'make', 'male', 'many', 'mark', 'mass',
  'matt', 'meal', 'mean', 'meat', 'meet', 'menu', 'mere', 'mike',
];

class RecoveryPhrase {
  /// 把 32 字节密钥编码成 16 个词（每词 1 字节）
  static List<String> encode(Uint8List key) {
    if (key.length < 16) {
      throw ArgumentError('恢复密钥至少要 16 字节');
    }
    final words = <String>[];
    for (var i = 0; i < 16; i += 1) {
      words.add(recoveryWordlist[key[i]]);
    }
    return words;
  }

  /// 把 16 个词还原成字节；词不在表里或数量不对都算失败
  static Uint8List decode(List<String> words) {
    final normalized = words
        .map((w) => w.trim().toLowerCase())
        .where((w) => w.isNotEmpty)
        .toList();
    if (normalized.length != 16) {
      throw FormatException('恢复短语应为 16 个词，当前 ${normalized.length} 个');
    }
    final bytes = Uint8List(32);
    for (var i = 0; i < 16; i += 1) {
      final index = recoveryWordlist.indexOf(normalized[i]);
      if (index < 0) {
        throw FormatException('第 ${i + 1} 个词不在词表里：${normalized[i]}');
      }
      bytes[i] = index;
    }
    return bytes;
  }
}
