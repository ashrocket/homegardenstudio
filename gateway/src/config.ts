import { HttpError } from "./errors";
import { imageModels } from "./providers";
import type { Env } from "./types";
import { isInt } from "./util";
export const SIZES = ["1024x1024","1536x1024","1024x1536"];
export const QUALITIES = ["low","medium","high"];
export function priceTable(env:Env): Record<string,Record<string,number>> {
  if(!env.MANAGED_PRICE_TABLE) return {};
  try {
    const parsed: unknown=JSON.parse(env.MANAGED_PRICE_TABLE);
    if(!parsed || typeof parsed!=="object" || Array.isArray(parsed)) throw new Error();
    for(const [model,prices] of Object.entries(parsed)) {
      if(!imageModels(env).includes(model) || !prices || typeof prices!=="object" || Array.isArray(prices)) throw new Error();
      for(const [key,value] of Object.entries(prices)) {
        const [size,quality]=key.split("|");
        if(!SIZES.includes(size??"") || !QUALITIES.includes(quality??"") || key!==`${size}|${quality}` || !isInt(value) || value<=0 || value>500_000_000) throw new Error();
      }
    }
    return parsed as Record<string,Record<string,number>>;
  }catch{throw new HttpError(503,"PRICE_CONFIGURATION_INVALID","Managed price configuration is unavailable.");}
}
export function managedStatus(env:Env): {available:boolean;reason:string|null} {
  if(env.MANAGED_RENDER_ENABLED!=="true") return {available:false,reason:"Managed rendering is not enabled."};
  if(!Number.isSafeInteger(Number(env.MANAGED_DAILY_LIMIT_MICROS)) || Number(env.MANAGED_DAILY_LIMIT_MICROS)<=0) return {available:false,reason:"The daily managed spending ceiling is not configured."};
  if(!env.OPENAI_MANAGED_KEY) return {available:false,reason:"Managed provider credentials are not configured."};
  if(!Object.values(priceTable(env)).some(prices=>Object.keys(prices).length)) return {available:false,reason:"Managed prices are not configured."};
  if(!env[`KEK_${Number(env.KEK_CURRENT_VERSION)}`]) return {available:false,reason:"Encrypted result recovery is not configured."};
  return {available:true,reason:null};
}
export function cheapestPrice(env:Env): number { return Math.min(...Object.values(priceTable(env)).flatMap(p=>Object.values(p)),Infinity); }
