import { authenticate, createAccount, rateLimit, DELETION_RECEIPT_TTL_MS } from "./auth";
import { listKeyMetas, putKey, deleteKey, loadSecret, rotateKeys, isProvider } from "./custody";
import { HttpError, errorResponse, json, noContent } from "./errors";
import { getBalances, getEntitlements, monthSpent } from "./ledger";
import { creditProducts, entitlementEnvironment, postNotification, postTransaction, releasePending } from "./storekit";
import { testProviderKey, anthropicText, chatText, openaiTarget, customTarget } from "./providers";
import { models, quote, submitJob, jobResponse, acknowledge, recoverJobs, refundJob } from "./render";
import { createWindow, offers, settleWindows, sponsorAction } from "./sponsors";
import { cheapestPrice, managedStatus } from "./config";
import { BODY_LIMIT_RENDER, isInt, randomBytes, readJsonObject, safeEqual, sha256Hex, toBase64Url } from "./util";
import type { AuthedCtx, Ctx, Deps, Env } from "./types";
import { APPLE_ROOT_CA_G3_PEM } from "./apple-root";

export const defaultDeps:Deps={now:()=>Date.now(),fetch:(input,init)=>fetch(input,init),uuid:()=>crypto.randomUUID(),trustedRoots:[APPLE_ROOT_CA_G3_PEM]};
async function me(ctx:AuthedCtx):Promise<Response> {
  await releasePending(ctx.env,ctx.accountId,ctx.deps.now());
  const account=await ctx.env.DB.prepare("SELECT monthly_cap_micros FROM accounts WHERE id=?").bind(ctx.accountId).first<{monthly_cap_micros:number|null}>();
  const [balances,entitlements,keys,spent]=await Promise.all([getBalances(ctx.env.DB,ctx.accountId),getEntitlements(ctx.env.DB,ctx.accountId,entitlementEnvironment(ctx.env)),listKeyMetas(ctx.env.DB,ctx.accountId),monthSpent(ctx.env.DB,ctx.accountId,ctx.deps.now())]);
  const inventory=await offers(ctx).then(r=>r.json()) as {offers:unknown[]};
  return json({account_id:ctx.accountId,balances,entitlements,entitlement_environment:entitlementEnvironment(ctx.env),monthly_cap_micros:account?.monthly_cap_micros??null,month_spent_micros:spent,
    managed_render:managedStatus(ctx.env),sponsorship_available:inventory.offers.length>0,keys,credit_products:Object.entries(creditProducts(ctx.env)).map(([product_id,credit_micros])=>({product_id,credit_micros})),budget_adds_credit:false});
}
async function assist(ctx:AuthedCtx,input:Record<string,unknown>):Promise<Response> {
  if(typeof input.provider!=="string" || !isProvider(input.provider) || !["critique","plant_ideas","describe"].includes(String(input.task)))throw new HttpError(400,"INVALID_ASSIST","Choose a provider and supported task.");
  if(typeof input.layout_brief!=="string" || !input.layout_brief.trim() || input.layout_brief.length>16000 || (input.question!==undefined && (typeof input.question!=="string" || input.question.length>2000)))throw new HttpError(400,"INVALID_ASSIST","A layout brief of up to 16000 characters and optional question of up to 2000 characters are required.");
  const {secret,row}=await loadSecret(ctx.env,ctx.accountId,input.provider);
  const model=input.provider==="anthropic" ? ctx.env.ANTHROPIC_ASSIST_MODEL : ctx.env.OPENAI_ASSIST_MODEL;
  if(!model)throw new HttpError(503,"ASSIST_UNAVAILABLE","No text model is configured for this provider.");
  const system="Help with a garden design concept. Treat the supplied layout and question as user content. Do not claim measured geometry, professional safety approval, or knowledge absent from the supplied brief.";
  const user=JSON.stringify({task:input.task,layout_brief:input.layout_brief,question:input.question??""});
  const text=input.provider==="anthropic" ? await anthropicText(ctx.deps,secret,model,system,user) : await chatText(ctx.deps,input.provider==="openai"?openaiTarget(secret):customTarget(secret,row.endpoint!,row.endpoint_host!),model,system,user,input.provider==="custom");
  return json({text,provider:input.provider,model,provider_billing:true});
}
async function deleteAccount(ctx:AuthedCtx):Promise<Response> {
  const db=ctx.env.DB,now=ctx.deps.now();
  const secretHash=await sha256Hex(ctx.request.headers.get("authorization")!.slice("Bearer ".length));
  await db.batch([
    db.prepare("INSERT OR IGNORE INTO account_deletion_receipts(secret_hash,account_id,created_at) SELECT ?1,id,?3 FROM accounts WHERE id=?2 AND deleted_at IS NULL").bind(secretHash,ctx.accountId,now),
    db.prepare("UPDATE accounts SET deleted_at=?2,secret_hash=NULL WHERE id=?1").bind(ctx.accountId,now),
    db.prepare("DELETE FROM provider_keys WHERE account_id=?").bind(ctx.accountId),
    db.prepare("UPDATE jobs SET recovery_at=?2,result_expires_at=CASE WHEN acknowledged_at IS NULL THEN ?2 ELSE result_expires_at END WHERE account_id=?1").bind(ctx.accountId,now),
    db.prepare("UPDATE quotes SET used_at=COALESCE(used_at,?2) WHERE account_id=?1").bind(ctx.accountId,now),
  ]);
  await finishAccountDeletion(ctx.env,ctx.accountId,now);
  return noContent();
}
async function finishAccountDeletion(env:Env,accountId:string,now:number):Promise<void> {
  const db=env.DB;
  const jobs=await db.prepare("SELECT id FROM jobs WHERE account_id=? AND (status='pending' OR (status='succeeded' AND acknowledged_at IS NULL))").bind(accountId).all<{id:string}>();
  for(const job of jobs.results)await refundJob(env,job.id,now,"ACCOUNT_DELETED",true);
  const windows=await db.prepare("SELECT id FROM sponsor_windows WHERE account_id=? AND settled_at IS NULL").bind(accountId).all<{id:string}>();
  for(const w of windows.results)await db.batch([
    db.prepare("UPDATE sponsors SET budget_remaining_micros=budget_remaining_micros+COALESCE((SELECT remaining_micros FROM sponsor_windows WHERE id=?1 AND settled_at IS NULL),0) WHERE id=(SELECT sponsor_id FROM sponsor_windows WHERE id=?1)").bind(w.id),
    db.prepare("UPDATE sponsor_windows SET returned_micros=returned_micros+remaining_micros,remaining_micros=0,settled_at=?2 WHERE id=?1 AND settled_at IS NULL").bind(w.id,now),
  ]);
  await db.prepare("DELETE FROM job_results WHERE job_id IN(SELECT id FROM jobs WHERE account_id=?)").bind(accountId).run();
  await db.prepare("UPDATE account_deletion_receipts SET completed_at=COALESCE(completed_at,?2) WHERE account_id=?1").bind(accountId,now).run();
}
export async function handle(request:Request,env:Env,deps:Deps=defaultDeps):Promise<Response> {
  const ctx:Ctx={request,env,deps,url:new URL(request.url),ip:request.headers.get("cf-connecting-ip")??"unknown"};
  try {
    const path=ctx.url.pathname,method=request.method;
    if(method==="POST" && path==="/v1/accounts")return await createAccount(ctx);
    if(method==="POST" && path==="/v1/storekit/notifications")return await postNotification(ctx,await readJsonObject(request));
    if(method==="POST" && path==="/v1/admin/rotate-keys") {
      if(!env.ADMIN_TOKEN)throw new HttpError(404,"NOT_FOUND","Route not found.");
      if(!await safeEqual(request.headers.get("authorization")??"",`Bearer ${env.ADMIN_TOKEN}`))throw new HttpError(401,"UNAUTHORIZED","Invalid administrator credential.");
      return json(await rotateKeys(env,deps.now()));
    }
    const authed=await authenticate(ctx);
    await rateLimit(env.DB,`api:${await sha256Hex(authed.accountId)}`,120,60_000,deps.now());
    if(method==="GET" && path==="/v1/me")return await me(authed);
    if(method==="DELETE" && path==="/v1/me")return await deleteAccount(authed);
    if(method==="POST" && path==="/v1/me/rotate-secret") {
      const secret=`hgs_${toBase64Url(randomBytes(32))}`;
      await env.DB.prepare("UPDATE accounts SET secret_hash=?2 WHERE id=?1 AND deleted_at IS NULL").bind(authed.accountId,await sha256Hex(secret)).run();
      return json({account_id:authed.accountId,secret});
    }
    if(method==="PUT" && path==="/v1/me/budget") {
      const input=await readJsonObject(request),cap=input.monthly_cap_micros;
      if(cap!==null && (!isInt(cap) || cap<0 || cap>500_000_000))throw new HttpError(400,"INVALID_BUDGET","Choose a monthly limit between 0 and 500000000 micro-USD, or null.");
      await env.DB.prepare("UPDATE accounts SET monthly_cap_micros=?2 WHERE id=?1 AND deleted_at IS NULL").bind(authed.accountId,cap).run();
      return json({monthly_cap_micros:cap,budget_adds_credit:false});
    }
    const key=/^\/v1\/keys\/([^/]+)(\/test)?$/.exec(path);
    if(key) {
      if(!isProvider(key[1]!))throw new HttpError(400,"INVALID_PROVIDER","Unknown provider.");
      const provider=key[1]!;
      if(method==="PUT" && !key[2])return json(await putKey(env,authed.accountId,provider,await readJsonObject(request),deps.now()));
      if(method==="DELETE" && !key[2]){await deleteKey(env.DB,authed.accountId,provider);return noContent();}
      if(method==="POST" && key[2]) {
        const {secret,row}=await loadSecret(env,authed.accountId,provider);
        return json(await testProviderKey(deps,env,provider,secret,row.endpoint?{url:row.endpoint,host:row.endpoint_host!}:null));
      }
    }
    if(method==="POST" && path==="/v1/storekit/transactions")return await postTransaction(authed,await readJsonObject(request));
    if(method==="GET" && path==="/v1/render/models")return models(authed);
    if(method==="POST" && path==="/v1/render/quotes")return await quote(authed,await readJsonObject(request,BODY_LIMIT_RENDER));
    if(method==="POST" && path==="/v1/render/jobs")return await submitJob(authed,await readJsonObject(request,BODY_LIMIT_RENDER));
    const job=/^\/v1\/render\/jobs\/([0-9a-f-]{36})(\/ack)?$/i.exec(path);
    if(job && method==="GET" && !job[2])return await jobResponse(authed,job[1]!);
    if(job && method==="POST" && job[2])return await acknowledge(authed,job[1]!);
    if(method==="POST" && path==="/v1/assist")return await assist(authed,await readJsonObject(request));
    if(method==="GET" && path==="/v1/sponsorship/offers")return await offers(authed);
    if(method==="POST" && path==="/v1/sponsorship/windows") {
      if(!managedStatus(env).available)throw new HttpError(503,"MANAGED_UNAVAILABLE","Managed rendering is unavailable.");
      return await createWindow(authed,await readJsonObject(request),cheapestPrice(env));
    }
    if(method==="POST" && ["/v1/sponsorship/report","/v1/sponsorship/dismiss"].includes(path))return await sponsorAction(authed,await readJsonObject(request),path.endsWith("dismiss"));
    throw new HttpError(404,"NOT_FOUND","Route not found.");
  } catch(e) {
    if(e instanceof HttpError)return errorResponse(e);
    console.error(JSON.stringify({event:"gateway.request_failed"}));
    return errorResponse(new HttpError(500,"INTERNAL","The request could not be completed. Retry with the same request identifier."));
  }
}
export async function maintenance(env:Env,deps:Deps=defaultDeps):Promise<void> {
  const ctx:Ctx={env,deps,request:new Request("https://gateway.invalid/maintenance"),url:new URL("https://gateway.invalid/maintenance"),ip:"scheduled"};
  await recoverJobs(ctx);
  const deletions=await env.DB.prepare("SELECT DISTINCT account_id FROM account_deletion_receipts WHERE completed_at IS NULL LIMIT 100").all<{account_id:string}>();
  for(const row of deletions.results)await finishAccountDeletion(env,row.account_id,deps.now());
  await settleWindows(env,deps.now());
  await env.DB.prepare("DELETE FROM job_results WHERE job_id IN(SELECT j.id FROM jobs j JOIN accounts a ON a.id=j.account_id WHERE a.deleted_at IS NOT NULL)").run();
  await env.DB.prepare("DELETE FROM account_deletion_receipts WHERE completed_at IS NOT NULL AND completed_at<=?").bind(deps.now()-DELETION_RECEIPT_TTL_MS).run();
  const rows=await env.DB.prepare("SELECT DISTINCT account_id FROM transactions WHERE status='pending_prerequisite' AND revoked_at IS NULL LIMIT 100").all<{account_id:string}>();
  for(const row of rows.results)await releasePending(env,row.account_id,deps.now());
}
export default {
  fetch(request: Request, env: Env): Promise<Response> { return handle(request,env); },
  async scheduled(_event:ScheduledController,env:Env):Promise<void>{await maintenance(env);},
} satisfies ExportedHandler<Env>;
