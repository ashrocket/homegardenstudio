import { HttpError, json } from "./errors";
import { assertSql, getBalances } from "./ledger";
import type { AuthedCtx, Env } from "./types";
import { isGuardFailure, isInt } from "./util";

const AVAILABLE = `s.status='active' AND o.status='active' AND (o.starts_at IS NULL OR o.starts_at<=?2)
 AND (o.ends_at IS NULL OR o.ends_at>?2) AND NOT EXISTS(SELECT 1 FROM sponsor_dismissals d WHERE d.account_id=?1 AND d.offer_id=o.id AND d.until_at>?2)`;
export async function settleWindows(env: Env, now: number, accountId?: string): Promise<void> {
  const rows = await env.DB.prepare(`SELECT id FROM sponsor_windows WHERE settled_at IS NULL AND (expires_at<=?1 OR account_id IN (SELECT id FROM accounts WHERE deleted_at IS NOT NULL)) ${accountId ? "AND account_id=?2" : ""} LIMIT 100`).bind(...(accountId ? [now,accountId] : [now])).all<{id:string}>();
  for (const row of rows.results) {
    try { await env.DB.batch([
      assertSql(env.DB,"EXISTS(SELECT 1 FROM sponsor_windows WHERE id=?1 AND settled_at IS NULL AND (expires_at<=?2 OR account_id IN (SELECT id FROM accounts WHERE deleted_at IS NOT NULL)))",row.id,now),
      env.DB.prepare("UPDATE sponsors SET budget_remaining_micros=budget_remaining_micros+(SELECT remaining_micros FROM sponsor_windows WHERE id=?1) WHERE id=(SELECT sponsor_id FROM sponsor_windows WHERE id=?1)").bind(row.id),
      env.DB.prepare("UPDATE sponsor_windows SET returned_micros=returned_micros+remaining_micros,remaining_micros=0,settled_at=?2 WHERE id=?1").bind(row.id,now),
    ]); } catch(e) { if (!isGuardFailure(e)) throw e; }
  }
}
export async function offers(ctx: AuthedCtx): Promise<Response> {
  const rows = await ctx.env.DB.prepare(`SELECT o.id offer_id,s.name sponsor_name,s.category,s.paid_for_by,o.disclosure,o.report_url,s.budget_remaining_micros
    FROM sponsor_offers o JOIN sponsors s ON s.id=o.sponsor_id WHERE ${AVAILABLE} AND s.budget_remaining_micros>0`)
    .bind(ctx.accountId,ctx.deps.now()).all<Record<string,unknown>>();
  const out = [];
  for (const row of rows.results) {
    const windows = await ctx.env.DB.prepare("SELECT minutes,credit_cap_micros FROM sponsor_offer_windows WHERE offer_id=? AND credit_cap_micros<=? ORDER BY minutes").bind(row.offer_id,row.budget_remaining_micros).all();
    if (windows.results.length) {
      const {budget_remaining_micros: _,...publicRow} = row;
      out.push({...publicRow,why_shown:"Available to anyone whose prepaid credit has run out. Not based on photos, location or activity.",windows:windows.results});
    }
  }
  return json({offers:out});
}
export async function createWindow(ctx: AuthedCtx, input: Record<string,unknown>, cheapest: number): Promise<Response> {
  const {env,accountId,deps} = ctx, now = deps.now(), db=env.DB;
  if (typeof input.offer_id !== "string" || !isInt(input.minutes)) throw new HttpError(400,"INVALID_WINDOW","Choose an available funded window.");
  if (cheapest <= 0) throw new HttpError(503,"MANAGED_UNAVAILABLE","Managed rendering is unavailable.");
  await settleWindows(env,now,accountId);
  const offer = await db.prepare(`SELECT o.id,o.sponsor_id,w.credit_cap_micros FROM sponsor_offers o JOIN sponsors s ON s.id=o.sponsor_id
    JOIN sponsor_offer_windows w ON w.offer_id=o.id WHERE ${AVAILABLE} AND o.id=?3 AND w.minutes=?4 AND s.budget_remaining_micros>=w.credit_cap_micros`)
    .bind(accountId,now,input.offer_id,input.minutes).first<{id:string;sponsor_id:string;credit_cap_micros:number}>();
  if (!offer) throw new HttpError(409,"OFFER_UNAVAILABLE","This funded offer is unavailable.");
  const id=deps.uuid(), expires=now+input.minutes*60_000;
  try { await db.batch([
    assertSql(db,"EXISTS(SELECT 1 FROM accounts WHERE id=?1 AND deleted_at IS NULL)",accountId),
    assertSql(db,"COALESCE((SELECT micros FROM balances WHERE account_id=?1 AND environment='production'),0)-COALESCE((SELECT SUM(shortfall_micros) FROM transactions WHERE account_id=?1 AND balance_environment='production' AND revoked_at IS NOT NULL),0)<?2",accountId,cheapest),
    assertSql(db,`EXISTS(SELECT 1 FROM sponsor_offers o JOIN sponsors s ON s.id=o.sponsor_id JOIN sponsor_offer_windows w ON w.offer_id=o.id WHERE ${AVAILABLE} AND o.id=?3 AND w.minutes=?4 AND w.credit_cap_micros=?5 AND s.budget_remaining_micros>=?5)`,accountId,now,offer.id,input.minutes,offer.credit_cap_micros),
    db.prepare("UPDATE sponsors SET budget_remaining_micros=budget_remaining_micros-?2 WHERE id=?1").bind(offer.sponsor_id,offer.credit_cap_micros),
    db.prepare("INSERT INTO sponsor_windows(id,account_id,offer_id,sponsor_id,minutes,credit_cap_micros,remaining_micros,starts_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?)").bind(id,accountId,offer.id,offer.sponsor_id,input.minutes,offer.credit_cap_micros,offer.credit_cap_micros,now,expires),
  ]); } catch(e) { if (isGuardFailure(e)) throw new HttpError(409,"WINDOW_UNAVAILABLE","The offer, balance, or active window changed. Refresh available offers."); throw e; }
  return json({window_id:id,expires_at:expires,credit_cap_micros:offer.credit_cap_micros,remaining_micros:offer.credit_cap_micros},201);
}
export async function sponsorAction(ctx: AuthedCtx,input:Record<string,unknown>,dismiss:boolean): Promise<Response> {
  if(typeof input.offer_id!=="string") throw new HttpError(400,"INVALID_OFFER","Choose an offer.");
  if(dismiss) await ctx.env.DB.prepare("INSERT INTO sponsor_dismissals VALUES(?,?,?) ON CONFLICT(account_id,offer_id) DO UPDATE SET until_at=excluded.until_at").bind(ctx.accountId,input.offer_id,ctx.deps.now()+30*86400000).run();
  else {
    if(typeof input.reason!=="string" || input.reason.trim().length<1 || input.reason.length>1000) throw new HttpError(400,"INVALID_REPORT","Provide a reason of 1–1000 characters.");
    await ctx.env.DB.prepare("INSERT INTO sponsor_reports(offer_id,account_id,reason,created_at) VALUES(?,?,?,?)").bind(input.offer_id,ctx.accountId,input.reason.trim(),ctx.deps.now()).run();
  }
  return json({ok:true});
}
