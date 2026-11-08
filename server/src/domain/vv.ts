/**
 * 版本向量：判断两个修改之间是因果关系还是并发。
 * 维度用 device_id 而不是 node_id —— 真正的并发发生在设备上，
 * 用设备作为维度能精确到"哪台设备改的"，节点只是副本。
 */

export type VersionVector = Record<string, number>;

export type VvRelation = 'equal' | 'a-dominates' | 'b-dominates' | 'concurrent';

export function normalize(vv: VersionVector | null | undefined): VersionVector {
  const out: VersionVector = {};
  if (!vv) return out;
  for (const [key, raw] of Object.entries(vv)) {
    const value = Number(raw);
    if (Number.isFinite(value) && value > 0) out[key] = Math.trunc(value);
  }
  return out;
}

export function compareVv(a: VersionVector, b: VersionVector): VvRelation {
  let aGreater = false;
  let bGreater = false;
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const key of keys) {
    const av = a[key] ?? 0;
    const bv = b[key] ?? 0;
    if (av > bv) aGreater = true;
    else if (bv > av) bGreater = true;
  }
  if (aGreater && bGreater) return 'concurrent';
  if (aGreater) return 'a-dominates';
  if (bGreater) return 'b-dominates';
  return 'equal';
}

/** 逐维度取最大值：表达"这两个修改我全都见过了" */
export function mergeVv(a: VersionVector, b: VersionVector): VersionVector {
  const out: VersionVector = { ...a };
  for (const [key, value] of Object.entries(b)) {
    out[key] = Math.max(out[key] ?? 0, value);
  }
  return out;
}

/** 把某个维度的计数器加一，表示本设备产生了一次新修改 */
export function incrementVv(vv: VersionVector, dimension: string): VersionVector {
  return { ...vv, [dimension]: (vv[dimension] ?? 0) + 1 };
}

/** 是否 a 覆盖了 b（a 至少和 b 一样新） */
export function dominatesOrEqual(a: VersionVector, b: VersionVector): boolean {
  const relation = compareVv(a, b);
  return relation === 'equal' || relation === 'a-dominates';
}

export function vvTotal(vv: VersionVector): number {
  return Object.values(vv).reduce((sum, v) => sum + v, 0);
}
