/**
 * 审计日志：管理员对节点、用户、迁移的每一次操作都必须留痕（需求 6.3 / 7.2.4）。
 * 只记录操作本身，绝不记录日记内容。
 */
import { pool } from '../db/pool.ts';

export interface AuditEntry {
  actorId: string | null;
  action: string;
  targetType?: string | null;
  targetId?: string | null;
  detail?: Record<string, unknown>;
}

export async function writeAudit(entry: AuditEntry): Promise<void> {
  await pool.query(
    `INSERT INTO audit_log (actor_id, action, target_type, target_id, detail)
     VALUES ($1, $2, $3, $4, $5)`,
    [
      entry.actorId,
      entry.action,
      entry.targetType ?? null,
      entry.targetId ?? null,
      JSON.stringify(entry.detail ?? {}),
    ],
  );
}

export async function listAudit(limit: number): Promise<
  Array<{
    id: number;
    actorId: string | null;
    actorName: string | null;
    action: string;
    targetType: string | null;
    targetId: string | null;
    detail: Record<string, unknown>;
    createdAt: string;
  }>
> {
  const { rows } = await pool.query(
    `SELECT a.id, a.actor_id, u.username AS actor_name, a.action, a.target_type, a.target_id, a.detail, a.created_at
       FROM audit_log a
       LEFT JOIN users u ON u.id = a.actor_id
      ORDER BY a.id DESC
      LIMIT $1`,
    [limit],
  );
  return rows.map((r) => ({
    id: Number(r.id),
    actorId: r.actor_id,
    actorName: r.actor_name,
    action: r.action,
    targetType: r.target_type,
    targetId: r.target_id,
    detail: r.detail ?? {},
    createdAt: new Date(r.created_at).toISOString(),
  }));
}
