/**
 * 混合逻辑时钟（HLC）
 *
 * 物理时钟会漂移，纯逻辑时钟又无法跨设备比较先后。
 * HLC 用 (物理毫秒, 逻辑计数, 设备号) 三元组，既单调又能在设备间全序比较，
 * 冲突仲裁时用它做确定性的 tie-break。
 */

export interface Hlc {
  /** 物理毫秒时间戳 */
  phys: number;
  /** 同一毫秒内的逻辑计数 */
  counter: number;
  /** 产生该时间戳的设备，用于全序比较时的最终 tie-break */
  device: string;
}

const PHYS_HEX_WIDTH = 12;
const COUNTER_HEX_WIDTH = 4;

/** 编码为定宽字符串，字符串序 == 时间序，可直接用于数据库排序 */
export function encodeHlc(hlc: Hlc): string {
  const phys = Math.max(0, Math.trunc(hlc.phys)).toString(16).padStart(PHYS_HEX_WIDTH, '0');
  const counter = Math.max(0, Math.trunc(hlc.counter)).toString(16).padStart(COUNTER_HEX_WIDTH, '0');
  return `${phys}-${counter}-${hlc.device}`;
}

export function decodeHlc(encoded: string): Hlc {
  const m = /^([0-9a-f]+)-([0-9a-f]+)-(.+)$/.exec(encoded);
  if (!m) throw new Error(`非法 HLC 编码: ${encoded}`);
  return {
    phys: Number.parseInt(m[1], 16),
    counter: Number.parseInt(m[2], 16),
    device: m[3],
  };
}

/** 比较两枚 HLC，返回 -1 / 0 / 1 */
export function compareHlc(a: Hlc, b: Hlc): number {
  if (a.phys !== b.phys) return a.phys < b.phys ? -1 : 1;
  if (a.counter !== b.counter) return a.counter < b.counter ? -1 : 1;
  if (a.device === b.device) return 0;
  return a.device < b.device ? -1 : 1;
}

/**
 * 生成本地新时间戳。
 * 若本地物理时钟落后于已见过的最大时间戳（例如设备时间被回拨），
 * 则沿用旧物理时间并递增逻辑计数，保证全局单调。
 */
export function nextHlc(prev: Hlc | null, physicalNow: number, device: string): Hlc {
  const wall = Math.max(0, Math.trunc(physicalNow));
  if (!prev) return { phys: wall, counter: 0, device };
  if (wall > prev.phys) return { phys: wall, counter: 0, device };
  return { phys: prev.phys, counter: prev.counter + 1, device };
}

/** 收到远端时间戳后推进本地时钟（Lamport 式合并） */
export function observeHlc(local: Hlc | null, remote: Hlc, physicalNow: number, device: string): Hlc {
  const wall = Math.max(0, Math.trunc(physicalNow));
  const maxPhys = Math.max(wall, local?.phys ?? 0, remote.phys);
  let counter: number;
  if (maxPhys === (local?.phys ?? 0) && maxPhys === remote.phys) {
    counter = Math.max(local?.counter ?? 0, remote.counter) + 1;
  } else if (maxPhys === (local?.phys ?? 0)) {
    counter = (local?.counter ?? 0) + 1;
  } else if (maxPhys === remote.phys) {
    counter = remote.counter + 1;
  } else {
    counter = 0;
  }
  return { phys: maxPhys, counter, device };
}
