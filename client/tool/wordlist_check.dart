import 'package:riji_client/core/recovery_phrase.dart';
void main() {
  print('词表长度: ${recoveryWordlist.length}');
  final seen = <String>{};
  final dup = <String>[];
  for (final w in recoveryWordlist) { if (!seen.add(w)) dup.add(w); }
  print('重复词: $dup');
}
