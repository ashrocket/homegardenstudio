import "reflect-metadata";
import { X509CertificateGenerator, BasicConstraintsExtension, Extension } from "@peculiar/x509";
import { toBase64Url, utf8 } from "../src/util";
import { env } from "cloudflare:workers";
import { describe, it, expect, vi } from "vitest";
import { handle, maintenance } from "../src/index";
import { assertSql, balanceDelta, getBalances, getEntitlements, monthSpent } from "../src/ledger";
import { encryptSecret, decryptSecret, getKeyRow, putKey } from "../src/custody";
import { boundedJson } from "../src/bounded";
import { testProviderKey } from "../src/providers";
import { validateCustomEndpoint, upstreamFetch } from "../src/ssrf";
import { reconcileVerified, PRODUCT_PREFIX, verifyAppleJws, releasePending, CREDIT_PACK_ID, CREDIT_PACK_MICROS, CREDIT_OFFER_DURATION_MS, type TxClaims } from "../src/storekit";
import { refundJob } from "../src/render";
import { settleWindows } from "../src/sponsors";
import type { Ctx, Deps, Env } from "../src/types";

const PNG="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
const now=Date.UTC(2026,10,1,12);
const imageRequest={provider:"managed",model:"gpt-image-2",size:"1024x1024",quality:"low",photo_upload_consent:true,prompt:"Synthetic garden concept",layout_image_png_base64:PNG};
function harness(fetcher:Deps["fetch"] = async()=>new Response(JSON.stringify({data:[{b64_json:PNG}]}),{headers:{"content-type":"application/json"}})) {
  const configured:Env={...env,MANAGED_RENDER_ENABLED:"true",OPENAI_MANAGED_KEY:"test-managed-credential-not-real",MANAGED_DAILY_LIMIT_MICROS:"50000000",MANAGED_PRICE_TABLE:JSON.stringify({"gpt-image-2":{"1024x1024|low":100}}),ENABLE_MAC_UPGRADE:"true",ACCEPT_SANDBOX:"true",ENTITLEMENT_ENVIRONMENT:"production"};
  let time=now;
  const calls=vi.fn(fetcher);
  const deps:Deps={now:()=>time,uuid:()=>crypto.randomUUID(),fetch:calls,trustedRoots:[]};
  const call=(path:string,method="GET",body?:unknown,secret?:string)=>handle(new Request(`https://gateway.invalid${path}`,{method,headers:{"content-type":"application/json",...(secret?{authorization:`Bearer ${secret}`}:{})},body:body===undefined?undefined:JSON.stringify(body)}),configured,deps);
  const account=async()=>{const response=await call("/v1/accounts","POST");expect(response.status).toBe(201);return await response.json() as {account_id:string;secret:string};};
  return {env:configured,deps,calls,call,account,advance:(ms:number)=>{time+=ms;}};
}
async function seedBalance(accountId:string,amount:number,environment="production") {await env.DB.prepare("INSERT INTO balances VALUES(?,?,?,?)").bind(accountId,environment,amount,now).run();}
async function count(table:string) {return (await env.DB.prepare(`SELECT COUNT(*) n FROM ${table}`).first<{n:number}>())!.n;}
async function purchaseContext(h:ReturnType<typeof harness>):Promise<{ctx:Ctx;account:{account_id:string;secret:string};claims:TxClaims}> {
  const account=await h.account();
  const ctx:Ctx={env:h.env,deps:h.deps,request:new Request("https://gateway.invalid"),url:new URL("https://gateway.invalid"),ip:"test"};
  return {ctx,account,claims:{transactionId:"tx1",originalTransactionId:"tx1",bundleId:h.env.BUNDLE_ID,productId:PRODUCT_PREFIX+"unlock.ios",environment:"Production",appAccountToken:account.account_id,revocationDate:null,purchaseDate:now-1000,signedDate:now}};
}
async function funded(h:ReturnType<typeof harness>,balance=1000) {const a=await h.account();await seedBalance(a.account_id,balance);return a;}
async function quoted(h:ReturnType<typeof harness>,a:{secret:string},changes={}) {
  const response=await h.call("/v1/render/quotes","POST",{...imageRequest,...changes},a.secret);expect(response.status).toBe(200);
  return await response.json() as {quote_id:string};
}
async function sponsorSeed() {
  await env.DB.batch([
    env.DB.prepare("INSERT INTO sponsors VALUES('s','Synthetic fixture','democratic_issue','Fixture only','test',1,'active',1000,1000,1)"),
    env.DB.prepare("INSERT INTO sponsor_offers VALUES('o','s','Test disclosure','https://example.invalid/report','active',NULL,NULL,1)"),
    env.DB.prepare("INSERT INTO sponsor_offer_windows VALUES('o',30,100)"),
  ]);
}

describe("D1 atomic ledger",()=>{
  it("debits sufficient credit and exact depletion; missing/overdraw abort the entire batch",async()=>{
    const h=harness(),a=await funded(h,100);
    await env.DB.batch([balanceDelta(env.DB,a.account_id,"production",-10,now)]);
    expect((await getBalances(env.DB,a.account_id)).production).toBe(90);
    await env.DB.batch([balanceDelta(env.DB,a.account_id,"production",-90,now)]);
    expect((await getBalances(env.DB,a.account_id)).production).toBe(0);
    await expect(env.DB.batch([env.DB.prepare("UPDATE accounts SET monthly_cap_micros=99 WHERE id=?").bind(a.account_id),balanceDelta(env.DB,a.account_id,"production",-1,now)])).rejects.toThrow();
    expect((await env.DB.prepare("SELECT monthly_cap_micros FROM accounts WHERE id=?").bind(a.account_id).first())?.monthly_cap_micros).toBeNull();
    await expect(env.DB.batch([balanceDelta(env.DB,a.account_id,"sandbox",-1,now)])).rejects.toThrow();
  });
  it("zero-row business guards roll back earlier writes",async()=>{
    const h=harness(),a=await funded(h);
    await expect(env.DB.batch([balanceDelta(env.DB,a.account_id,"production",100,now),assertSql(env.DB,"0")])).rejects.toThrow();
    expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);
  });
});

describe("custody and destination boundaries",()=>{
  it("keeps rejected key discovery decodable without claiming capabilities",async()=>{
    for(const provider of ["openai","anthropic"] as const)for(const status of [401,403]){
      const h=harness(async()=>new Response(JSON.stringify({error:{message:"private upstream detail"}}),{status,headers:{"content-type":"application/json"}}));
      const result=await testProviderKey(h.deps,h.env,provider,"sk-ant-fixture-not-real",null);
      expect(result).toMatchObject({ok:false,status,discovery:"invalid_response",generation_verified:false,capabilities:{image_generation:false,text:false}});
      expect(result.message).not.toContain("private upstream detail");
      expect(h.calls).toHaveBeenCalledTimes(1);
    }
  });
  it("binds ciphertext to tenant, record purpose, and KEK version",async()=>{
    const h=harness(),a=await h.account(),b=await h.account();
    const encrypted=await encryptSecret(h.env,a.account_id,"openai","fixture-secret");
    expect(await decryptSecret(h.env,a.account_id,"openai",encrypted)).toBe("fixture-secret");
    await expect(decryptSecret(h.env,b.account_id,"openai",encrypted)).rejects.toThrow();
    await expect(decryptSecret(h.env,a.account_id,"custom",encrypted)).rejects.toThrow();
    await expect(decryptSecret(h.env,a.account_id,"openai",{...encrypted,kek_version:2})).rejects.toThrow();
  });
  it("requires provider confirmation and exposes only metadata",async()=>{
    const h=harness(),a=await h.account();
    expect((await h.call("/v1/keys/openai","PUT",{secret:"sk-fixture-not-a-real-provider-key"},a.secret)).status).toBe(400);
    const saved=await h.call("/v1/keys/openai","PUT",{secret:"sk-fixture-not-a-real-provider-key",confirmed_provider:"openai"},a.secret);
    expect(saved.status).toBe(200);expect(await saved.text()).not.toContain("sk-fixture");
    expect((await h.call("/v1/keys/openai","GET",undefined,a.secret)).status).toBe(404);
    const row=await getKeyRow(env.DB,a.account_id,"openai");expect(row?.ciphertext).not.toContain("fixture");
  });
  it("rejects local/IP/ambiguous destinations and never forwards redirects",async()=>{
    for(const host of ["http://example.com","https://127.0.0.1","https://2130706433","https://[::1]","https://foo.local","https://api.openai.com","https://user@example.com","https://example.com?x=1"])expect(()=>validateCustomEndpoint(host)).toThrow();
    const fetcher=vi.fn(async(_input:RequestInfo|URL,_init?:RequestInit)=>new Response(null,{status:302,headers:{location:"http://127.0.0.1"}}));
    await expect(upstreamFetch(fetcher,"https://example.com/models",{headers:{authorization:"fixture"}},{expectHost:"example.com",timeoutMs:100})).rejects.toThrow();
    expect(fetcher).toHaveBeenCalledTimes(1);expect(fetcher.mock.calls[0]?.[1]?.redirect).toBe("manual");
  });
  it("rejects HTML model discovery and never calls image generation to test a key",async()=>{
    const h=harness(async()=>new Response("<html>hello</html>",{headers:{"content-type":"text/html"}}));
    expect((await testProviderKey(h.deps,h.env,"custom","fixture",{url:"https://example.com/v1",host:"example.com"})).ok).toBe(false);
    const good=harness(async()=>new Response(JSON.stringify({data:[{id:"gpt-image-2"}]}),{headers:{"content-type":"application/json"}}));
    const result=await testProviderKey(good.deps,good.env,"openai","fixture",null);
    expect(result.ok).toBe(true);expect(result.capabilities.image_generation).toBe(false);expect(result.generation_verified).toBe(false);expect(good.calls).toHaveBeenCalledTimes(1);
    const anthropic=harness(async()=>new Response(JSON.stringify({unexpected:true}),{headers:{"content-type":"application/json"}}));
    expect((await testProviderKey(anthropic.deps,anthropic.env,"anthropic","sk-ant-fixture-not-real",null)).ok).toBe(false);
    expect(anthropic.calls).toHaveBeenCalledTimes(1);
  });
});

describe("bounded upstream data",()=>{
  it("handles exact byte limit and rejects chunked overflow even with lying headers",async()=>{
    expect(await boundedJson(new Response('{"x":1}',{headers:{"content-type":"application/json"}}),7)).toEqual({x:1});
    const stream=new ReadableStream<Uint8Array>({start(c){c.enqueue(new Uint8Array(8));c.close();}});
    await expect(boundedJson(new Response(stream,{headers:{"content-type":"application/json","content-length":"1"}}),7)).rejects.toThrow();
  });
  it("cancels a slow body and rejects malformed JSON",async()=>{
    let cancelled=false;
    const response=new Response(new ReadableStream({cancel(){cancelled=true;}}),{headers:{"content-type":"application/json"}});
    await expect(boundedJson(response,100,10)).rejects.toThrow("timed out");expect(cancelled).toBe(true);
    await expect(boundedJson(new Response("no",{headers:{"content-type":"application/json"}}),100)).rejects.toThrow();
  });
});

describe("purchase state convergence",()=>{
  it("verifies a signed certificate-chain fixture through the purchase route and rejects tampering/tokenless claims",async()=>{
    const h=harness(),a=await h.account();
    const algorithm={name:"ECDSA",namedCurve:"P-256"};
    const rootKeys=await crypto.subtle.generateKey(algorithm,true,["sign","verify"]) as CryptoKeyPair;
    const intermediateKeys=await crypto.subtle.generateKey(algorithm,true,["sign","verify"]) as CryptoKeyPair;
    const leafKeys=await crypto.subtle.generateKey(algorithm,true,["sign","verify"]) as CryptoKeyPair;
    const dates={notBefore:new Date(now-60000),notAfter:new Date(now+60000),signingAlgorithm:{name:"ECDSA",hash:"SHA-256"}};
    const root=await X509CertificateGenerator.createSelfSigned({...dates,name:"CN=Synthetic test root",keys:rootKeys,extensions:[new BasicConstraintsExtension(true,1,true)]},crypto);
    const intermediate=await X509CertificateGenerator.create({...dates,subject:"CN=Synthetic test intermediate",issuer:root.subject,publicKey:intermediateKeys.publicKey,signingKey:rootKeys.privateKey,
      extensions:[new BasicConstraintsExtension(true,0,true),new Extension("1.2.840.113635.100.6.2.1",false,new Uint8Array([5,0]))]},crypto);
    const leaf=await X509CertificateGenerator.create({...dates,subject:"CN=Synthetic test leaf",issuer:intermediate.subject,publicKey:leafKeys.publicKey,signingKey:intermediateKeys.privateKey,
      extensions:[new BasicConstraintsExtension(false,undefined,true),new Extension("1.2.840.113635.100.6.11.1",false,new Uint8Array([5,0]))]},crypto);
    h.deps.trustedRoots=[root.toString("pem")];
    const payload={transactionId:"signed-fixture",originalTransactionId:"signed-fixture",bundleId:h.env.BUNDLE_ID,productId:PRODUCT_PREFIX+"unlock.ios",environment:"Production",appAccountToken:a.account_id,signedDate:now,purchaseDate:now-1000};
    const sign=async(p:Record<string,unknown>)=>{
      const body=toBase64Url(utf8(JSON.stringify({alg:"ES256",x5c:[leaf.toString("base64"),intermediate.toString("base64"),root.toString("base64")]})))+"."+toBase64Url(utf8(JSON.stringify(p)));
      return body+"."+toBase64Url(new Uint8Array(await crypto.subtle.sign({name:"ECDSA",hash:"SHA-256"},leafKeys.privateKey,utf8(body))));
    };
    const jws=await sign(payload);
    expect((await h.call("/v1/storekit/transactions","POST",{signed_transaction:jws},a.secret)).status).toBe(200);
    expect((await getBalances(env.DB,a.account_id)).production).toBe(2_000_000);
    const parts=jws.split(".");parts[1]=toBase64Url(utf8(JSON.stringify({...payload,productId:PRODUCT_PREFIX+"unlock.bundle"})));
    expect((await h.call("/v1/storekit/transactions","POST",{signed_transaction:parts.join(".")},a.secret)).status).toBe(400);
    const tokenless=await sign({...payload,appAccountToken:undefined});
    expect((await h.call("/v1/storekit/transactions","POST",{signed_transaction:tokenless},a.secret)).status).toBe(403);
    await expect(verifyAppleJws(jws,[])).rejects.toThrow("trusted root");
    const revoked=await sign({...payload,signedDate:now+1,revocationDate:now+1});
    const notification=await sign({notificationType:"REFUND",notificationUUID:crypto.randomUUID(),signedDate:now+1,data:{bundleId:h.env.BUNDLE_ID,signedTransactionInfo:revoked}});
    expect((await h.call("/v1/storekit/notifications","POST",{signedPayload:notification})).status).toBe(200);
    expect((await getBalances(env.DB,a.account_id)).production).toBe(0);
    expect((await h.call("/v1/storekit/notifications","POST",{signedPayload:notification})).status).toBe(200);
    expect((await getBalances(env.DB,a.account_id)).production).toBe(0);
  });
  it("grants once across concurrent submission and replay",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    await Promise.all([reconcileVerified(ctx,claims,account.account_id),reconcileVerified(ctx,claims,account.account_id)]);
    await reconcileVerified(ctx,claims,account.account_id);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(2_000_000);expect(await count("ledger")).toBe(1);
  });
  it("rejects copied purchase ownership and an unsigned route payload",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h),other=await h.account();
    await expect(reconcileVerified(ctx,claims,other.account_id)).rejects.toThrow();
    expect((await h.call("/v1/storekit/transactions","POST",{signed_transaction:"a.b.c"},account.secret)).status).toBe(400);
    await expect(verifyAppleJws("a.b.c",[])).rejects.toThrow();expect(await count("transactions")).toBe(0);
  });
  it("keeps sandbox entitlement and upgrade prerequisite separate from production",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    await reconcileVerified(ctx,{...claims,environment:"Sandbox"},account.account_id);
    await reconcileVerified(ctx,{...claims,transactionId:"upgrade",originalTransactionId:"upgrade",productId:PRODUCT_PREFIX+"upgrade.ios_to_bundle"},account.account_id);
    expect((await getEntitlements(env.DB,account.account_id,"production")).bundle).toBe(false);
    expect((await getEntitlements(env.DB,account.account_id,"production")).ios).toBe(false);
    expect((await getEntitlements(env.DB,account.account_id,"sandbox")).ios).toBe(true);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(0);
  });
  it("releases a pending upgrade once and suspends bundle access after prerequisite revocation",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    const upgrade={...claims,transactionId:"u",originalTransactionId:"u",productId:PRODUCT_PREFIX+"upgrade.ios_to_bundle"};
    await reconcileVerified(ctx,upgrade,account.account_id);expect((await getEntitlements(env.DB,account.account_id)).bundle).toBe(false);
    await reconcileVerified(ctx,claims,account.account_id);await releasePending(h.env,account.account_id,now);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(7_000_000);
    await reconcileVerified(ctx,{...claims,signedDate:now+1,revocationDate:now+1},null,"n1");
    expect((await getEntitlements(env.DB,account.account_id)).bundle).toBe(false);
  });
  it("converges concurrent prerequisite and upgrade submissions",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    await Promise.all([reconcileVerified(ctx,claims,account.account_id),reconcileVerified(ctx,{...claims,transactionId:"u",originalTransactionId:"u",productId:PRODUCT_PREFIX+"upgrade.ios_to_bundle"},account.account_id)]);
    await maintenance(h.env,h.deps);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(7_000_000);expect(await count("ledger")).toBe(2);
  });
  it("persists refund before registration, ignores stale states, and handles later revoke after reversal",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    await reconcileVerified(ctx,{...claims,signedDate:now+2,revocationDate:now+2},null,"refund-first");
    await reconcileVerified(ctx,claims,account.account_id);expect((await getBalances(env.DB,account.account_id)).production).toBe(0);
    await reconcileVerified(ctx,{...claims,signedDate:now+3},null,"reversal");expect((await getBalances(env.DB,account.account_id)).production).toBe(2_000_000);
    const refund={...claims,signedDate:now+4,revocationDate:now+4};
    await reconcileVerified(ctx,refund,null,"refund-two");await reconcileVerified(ctx,refund,null,"refund-two");
    expect((await getBalances(env.DB,account.account_id)).production).toBe(0);
    await reconcileVerified(ctx,{...claims,signedDate:now+5},null,"reversal-two");
    await reconcileVerified(ctx,refund,null,"refund-two");expect((await getBalances(env.DB,account.account_id)).production).toBe(2_000_000);
    await reconcileVerified(ctx,{...claims,signedDate:now+6,revocationDate:now+6},null,"refund-three");expect((await getBalances(env.DB,account.account_id)).production).toBe(0);
  });
  it.each(["pending","unregistered"])("retries a refund snapshot when %s purchase state grants before its commit",async(phase)=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    await env.DB.prepare("INSERT INTO storekit_states VALUES(?,?,NULL,?,?,?,?)").bind(claims.transactionId,now,claims.originalTransactionId,"unlock.ios","Production",account.account_id).run();
    if(phase==="pending")await env.DB.batch([
      env.DB.prepare("INSERT INTO transaction_bindings VALUES(?,?,?)").bind(claims.originalTransactionId,account.account_id,now),
      env.DB.prepare("INSERT INTO transactions(transaction_id,original_transaction_id,account_id,product_id,store_environment,balance_environment,status,created_at) VALUES(?,?,?,'unlock.ios','Production','production','pending_prerequisite',?)").bind(claims.transactionId,claims.originalTransactionId,account.account_id,now),
    ]);
    let interleaved=false;
    const proxied=new Proxy(env.DB,{get(target,name){
      if(name==="batch")return async(statements:D1PreparedStatement[])=>{
        if(!interleaved){
          interleaved=true;
          if(phase==="pending")await releasePending(h.env,account.account_id,now);
          else await reconcileVerified(ctx,claims,account.account_id);
          expect((await getBalances(env.DB,account.account_id)).production).toBe(2_000_000);
        }
        return target.batch(statements);
      };
      const value=Reflect.get(target,name,target);
      return typeof value==="function"?value.bind(target):value;
    }});
    await reconcileVerified({...ctx,env:{...h.env,DB:proxied}},{...claims,signedDate:now+1,revocationDate:now+1},null,"interleaved-refund");
    expect(interleaved).toBe(true);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(0);
    expect(await count("ledger")).toBe(2);
    expect((await env.DB.prepare("SELECT revoked_at FROM transactions WHERE transaction_id=?").bind(claims.transactionId).first<{revoked_at:number}>())?.revoked_at).toBe(now+1);
  });
  it("reserves revoked shortfall against a concurrent render failure refund",async()=>{
    let release:()=>void=()=>{};
    const blocked=new Promise<void>(resolve=>{release=resolve;});
    let accepted:()=>void=()=>{};
    const entered=new Promise<void>(resolve=>{accepted=resolve;});
    const h=harness(async()=>{accepted();await blocked;throw new Error("uncertain provider result");});
    const {ctx,account,claims}=await purchaseContext(h);
    await reconcileVerified(ctx,claims,account.account_id);
    const q=await quoted(h,account);
    const running=h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},account.secret);
    await entered;
    await reconcileVerified(ctx,{...claims,signedDate:now+1,revocationDate:now+1},null,"refund-during-render");
    release();await running;
    expect((await getBalances(env.DB,account.account_id)).production).toBe(0);
    expect((await h.call("/v1/render/quotes","POST",imageRequest,account.secret)).status).toBe(402);
    await reconcileVerified(ctx,{...claims,signedDate:now+2},null,"reverse-after-render");
    expect((await getBalances(env.DB,account.account_id)).production).toBe(2_000_000);
  });
  it("rejects ambiguous equally signed states and grants only permanent known consumables",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    await reconcileVerified(ctx,claims,account.account_id);
    await expect(reconcileVerified(ctx,{...claims,revocationDate:now},null)).rejects.toThrow("Conflicting");
    const credit={...claims,transactionId:"c",originalTransactionId:"c",productId:PRODUCT_PREFIX+"credit.fixture"};
    await expect(reconcileVerified(ctx,credit,account.account_id)).rejects.toThrow("not configured");
    const known={...credit,productId:CREDIT_PACK_ID};
    await reconcileVerified(ctx,known,account.account_id);await reconcileVerified(ctx,known,account.account_id);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(17_000_000);
    await reconcileVerified(ctx,{...known,signedDate:now+1,revocationDate:now+1},null,"unlisted-pack-refund");
    expect((await getBalances(env.DB,account.account_id)).production).toBe(2_000_000);
  });
});

describe("90-day credit offer and permanent purchased credit",()=>{
  it("lists the exact nonexpiring credit offer only during the configured UTC interval",async()=>{
    const h=harness(),a=await h.account();
    const start=now+1000,end=start+CREDIT_OFFER_DURATION_MS;
    h.env.CREDIT_OFFER_START_UTC=new Date(start).toISOString();
    h.env.CREDIT_OFFER_END_UTC=new Date(end).toISOString();
    const catalog=async()=>{
      const response=await h.call("/v1/me","GET",undefined,a.secret);expect(response.status).toBe(200);
      return (await response.json() as {credit_products:unknown[]}).credit_products;
    };
    h.advance(999);expect(await catalog()).toEqual([]); // before start
    h.advance(1);expect(await catalog()).toEqual([{product_id:CREDIT_PACK_ID,credit_micros:CREDIT_PACK_MICROS,
      offer_starts_at:start,offer_ends_at:end,credit_expires:false}]); // inclusive start
    h.advance(CREDIT_OFFER_DURATION_MS-1);expect(await catalog()).toHaveLength(1); // before end
    h.advance(1);expect(await catalog()).toEqual([]); // exclusive end
    expect(h.calls).not.toHaveBeenCalled();expect(await count("ledger")).toBe(0);
  });
  it("fails catalog visibility closed for missing, malformed, non-UTC or non-90-day activation",async()=>{
    const h=harness(),a=await h.account();
    const start=new Date(now).toISOString(),end=new Date(now+CREDIT_OFFER_DURATION_MS).toISOString();
    const windows=[['',''],[start,''],['',end],['2026-02-30T12:00:00Z',end],
      [start.replace('Z','+00:00'),end],[start+' ',end],['launch',end],
      [start,new Date(now+CREDIT_OFFER_DURATION_MS-1).toISOString()],
      [start,new Date(now+CREDIT_OFFER_DURATION_MS+1).toISOString()],[end,start]];
    for(const [starts,ends] of windows) {
      h.env.CREDIT_OFFER_START_UTC=starts!;h.env.CREDIT_OFFER_END_UTC=ends!;
      const response=await h.call("/v1/me","GET",undefined,a.secret);expect(response.status).toBe(200);
      expect((await response.json() as {credit_products:unknown[]}).credit_products).toEqual([]);
    }
    expect(h.calls).not.toHaveBeenCalled();
  });
  it("honors first verified acceptance and replay after the storefront offer ends without expiring credit",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    const end=now+CREDIT_OFFER_DURATION_MS;
    h.env.CREDIT_OFFER_START_UTC=new Date(now).toISOString();h.env.CREDIT_OFFER_END_UTC=new Date(end).toISOString();
    const credit={...claims,productId:CREDIT_PACK_ID,purchaseDate:end-1,signedDate:end};
    h.advance(CREDIT_OFFER_DURATION_MS); // An in-flight Apple purchase arrives after catalog removal.
    await reconcileVerified(ctx,credit,account.account_id);await reconcileVerified(ctx,credit,account.account_id);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(CREDIT_PACK_MICROS);
    expect(await count("ledger")).toBe(1);
    h.env.CREDIT_OFFER_START_UTC="";h.env.CREDIT_OFFER_END_UTC="";
    h.advance(365*86400000);await maintenance(h.env,h.deps);await reconcileVerified(ctx,credit,account.account_id);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(CREDIT_PACK_MICROS);
    expect(await count("ledger")).toBe(1);
    const me=await (await h.call("/v1/me","GET",undefined,account.secret)).json() as {credit_products:unknown[]};
    expect(me.credit_products).toEqual([]);
    // Genuine purchases remain owed even if an App Store removal race leaves the SKU purchasable late.
    await reconcileVerified(ctx,{...credit,transactionId:"late",originalTransactionId:"late",purchaseDate:end+1,signedDate:end+1},account.account_id);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(2*CREDIT_PACK_MICROS);
    expect(await count("ledger")).toBe(2);expect(h.calls).not.toHaveBeenCalled();
  });
  it("repairs an interrupted credit grant after the promotion closes and never grants an unlock",async()=>{
    const h=harness(),{ctx,account,claims}=await purchaseContext(h);
    const credit={...claims,productId:CREDIT_PACK_ID};
    h.env.CREDIT_OFFER_START_UTC=new Date(now).toISOString();h.env.CREDIT_OFFER_END_UTC=new Date(now+CREDIT_OFFER_DURATION_MS).toISOString();
    const original=h.env.DB;let pause=true;
    h.env.DB=new Proxy(original,{get(target,key){
      if(key==="prepare")return (sql:string)=>{
        if(pause && sql.startsWith("SELECT * FROM transactions WHERE account_id=")){pause=false;throw new Error("Synthetic grant interruption");}
        return target.prepare(sql);
      };
      const value=Reflect.get(target,key,target);return typeof value==="function"?value.bind(target):value;
    }});
    await expect(reconcileVerified(ctx,credit,account.account_id)).rejects.toThrow("Synthetic grant interruption");
    h.env.DB=original;h.advance(CREDIT_OFFER_DURATION_MS+1);
    await maintenance(h.env,h.deps);await reconcileVerified(ctx,credit,account.account_id);
    expect((await getBalances(env.DB,account.account_id)).production).toBe(CREDIT_PACK_MICROS);
    expect(await count("ledger")).toBe(1);
    expect(await getEntitlements(env.DB,account.account_id,"production")).toEqual({ios:false,macos:false,bundle:false});
  });
});

describe("render acceptance and recovery",()=>{
  it("requires consent even without a source photo; binds exact image and prompt",async()=>{
    const h=harness(),a=await funded(h);
    expect((await h.call("/v1/render/quotes","POST",{...imageRequest,photo_upload_consent:false},a.secret)).status).toBe(400);
    const q=await quoted(h,a);
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID(),prompt:"changed"},a.secret)).status).toBe(409);
    expect(h.calls).toHaveBeenCalledTimes(0);expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);
  });
  it("recovers an encrypted successful result without another debit or upstream call",async()=>{
    const h=harness(),a=await funded(h),q=await quoted(h,a),body={...imageRequest,...q,idempotency_key:crypto.randomUUID()};
    const first=await h.call("/v1/render/jobs","POST",body,a.secret);expect(first.status).toBe(200);
    const job=await first.json() as {job_id:string;image_base64:string;status:string};expect(job.status).toBe("succeeded");expect(job.image_base64).toBe(PNG);
    const replay=await h.call("/v1/render/jobs","POST",body,a.secret);expect((await replay.json() as {image_base64:string}).image_base64).toBe(PNG);
    expect(h.calls).toHaveBeenCalledTimes(1);expect((await getBalances(env.DB,a.account_id)).production).toBe(900);
    const stored=await env.DB.prepare("SELECT ciphertext FROM job_results").first<{ciphertext:string}>();expect(stored?.ciphertext).not.toContain(PNG);
    const other=await h.account();expect((await h.call(`/v1/render/jobs/${job.job_id}`,"GET",undefined,other.secret)).status).toBe(404);
    expect((await h.call("/v1/render/jobs","POST",{...body,prompt:"changed"},a.secret)).status).toBe(409);
  });
  it("concurrent identical requests dispatch once",async()=>{
    const h=harness(),a=await funded(h),q=await quoted(h,a),body={...imageRequest,...q,idempotency_key:crypto.randomUUID()};
    const responses=await Promise.all([h.call("/v1/render/jobs","POST",body,a.secret),h.call("/v1/render/jobs","POST",body,a.secret)]);
    expect(responses.every(r=>[200,202].includes(r.status))).toBe(true);expect(h.calls).toHaveBeenCalledTimes(1);expect(await count("jobs")).toBe(1);expect((await getBalances(env.DB,a.account_id)).production).toBe(900);
  });
  it("last-credit race atomically leaves one unused quote and one funded job",async()=>{
    const h=harness(),a=await funded(h,100),q1=await quoted(h,a),q2=await quoted(h,a);
    const responses=await Promise.all([q1,q2].map(q=>h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)));
    expect(responses.map(r=>r.status).sort()).toEqual([200,409]);expect(await count("jobs")).toBe(1);expect((await getBalances(env.DB,a.account_id)).production).toBe(0);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM quotes WHERE used_at IS NULL").first<{n:number}>())!.n).toBe(1);
  });
  it("enforces monthly and operator caps atomically; a budget never adds credit",async()=>{
    const h=harness(),a=await funded(h),q=await quoted(h,a);
    await h.call("/v1/me/budget","PUT",{monthly_cap_micros:0},a.secret);
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)).status).toBe(409);
    expect(await count("jobs")).toBe(0);expect(await count("ledger")).toBe(0);expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);
    await h.call("/v1/me/budget","PUT",{monthly_cap_micros:null},a.secret);h.env.MANAGED_DAILY_LIMIT_MICROS="99";
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)).status).toBe(409);expect(await count("operator_spend")).toBe(0);
  });
  it("rejects expired and foreign quotes without consuming them",async()=>{
    const h=harness(),a=await funded(h),b=await funded(h),q=await quoted(h,a);
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},b.secret)).status).toBe(404);
    h.advance(600_000);
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)).status).toBe(409);expect(await count("jobs")).toBe(0);
  });
  it("key rotation invalidates outstanding destination consent",async()=>{
    const h=harness(),a=await h.account();
    await putKey(h.env,a.account_id,"custom",{secret:"fixture-custom-key-000000",confirmed_provider:"custom",endpoint:"https://example.com/v1"},now);
    const q=await quoted(h,a,{provider:"custom"});
    await putKey(h.env,a.account_id,"custom",{secret:"fixture-custom-key-111111",confirmed_provider:"custom",endpoint:"https://example.org/v1"},now+1);
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)).status).toBe(409);expect(h.calls).toHaveBeenCalledTimes(0);
  });
  it("uncertain provider failure refunds once and preserves the operator ceiling",async()=>{
    const h=harness(async()=>{throw new Error("network response lost");}),a=await funded(h),q=await quoted(h,a),body={...imageRequest,...q,idempotency_key:crypto.randomUUID()};
    const first=await h.call("/v1/render/jobs","POST",body,a.secret),job=await first.json() as {job_id:string;status:string;refunded:boolean};
    expect(job.status).toBe("failed");expect(job.refunded).toBe(true);
    await h.call("/v1/render/jobs","POST",body,a.secret);await refundJob(h.env,job.job_id,now,"again");
    expect(h.calls).toHaveBeenCalledTimes(1);expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);expect(await monthSpent(env.DB,a.account_id,now)).toBe(0);
    expect((await env.DB.prepare("SELECT spent_micros FROM operator_spend").first<{spent_micros:number}>())?.spent_micros).toBe(100);
  });
  it("stale committed pending work is refunded rather than redispatched",async()=>{
    const h=harness(),a=await funded(h),q=await quoted(h,a),body={...imageRequest,...q,idempotency_key:crypto.randomUUID()};
    const result=await h.call("/v1/render/jobs","POST",body,a.secret),job=await result.json() as {job_id:string};
    // Simulate process loss after acceptance: remove the completed result and restore only the durable pending state.
    await env.DB.batch([env.DB.prepare("DELETE FROM job_results"),env.DB.prepare("UPDATE jobs SET status='pending',completed_at=NULL,result_expires_at=NULL")]);
    h.advance(600_001);await maintenance(h.env,h.deps);await maintenance(h.env,h.deps);
    expect((await h.call("/v1/render/jobs","POST",body,a.secret)).status).toBe(200);
    expect(h.calls).toHaveBeenCalledTimes(1);expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);
  });
  it("expires unacknowledged results with refund and keeps acknowledged debit",async()=>{
    const h=harness(),a=await funded(h),q=await quoted(h,a);
    const response=await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret),job=await response.json() as {job_id:string};
    h.advance(7*86400000+1);await maintenance(h.env,h.deps);
    expect(await count("job_results")).toBe(0);expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);
    const q2=await quoted(h,a),r2=await h.call("/v1/render/jobs","POST",{...imageRequest,...q2,idempotency_key:crypto.randomUUID()},a.secret),j2=await r2.json() as {job_id:string};
    expect((await h.call(`/v1/render/jobs/${j2.job_id}/ack`,"POST",{},a.secret)).status).toBe(200);
    h.advance(7*86400000+1);
    const expired=await h.call(`/v1/render/jobs/${j2.job_id}`,"GET",undefined,a.secret);
    const expiredBody=await expired.json() as {image_base64?:string;result_expired:boolean};
    expect(expiredBody.image_base64).toBeUndefined();expect(expiredBody.result_expired).toBe(true);
    expect(await count("job_results")).toBe(0);await maintenance(h.env,h.deps);expect((await getBalances(env.DB,a.account_id)).production).toBe(900);
  });
});

describe("finite sponsorship and deletion",()=>{
  it("does not recreate an expired receipt when a previously authenticated retry resumes after maintenance",async()=>{
    const h=harness(),a=await h.account();
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    h.advance(30*86400000-1);
    const original=h.env.DB;
    let pause=true;
    h.env.DB=new Proxy(original,{get(target,key){
      if(key==="batch")return async (statements:D1PreparedStatement[])=>{
        if(pause){pause=false;h.advance(2);await maintenance({...h.env,DB:original},h.deps);}
        return target.batch(statements);
      };
      const value=Reflect.get(target,key,target);
      return typeof value==="function"?value.bind(target):value;
    }});
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    h.env.DB=original;
    expect(await count("account_deletion_receipts")).toBe(0);
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(401);
  });
  it("repeats a lost deletion response without reopening access and expires the receipt before cleanup",async()=>{
    const h=harness(),a=await h.account();
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    expect((await h.call("/v1/me","GET",undefined,a.secret)).status).toBe(401);
    expect((await h.call("/v1/me/budget","PUT",{monthly_cap_micros:1},a.secret)).status).toBe(401);
    expect((await h.call("/v1/keys/openai","PUT",{confirmed_provider:"openai",secret:"sk-test-key-not-a-real-credential"},a.secret)).status).toBe(401);
    expect(await count("account_deletion_receipts")).toBe(1);
    h.advance(30*86400000+1);
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(401);
    await maintenance(h.env,h.deps);
    expect(await count("account_deletion_receipts")).toBe(0);
    expect(h.calls).not.toHaveBeenCalled();
  });
  for(const recovery of ["retry","maintenance"])it(`resumes interrupted deletion through ${recovery} without duplicate refunds`,async()=>{
    const h=harness(),a=await funded(h),q=await quoted(h,a);
    await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret);
    const original=h.env.DB;
    let interrupt=true;
    h.env.DB=new Proxy(original,{get(target,key){
      if(key==="prepare")return (sql:string)=>{
        if(interrupt && sql.startsWith("SELECT id FROM jobs WHERE account_id=")){interrupt=false;throw new Error("Synthetic cleanup interruption");}
        return target.prepare(sql);
      };
      const value=Reflect.get(target,key,target);
      return typeof value==="function"?value.bind(target):value;
    }});
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(500);
    expect((await h.call("/v1/me","GET",undefined,a.secret)).status).toBe(401);
    h.env.DB=original;
    if(recovery==="retry")expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    else await maintenance(h.env,h.deps);
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    expect((await getBalances(env.DB,a.account_id)).production).toBe(1000);
    expect(await count("job_results")).toBe(0);
    expect((await env.DB.prepare("SELECT COUNT(*) n FROM ledger WHERE kind='job_refund'").first<{n:number}>())?.n).toBe(1);
    expect((await env.DB.prepare("SELECT completed_at FROM account_deletion_receipts").first<{completed_at:number}>())?.completed_at).toBe(now);
    expect(h.calls).toHaveBeenCalledTimes(1);
  });
  it("hides funded offers from accounts with enough prepaid credit, including exact cheapest price",async()=>{
    const h=harness(),a=await funded(h,100);await sponsorSeed();
    for(const balance of [100,101,1000]) {
      await env.DB.prepare("UPDATE balances SET micros=? WHERE account_id=?").bind(balance,a.account_id).run();
      const response=await h.call("/v1/sponsorship/offers","GET",undefined,a.secret);
      expect(response.status).toBe(200);expect(await response.json()).toEqual({offers:[]});
      const me=await (await h.call("/v1/me","GET",undefined,a.secret)).json() as {sponsorship_available:boolean};
      expect(me.sponsorship_available).toBe(false);
    }
    expect((await h.call("/v1/sponsorship/windows","POST",{offer_id:"o",minutes:30},a.secret)).status).toBe(409);
    expect(await count("sponsor_windows")).toBe(0);expect(h.calls).not.toHaveBeenCalled();
  });
  it("hides sponsorship and rejects direct acceptance in sandbox even when sandbox spending is enabled",async()=>{
    const h=harness(),a=await h.account();await sponsorSeed();h.env.ENTITLEMENT_ENVIRONMENT="sandbox";
    for(const enabled of ["false","true"]) {
      h.env.ALLOW_SANDBOX_SPEND=enabled;
      expect(await (await h.call("/v1/sponsorship/offers","GET",undefined,a.secret)).json()).toEqual({offers:[]});
      expect((await h.call("/v1/sponsorship/windows","POST",{offer_id:"o",minutes:30},a.secret)).status).toBe(503);
    }
    expect(await count("sponsor_windows")).toBe(0);expect(h.calls).not.toHaveBeenCalled();
  });
  it("hides funded inventory whenever managed rendering is unavailable",async()=>{
    const h=harness(),a=await h.account();await sponsorSeed();
    const unavailable:Partial<Env>[]=[{MANAGED_RENDER_ENABLED:"false"},{MANAGED_DAILY_LIMIT_MICROS:"0"},
      {OPENAI_MANAGED_KEY:""},{MANAGED_PRICE_TABLE:""},{KEK_1:""}];
    for(const change of unavailable) {
      const prior={...h.env};Object.assign(h.env,change);
      const response=await h.call("/v1/sponsorship/offers","GET",undefined,a.secret);
      expect(response.status).toBe(200);expect(await response.json()).toEqual({offers:[]});
      const me=await (await h.call("/v1/me","GET",undefined,a.secret)).json() as {sponsorship_available:boolean};
      expect(me.sponsorship_available).toBe(false);Object.assign(h.env,prior);
    }
    expect(h.calls).not.toHaveBeenCalled();
  });
  it("exposes approved funded inventory only below the cheapest render and never calls a provider",async()=>{
    const h=harness(),a=await funded(h,99);await sponsorSeed();
    for(const balance of [99,0]) {
      await env.DB.prepare("UPDATE balances SET micros=? WHERE account_id=?").bind(balance,a.account_id).run();
      const response=await h.call("/v1/sponsorship/offers","GET",undefined,a.secret);
      expect(response.status).toBe(200);
      const body=await response.json() as {offers:{offer_id:string;windows:{minutes:number;credit_cap_micros:number}[]}[]};
      expect(body.offers.map(o=>o.offer_id)).toEqual(["o"]);
      expect(body.offers[0]!.windows).toEqual([{minutes:30,credit_cap_micros:100}]);
      const me=await (await h.call("/v1/me","GET",undefined,a.secret)).json() as {sponsorship_available:boolean};
      expect(me.sponsorship_available).toBe(true);
    }
    expect(await count("sponsor_windows")).toBe(0);expect(h.calls).not.toHaveBeenCalled();
  });
  it("hides offers without a render-sized funded window or remaining operator allowance",async()=>{
    const h=harness(),a=await h.account();await sponsorSeed();
    await env.DB.prepare("UPDATE sponsor_offer_windows SET credit_cap_micros=99").run();
    expect(await (await h.call("/v1/sponsorship/offers","GET",undefined,a.secret)).json()).toEqual({offers:[]});
    await env.DB.prepare("UPDATE sponsor_offer_windows SET credit_cap_micros=100").run();
    await env.DB.prepare("UPDATE sponsors SET budget_remaining_micros=99").run();
    expect(await (await h.call("/v1/sponsorship/offers","GET",undefined,a.secret)).json()).toEqual({offers:[]});
    await env.DB.prepare("UPDATE sponsors SET budget_remaining_micros=1000").run();
    await env.DB.prepare("INSERT INTO operator_spend VALUES(?,?,?)").bind(new Date(now).toISOString().slice(0,10),49999901,50000000).run();
    expect(await (await h.call("/v1/sponsorship/offers","GET",undefined,a.secret)).json()).toEqual({offers:[]});
    await env.DB.prepare("UPDATE operator_spend SET spent_micros=49999900").run();
    expect((await (await h.call("/v1/sponsorship/offers","GET",undefined,a.secret)).json() as {offers:unknown[]}).offers).toHaveLength(1);
    expect(h.calls).not.toHaveBeenCalled();
  });
  it("has no synthetic inventory by default and enforces one funded window concurrently",async()=>{
    const h=harness(),a=await h.account();expect(await (await h.call("/v1/sponsorship/offers","GET",undefined,a.secret)).json()).toEqual({offers:[]});
    await sponsorSeed();const responses=await Promise.all([1,2].map(()=>h.call("/v1/sponsorship/windows","POST",{offer_id:"o",minutes:30},a.secret)));
    expect(responses.map(r=>r.status).sort()).toEqual([201,409]);expect(await count("sponsor_windows")).toBe(1);
    expect((await env.DB.prepare("SELECT budget_remaining_micros FROM sponsors").first<{budget_remaining_micros:number}>())?.budget_remaining_micros).toBe(900);
  });
  it("races the last window credit and sends late failure refunds to the original sponsor",async()=>{
    const h=harness(),a=await h.account();await sponsorSeed();await h.call("/v1/sponsorship/windows","POST",{offer_id:"o",minutes:30},a.secret);
    const q1=await quoted(h,a),q2=await quoted(h,a);
    const results=await Promise.all([q1,q2].map(q=>h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)));
    expect(results.map(r=>r.status).sort()).toEqual([200,409]);expect((await getBalances(env.DB,a.account_id)).production).toBe(0);
    const job=await env.DB.prepare("SELECT id FROM jobs").first<{id:string}>();
    await env.DB.prepare("UPDATE jobs SET status='pending'").run();
    h.advance(31*60000);await settleWindows(h.env,h.deps.now());await refundJob(h.env,job!.id,h.deps.now(),"late-failure");await settleWindows(h.env,h.deps.now());
    expect((await env.DB.prepare("SELECT budget_remaining_micros FROM sponsors").first<{budget_remaining_micros:number}>())?.budget_remaining_micros).toBe(1000);expect((await getBalances(env.DB,a.account_id)).production).toBe(0);
  });
  it("withdrawn sponsor approval rejects acceptance without spending",async()=>{
    const h=harness(),a=await h.account();await sponsorSeed();await h.call("/v1/sponsorship/windows","POST",{offer_id:"o",minutes:30},a.secret);const q=await quoted(h,a);
    await env.DB.prepare("UPDATE sponsors SET status='paused'").run();
    expect((await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret)).status).toBe(409);expect(await count("jobs")).toBe(0);expect(await count("ledger")).toBe(0);
  });
  it("deletion revokes access, removes custody/results, and prevents stale writes",async()=>{
    const h=harness(),a=await funded(h);await putKey(h.env,a.account_id,"openai",{confirmed_provider:"openai",secret:"sk-test-key-not-a-real-credential"},now);
    const q=await quoted(h,a);await h.call("/v1/render/jobs","POST",{...imageRequest,...q,idempotency_key:crypto.randomUUID()},a.secret);
    expect((await h.call("/v1/me","DELETE",undefined,a.secret)).status).toBe(204);
    expect((await h.call("/v1/me","GET",undefined,a.secret)).status).toBe(401);expect(await count("provider_keys")).toBe(0);expect(await count("job_results")).toBe(0);
    await expect(putKey(h.env,a.account_id,"openai",{confirmed_provider:"openai",secret:"sk-test-key-not-a-real-credential"},now)).rejects.toThrow();
  });
});
