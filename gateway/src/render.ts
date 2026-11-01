import { HttpError, json } from "./errors";
import { decryptSecret, encryptSecret, getKeyRow, loadSecret } from "./custody";
import { imageEdit, imageModels, openaiTarget, customTarget, type OpenAiTarget, type ImageParams } from "./providers";
import { assertSql, balanceDelta, getBalances, ledgerInsert, monthKey, monthSpendAdd, monthSpendRelease, monthSpent } from "./ledger";
import { managedStatus, priceTable, SIZES, QUALITIES } from "./config";
import { settleWindows } from "./sponsors";
import { entitlementEnvironment } from "./storekit";
import type { AuthedCtx, BalanceEnvironment, Ctx, Env } from "./types";
import { LABEL_AI_CONCEPT } from "./types";
import { fromBase64, isGuardFailure, isUuid, sha256Hex } from "./util";

type RenderProvider = "managed" | "openai" | "custom";
interface Quote {
  id:string; account_id:string; provider:RenderProvider; model:string; size:string; quality:string;
  debit_micros:number; funding:"balance"|"sponsor_window"|"provider"; window_id:string|null;
  balance_environment:BalanceEnvironment|null; input_digest:string; destination_digest:string; expires_at:number; used_at:number|null;
}
interface Job extends Quote {
  quote_id:string; request_digest:string; idempotency_key:string; status:"pending"|"succeeded"|"failed";
  error_code:string|null; month_key:string|null; recovery_at:number; result_expires_at:number|null; acknowledged_at:number|null;
}
const getJob=(db:D1Database,accountId:string,id:string)=>db.prepare("SELECT * FROM jobs WHERE account_id=? AND id=?").bind(accountId,id).first<Job>();
function bad(message:string): never {throw new HttpError(400,"INVALID_RENDER",message);}
export async function renderInput(input:Record<string,unknown>):Promise<{digest:string;params:Omit<ImageParams,"model"|"size"|"quality">}> {
  if(input.photo_upload_consent!==true) throw new HttpError(400,"CONSENT_REQUIRED","Explicit consent is required for every cloud image submission.");
  if(typeof input.prompt!=="string" || input.prompt.trim().length===0 || input.prompt.length>8000) bad("A prompt of 1–8000 characters is required.");
  function decode(value:unknown,png:boolean):Uint8Array {
    if(typeof value!=="string" || value.length===0 || value.length>10*1024*1024) bad("Image data is missing or too large.");
    let bytes:Uint8Array;
    try{bytes=fromBase64(value);}catch{bad("Image data must be standard base64.");}
    if(png ? !(bytes[0]===137 && bytes[1]===80 && bytes[2]===78 && bytes[3]===71 && bytes[4]===13 && bytes[5]===10 && bytes[6]===26 && bytes[7]===10) : !(bytes[0]===255 && bytes[1]===216 && bytes[2]===255)) bad("Image bytes do not match the declared media type.");
    return bytes;
  }
  const layout=decode(input.layout_image_png_base64,true);
  let source:ImageParams["source"]=null;
  if(input.source_image_base64!==undefined) {
    if(input.source_media_type!=="image/jpeg" && input.source_media_type!=="image/png") bad("Choose JPEG or PNG for the source image.");
    source={bytes:decode(input.source_image_base64,input.source_media_type==="image/png"),mediaType:input.source_media_type};
  } else if(input.source_media_type!==undefined) bad("Source media type requires source image data.");
  const digest=await sha256Hex(JSON.stringify({prompt:input.prompt,layout:await sha256Hex(layout),source:source ? await sha256Hex(source.bytes):null,media:source?.mediaType??null,consent:true}));
  return {digest,params:{prompt:input.prompt,layoutPng:layout,source}};
}
async function destination(ctx:AuthedCtx,provider:RenderProvider):Promise<{digest:string;target:OpenAiTarget;keyCiphertext:string|null}> {
  if(provider==="managed") {
    const status=managedStatus(ctx.env); if(!status.available) throw new HttpError(503,"MANAGED_UNAVAILABLE",status.reason!);
    return {digest:await sha256Hex(`managed|${ctx.env.OPENAI_MANAGED_KEY}`),target:openaiTarget(ctx.env.OPENAI_MANAGED_KEY!),keyCiphertext:null};
  }
  const {row,secret}=await loadSecret(ctx.env,ctx.accountId,provider);
  return {digest:await sha256Hex(JSON.stringify([row.ciphertext,row.endpoint,row.kek_version])),keyCiphertext:row.ciphertext,
    target:provider==="openai" ? openaiTarget(secret) : customTarget(secret,row.endpoint!,row.endpoint_host!)};
}
export function models(ctx:AuthedCtx):Response {
  const prices=priceTable(ctx.env);
  return json({providers:["managed","openai","custom"].map(provider=>({provider,models:imageModels(ctx.env).map(id=>({id,sizes:SIZES,qualities:QUALITIES,price_micros:provider==="managed" ? prices[id]??{} : null}))}))});
}
export async function quote(ctx:AuthedCtx,input:Record<string,unknown>):Promise<Response> {
  const {env,accountId,deps}=ctx, now=deps.now();
  if(input.provider!=="managed" && input.provider!=="openai" && input.provider!=="custom") bad("Choose a supported image provider.");
  if(typeof input.model!=="string" || !imageModels(env).includes(input.model) || typeof input.size!=="string" || !SIZES.includes(input.size) || typeof input.quality!=="string" || !QUALITIES.includes(input.quality)) bad("Choose a configured model, size, and quality.");
  const render=await renderInput(input), dest=await destination(ctx,input.provider);
  // Validate recovery encryption before money is committed, even for BYOK.
  await encryptSecret(env,accountId,"result-probe","");
  let debit=0,funding:Quote["funding"]="provider",windowId:string|null=null, balanceEnvironment:BalanceEnvironment|null=null;
  if(input.provider==="managed") {
    debit=priceTable(env)[input.model]?.[`${input.size}|${input.quality}`]??0;
    if(debit<=0) bad("No price is configured for this render.");
    balanceEnvironment=entitlementEnvironment(env);
    if(balanceEnvironment==="sandbox" && env.ALLOW_SANDBOX_SPEND!=="true") throw new HttpError(403,"SANDBOX_SPEND_DISABLED","Sandbox paid rendering is disabled.");
    await settleWindows(env,now,accountId);
    const window=balanceEnvironment==="production" ? await env.DB.prepare(`SELECT w.id FROM sponsor_windows w JOIN sponsors s ON s.id=w.sponsor_id JOIN sponsor_offers o ON o.id=w.offer_id
      WHERE w.account_id=?1 AND w.settled_at IS NULL AND w.expires_at>?2 AND w.remaining_micros>=?3 AND s.status='active' AND o.status='active' AND (o.ends_at IS NULL OR o.ends_at>?2)`).bind(accountId,now,debit).first<{id:string}>():null;
    if(window){funding="sponsor_window";windowId=window.id;balanceEnvironment=null;}
    else {
      funding="balance";
      if((await getBalances(env.DB,accountId))[balanceEnvironment!]<debit) throw new HttpError(402,"INSUFFICIENT_CREDIT","Purchase credit or choose your own provider or available sponsorship.");
      const account=await env.DB.prepare("SELECT monthly_cap_micros FROM accounts WHERE id=?").bind(accountId).first<{monthly_cap_micros:number|null}>();
      if(account?.monthly_cap_micros!=null && await monthSpent(env.DB,accountId,now)+debit>account.monthly_cap_micros) throw new HttpError(402,"MONTHLY_CAP_REACHED","The monthly spending limit would be exceeded.");
    }
  }
  const id=deps.uuid(),expires=now+600_000;
  await env.DB.prepare(`INSERT INTO quotes(id,account_id,provider,model,size,quality,debit_micros,funding,created_at,expires_at,input_digest,destination_digest,window_id,balance_environment)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)`).bind(id,accountId,input.provider,input.model,input.size,input.quality,debit,funding,now,expires,render.digest,dest.digest,windowId,balanceEnvironment).run();
  return json({quote_id:id,provider:input.provider,model:input.model,size:input.size,quality:input.quality,debit_micros:debit,funding,expires_at:expires,
    destination_host:dest.target.host,provider_billing:funding==="provider",input_digest:render.digest});
}
export async function refundJob(env:Env,id:string,now:number,code:string,expiredOnly=false):Promise<void> {
  const db=env.DB;
  const row=await db.prepare("SELECT * FROM jobs WHERE id=?").bind(id).first<Job>();
  if(!row || row.status==="failed")return;
  const guard=expiredOnly ? "((status='pending' AND recovery_at<=?2) OR (status='succeeded' AND acknowledged_at IS NULL AND result_expires_at<=?2))" : "status='pending'";
  const stmts=[assertSql(db,`EXISTS(SELECT 1 FROM jobs WHERE id=?1 AND ${guard})`,...(expiredOnly?[id,now]:[id]))];
  if(row.debit_micros>0) {
    stmts.push(ledgerInsert(db,{accountId:row.account_id,source:row.funding==="balance"?"balance":"sponsor_window",environment:row.balance_environment,kind:"job_refund",amount:row.debit_micros,key:`job-refund:${id}`,ref:id,now}));
    if(row.funding==="balance") stmts.push(balanceDelta(db,row.account_id,row.balance_environment!,row.debit_micros,now),monthSpendRelease(db,row.account_id,row.month_key!,row.debit_micros));
    else stmts.push(
      db.prepare("UPDATE sponsor_windows SET remaining_micros=remaining_micros+?2 WHERE id=?1 AND settled_at IS NULL").bind(row.window_id,row.debit_micros),
      db.prepare("UPDATE sponsors SET budget_remaining_micros=budget_remaining_micros+?2 WHERE id=(SELECT sponsor_id FROM sponsor_windows WHERE id=?1 AND settled_at IS NOT NULL)").bind(row.window_id,row.debit_micros),
      db.prepare("UPDATE sponsor_windows SET returned_micros=returned_micros+?2 WHERE id=?1 AND settled_at IS NOT NULL").bind(row.window_id,row.debit_micros));
  }
  stmts.push(db.prepare("UPDATE jobs SET status='failed',error_code=?2,completed_at=?3 WHERE id=?1").bind(id,code,now),db.prepare("DELETE FROM job_results WHERE job_id=?").bind(id));
  try{await db.batch(stmts);}catch(e){if(!isGuardFailure(e))throw e;}
}
export async function jobResponse(ctx:AuthedCtx,id:string):Promise<Response> {
  let row=await getJob(ctx.env.DB,ctx.accountId,id);
  if(!row)throw new HttpError(404,"JOB_NOT_FOUND","No render exists for this account.");
  if((row.status==="pending" && row.recovery_at<=ctx.deps.now()) || (row.status==="succeeded" && !row.acknowledged_at && row.result_expires_at!<=ctx.deps.now())) {
    await refundJob(ctx.env,id,ctx.deps.now(),"RESULT_UNRECOVERABLE",true); row=(await getJob(ctx.env.DB,ctx.accountId,id))!;
  }
  let image:string|undefined;
  const resultExpired=row.status==="succeeded" && row.result_expires_at!==null && row.result_expires_at<=ctx.deps.now();
  if(resultExpired)await ctx.env.DB.prepare("DELETE FROM job_results WHERE job_id=?").bind(id).run();
  if(row.status==="succeeded" && !resultExpired) {
    const parts=await ctx.env.DB.prepare("SELECT * FROM job_results WHERE job_id=? ORDER BY part").bind(id).all<{part:number;ciphertext:string;iv:string;kek_version:number}>();
    if(parts.results.length)image=(await Promise.all(parts.results.map(p=>decryptSecret(ctx.env,ctx.accountId,`result:${id}:${p.part}`,p)))).join("");
  }
  return json({job_id:id,status:row.status,error_code:row.error_code,image_base64:image,media_type:image?"image/png":undefined,debit_micros:row.debit_micros,
    refunded:row.status==="failed" && row.debit_micros>0,provider_billing:row.funding==="provider",funding:row.funding,provider:row.provider,model:row.model,label:LABEL_AI_CONCEPT,
    result_expires_at:row.result_expires_at,result_expired:resultExpired,acknowledged:row.acknowledged_at!==null,balances:await getBalances(ctx.env.DB,ctx.accountId)},row.status==="pending"?202:200);
}
export async function submitJob(ctx:AuthedCtx,input:Record<string,unknown>):Promise<Response> {
  const {env,accountId,deps}=ctx, db=env.DB;
  if(!isUuid(input.quote_id)||!isUuid(input.idempotency_key))bad("quote_id and idempotency_key must be UUIDs.");
  const render=await renderInput(input), requestDigest=await sha256Hex(JSON.stringify([input.quote_id,render.digest]));
  const replay=await db.prepare("SELECT id,request_digest FROM jobs WHERE account_id=? AND idempotency_key=?").bind(accountId,input.idempotency_key).first<{id:string;request_digest:string}>();
  if(replay){if(replay.request_digest!==requestDigest)throw new HttpError(409,"IDEMPOTENCY_MISMATCH","This retry changed the approved render request.");return jobResponse(ctx,replay.id);}
  const q=await db.prepare("SELECT * FROM quotes WHERE id=? AND account_id=?").bind(input.quote_id,accountId).first<Quote>();
  if(!q)throw new HttpError(404,"QUOTE_NOT_FOUND","No quote exists for this account.");
  if(q.input_digest!==render.digest)throw new HttpError(409,"QUOTE_INPUT_CHANGED","Get a new quote for the changed render inputs.");
  const dest=await destination(ctx,q.provider);
  if(q.destination_digest!==dest.digest)throw new HttpError(409,"DESTINATION_CHANGED","The provider key or destination changed; review a new quote.");
  const now=deps.now(), id=deps.uuid(), month=monthKey(now);
  const statements=[
    assertSql(db,"EXISTS(SELECT 1 FROM quotes WHERE id=?1 AND account_id=?2 AND used_at IS NULL AND expires_at>?3 AND input_digest=?4 AND destination_digest=?5)",q.id,accountId,now,render.digest,dest.digest),
    db.prepare("UPDATE quotes SET used_at=?2 WHERE id=?1").bind(q.id,now),
    db.prepare(`INSERT INTO jobs(id,account_id,idempotency_key,quote_id,provider,model,size,quality,debit_micros,funding,balance_environment,window_id,month_key,status,created_at,request_digest,recovery_at)
      VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'pending',?,?,?)`).bind(id,accountId,input.idempotency_key,q.id,q.provider,q.model,q.size,q.quality,q.debit_micros,q.funding,q.balance_environment,q.window_id,month,now,requestDigest,now+600_000),
  ];
  if(dest.keyCiphertext)statements.push(assertSql(db,"EXISTS(SELECT 1 FROM provider_keys WHERE account_id=?1 AND provider=?2 AND ciphertext=?3)",accountId,q.provider,dest.keyCiphertext));
  if(q.provider==="managed") statements.push(db.prepare(`INSERT INTO operator_spend(day_key,spent_micros,cap_micros) VALUES(?,?,?) ON CONFLICT(day_key) DO UPDATE SET spent_micros=spent_micros+excluded.spent_micros,cap_micros=excluded.cap_micros`).bind(new Date(now).toISOString().slice(0,10),q.debit_micros,Number(env.MANAGED_DAILY_LIMIT_MICROS)));
  if(q.debit_micros>0) {
    statements.push(ledgerInsert(db,{accountId,source:q.funding==="balance"?"balance":"sponsor_window",environment:q.balance_environment,kind:"debit",amount:-q.debit_micros,key:`debit:${id}`,ref:id,now}));
    if(q.funding==="balance")statements.push(assertSql(db,`COALESCE((SELECT micros FROM balances WHERE account_id=?1 AND environment=?2),0)
      -COALESCE((SELECT SUM(shortfall_micros) FROM transactions WHERE account_id=?1 AND balance_environment=?2 AND revoked_at IS NOT NULL),0)>=?3`,accountId,q.balance_environment,q.debit_micros),balanceDelta(db,accountId,q.balance_environment!, -q.debit_micros,now),monthSpendAdd(db,accountId,month,q.debit_micros));
    else statements.push(assertSql(db,`EXISTS(SELECT 1 FROM sponsor_windows w JOIN sponsors s ON s.id=w.sponsor_id JOIN sponsor_offers o ON o.id=w.offer_id
      WHERE w.id=?1 AND w.account_id=?2 AND w.expires_at>?3 AND w.settled_at IS NULL AND w.remaining_micros>=?4 AND s.status='active' AND o.status='active' AND (o.ends_at IS NULL OR o.ends_at>?3))`,q.window_id,accountId,now,q.debit_micros),
      db.prepare("UPDATE sponsor_windows SET remaining_micros=remaining_micros-?2 WHERE id=?1").bind(q.window_id,q.debit_micros));
  }
  try{await db.batch(statements);}catch(e){
    if(!isGuardFailure(e))throw e;
    const winner=await db.prepare("SELECT id,request_digest FROM jobs WHERE account_id=? AND idempotency_key=?").bind(accountId,input.idempotency_key).first<{id:string;request_digest:string}>();
    if(winner){if(winner.request_digest!==requestDigest)throw new HttpError(409,"IDEMPOTENCY_MISMATCH","This retry changed the approved render request.");return jobResponse(ctx,winner.id);}
    throw new HttpError(409,"QUOTE_OR_FUNDING_CHANGED","The quote expired, was used, or available funding or budget changed. Refresh before spending.");
  }
  // Only the transaction winner dispatches. No automatic upstream retries, even after an uncertain outcome.
  try {
    const image=await imageEdit(deps,dest.target,{...render.params,model:q.model,size:q.size,quality:q.quality});
    const resultStatements:D1PreparedStatement[]=[assertSql(db,"EXISTS(SELECT 1 FROM jobs j JOIN accounts a ON a.id=j.account_id WHERE j.id=?1 AND j.status='pending' AND j.recovery_at>?2 AND a.deleted_at IS NULL)",id,deps.now())];
    for(let offset=0,part=0;offset<image.length;offset+=256*1024,part++) {
      const encrypted=await encryptSecret(env,accountId,`result:${id}:${part}`,image.slice(offset,offset+256*1024));
      resultStatements.push(db.prepare("INSERT INTO job_results VALUES(?,?,?,?,?)").bind(id,part,encrypted.ciphertext,encrypted.iv,encrypted.kek_version));
    }
    resultStatements.push(db.prepare("UPDATE jobs SET status='succeeded',completed_at=?2,result_expires_at=?3 WHERE id=?1").bind(id,deps.now(),deps.now()+7*86400000));
    await db.batch(resultStatements);
  } catch {
    // Provider acceptance can be ambiguous. The operator absorbs any upstream charge; customer debit is refunded.
    await refundJob(env,id,deps.now(),"PROVIDER_FAILED_OR_UNCERTAIN");
  }
  return jobResponse(ctx,id);
}
export async function acknowledge(ctx:AuthedCtx,id:string):Promise<Response> {
  const result=await ctx.env.DB.prepare("UPDATE jobs SET acknowledged_at=COALESCE(acknowledged_at,?3) WHERE id=?1 AND account_id=?2 AND status='succeeded' AND result_expires_at>?3 RETURNING id").bind(id,ctx.accountId,ctx.deps.now()).first();
  if(!result)throw new HttpError(409,"RESULT_UNAVAILABLE","A retained successful result is required before acknowledgement.");
  return json({ok:true});
}
export async function recoverJobs(ctx:Ctx):Promise<void> {
  const now=ctx.deps.now(),db=ctx.env.DB;
  const expired=await db.prepare("SELECT id FROM jobs WHERE (status='pending' AND recovery_at<=?1) OR (status='succeeded' AND acknowledged_at IS NULL AND result_expires_at<=?1) LIMIT 100").bind(now).all<{id:string}>();
  for(const row of expired.results)await refundJob(ctx.env,row.id,now,"RESULT_UNRECOVERABLE",true);
  await db.prepare("DELETE FROM job_results WHERE job_id IN(SELECT id FROM jobs WHERE acknowledged_at IS NOT NULL AND result_expires_at<=?)").bind(now).run();
}
