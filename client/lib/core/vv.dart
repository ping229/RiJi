/// 版本向量：判断两次修改之间是因果关系还是并发。
/// 维度用设备 ID 而不是节点 ID —— 真正的并发发生在设备上。
library;

import 'dart:math' as math;

typedef VersionVector = Map<String, int>;

VersionVector normalizeVv(Map<String, dynamic>? raw) {
  final out = <String, int>{};
  if (raw == null) return out;
  raw.forEach((key, value) {
    final n = value is int ? value : int.tryParse('$value');
    if (n != null && n > 0) out[key] = n;
  });
  return out;
}

enum VvRelation { equal, aDominates, bDominates, concurrent }

VvRelation compareVv(VersionVector a, VersionVector b) {
  var aGreater = false;
  var bGreater = false;
  final keys = {...a.keys, ...b.keys};
  for (final key in keys) {
    final av = a[key] ?? 0;
    final bv = b[key] ?? 0;
    if (av > bv) {
      aGreater = true;
    } else if (bv > av) {
      bGreater = true;
    }
  }
  if (aGreater && bGreater) return VvRelation.concurrent;
  if (aGreater) return VvRelation.aDominates;
  if (bGreater) return VvRelation.bDominates;
  return VvRelation.equal;
}

/// 逐维度取最大值：表达"这两个修改我全都见过了"
VersionVector mergeVv(VersionVector a, VersionVector b) {
  final out = <String, int>{...a};
  b.forEach((key, value) {
    out[key] = math.max(out[key] ?? 0, value);
  });
  return out;
}

/// 本设备产生一次新修改
VersionVector incrementVv(VersionVector vv, String dimension) {
  return {...vv, dimension: (vv[dimension] ?? 0) + 1};
}

bool dominatesOrEqual(VersionVector a, VersionVector b) {
  final relation = compareVv(a, b);
  return relation == VvRelation.equal || relation == VvRelation.aDominates;
}
