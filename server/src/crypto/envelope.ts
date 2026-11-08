/**
 * 密文外壳（需求 6.1 的落地形式）
 *
 * 设计决定：数据模型从第一天就按"服务端只见不透明字节"来做。
 *
 * 现状（v1.4 实现完成后）：
 *   * 客户端负责真正的加解密，密钥由用户密码在本地派生，永不上传；
 *   * 服务端把 payload 当作不透明的 bytea 原样存取，**不参与解密**；
 *   * 因此这里的 seal/open 只在服务端确实需要持有密钥时才用得上
 *     （例如将来做服务端索引），日常写入路径是 enc='none' 透传密文——
 *     'none' 指的是"服务端没再包一层"，不是"明文"。
 *
 * AAD 把密文绑定到具体位置，防止运维方把 A 块的密文挪到 B 块做重放。
 */
import { createCipheriv, createDecipheriv, createHash, randomBytes } from 'node:crypto';

export type EncMode = 'none' | 'aes-256-gcm';

export interface Sealed {
  enc: EncMode;
  payload: Buffer;
  nonce: Buffer | null;
  keyId: string | null;
}

export interface KeyMaterial {
  keyId: string;
  key: Buffer;
}

export interface Keyring {
  mode: EncMode;
  current: KeyMaterial | null;
  lookup(keyId: string): Buffer | null;
}

/** 当前阶段的空实现：不做任何加密，原样透传 */
export function passthroughKeyring(): Keyring {
  return { mode: 'none', current: null, lookup: () => null };
}

export function seal(plain: Buffer, aad: Buffer, keyring: Keyring): Sealed {
  if (keyring.mode === 'none') {
    return { enc: 'none', payload: plain, nonce: null, keyId: null };
  }
  const material = keyring.current;
  if (!material) throw new Error('keyring 处于加密模式但没有可用密钥');
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', material.key, nonce);
  cipher.setAAD(aad);
  const body = Buffer.concat([cipher.update(plain), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    enc: 'aes-256-gcm',
    payload: Buffer.concat([body, tag]),
    nonce,
    keyId: material.keyId,
  };
}

export function open(sealed: Sealed, aad: Buffer, keyring: Keyring): Buffer {
  if (sealed.enc === 'none') return sealed.payload;
  if (sealed.enc !== 'aes-256-gcm') throw new Error(`未知的加密模式: ${sealed.enc}`);
  const key = sealed.keyId ? keyring.lookup(sealed.keyId) : keyring.current?.key ?? null;
  if (!key) throw new Error(`找不到解密密钥: ${sealed.keyId ?? '(current)'}`);
  if (!sealed.nonce) throw new Error('密文缺少 nonce');
  const tag = sealed.payload.subarray(sealed.payload.length - 16);
  const body = sealed.payload.subarray(0, sealed.payload.length - 16);
  const decipher = createDecipheriv('aes-256-gcm', key, sealed.nonce);
  decipher.setAAD(aad);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(body), decipher.final()]);
}

/** 构造块级 AAD：块的身份信息，防止跨块重放 */
export function blockAad(parts: {
  diaryId: string;
  blockId: string;
  deviceId: string;
  hlc: string;
}): Buffer {
  return Buffer.from(`${parts.diaryId}|${parts.blockId}|${parts.deviceId}|${parts.hlc}`, 'utf8');
}

export function sha256Hex(data: Buffer | string): string {
  return createHash('sha256').update(data).digest('hex');
}
