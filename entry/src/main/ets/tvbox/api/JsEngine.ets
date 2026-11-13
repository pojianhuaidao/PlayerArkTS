/**
 * JsEngine - WebView-based JavaScript execution engine
 * 基于 ArkWeb WebView V8 引擎的脚本执行环境
 *
 * Architecture:
 * - Hidden Web component hosts JS runtime
 * - javaScriptProxy exposes native functions (http, pd, pdfh, pdfa, aesX, etc.)
 * - runJavaScript executes spider code and calls spider methods
 * - Async http handled via polling: JS calls NativeBridge.httpAsync -> gets reqId -> polls httpResult
 *
 * Lifecycle:
 * 1. setWebController() - register WebView from UI component
 * 2. markJsEngineReady() - called after WebView page finishes loading
 * 3. loadSpider(jsCode, key) - evaluates spider JS, stores spider object
 * 4. callSpiderMethod(key, method, argsJson) - calls spider method, returns result
 */
import { webview } from '@kit.ArkWeb';
import { httpGet } from '../utils/HttpUtil';
import {
  nativeHttpAsync, isHttpDone, getHttpResult,
  nativeJoinUrl, nativePdfh, nativePd, nativePdfa, nativePdfla,
  nativeAesX, nativeBase64Encode, nativeBase64Decode, nativeMd5
} from './JsBridge';

export interface JsCallResult {
  success: boolean;
  result: string;
  error: string;
}

interface SpiderState {
  key: string;
  loaded: boolean;
  cat: boolean;
}

const spiderStates: Map<string, SpiderState> = new Map();
let webController: webview.WebviewController | null = null;
let webReady: boolean = false;

class NativeBridge {
  httpAsync(url: string, optionsJson: string): number {
    return nativeHttpAsync(url, optionsJson);
  }
  httpDone(reqId: number): boolean {
    return isHttpDone(reqId);
  }
  httpResult(reqId: number): string {
    return getHttpResult(reqId);
  }
  joinUrl(parent: string, child: string): string {
    return nativeJoinUrl(parent, child);
  }
  pdfh(html: string, rule: string): string {
    return nativePdfh(html, rule);
  }
  pd(html: string, rule: string, addUrl: string): string {
    return nativePd(html, rule, addUrl);
  }
  pdfa(html: string, rule: string): string {
    return nativePdfa(html, rule);
  }
  pdfla(html: string, p1: string, listText: string, listUrl: string, addUrl: string): string {
    return nativePdfla(html, p1, listText, listUrl, addUrl);
  }
  aesX(mode: string, encrypt: boolean, input: string, inBase64: boolean,
       key: string, iv: string, outBase64: boolean): string {
    return nativeAesX(mode, encrypt, input, inBase64, key, iv, outBase64);
  }
  base64Encode(input: string): string {
    return nativeBase64Encode(input);
  }
  base64Decode(input: string): string {
    return nativeBase64Decode(input);
  }
  md5(input: string): string {
    return nativeMd5(input);
  }
  log(msg: string): void {
    console.info('[JsEngine] ' + msg);
  }
  setCallResult(result: string): void {
    callResultStr = result;
    callDoneFlag = true;
  }
}

// Direct call result store - JS calls NativeBridge.setCallResult instead of window.__call_result
const callResultStore: Map<string, string> = new Map();
let callDoneFlag: boolean = false;
let callResultStr: string = '';

const nativeBridge = new NativeBridge();

// Called from JS to set the call result directly (bypasses readJsVariable)
export function setCallResult(result: string): void {
  callResultStr = result;
  callDoneFlag = true;
  console.info('[JsEngine] setCallResult called, length=' + result.length);
}

export function isCallDone(): boolean {
  return callDoneFlag;
}

export function getCallResult(): string {
  return callResultStr;
}

export function resetCallResult(): void {
  callResultStr = '';
  callDoneFlag = false;
}

export function setWebController(controller: webview.WebviewController): void {
  webController = controller;
  webReady = false;
}

export function getNativeBridge(): NativeBridge {
  return nativeBridge;
}

export function isJsEngineReady(): boolean {
  return webReady && webController !== null;
}

export function markJsEngineReady(): void {
  webReady = true;
  console.info('[JsEngine] Engine ready! webController=' + (webController !== null));
}

/**
 * Load a spider JS module into the WebView.
 * The JS code is evaluated in the WebView's global scope.
 * Spider objects are stored in window.__spiders[key].
 *
 * Supports three spider formats:
 * 1. __jsEvalReturn format: code defines __jsEvalReturn() -> returns spider object (cat mode)
 * 2. __JS_SPIDER__ format: code assigns __JS_SPIDER__ = {...}
 * 3. export default format: ES module with default export
 *
 * Returns true on success.
 */
/**
 * Pre-process JS module code: strip ES import statements and provide stubs.
 * WebView 不支持原生模块导入，此处做兼容处理。
 */
function preprocessModuleImports(code: string): string {
  let result = code;
  // Remove side-effect imports: import "url"; import'url'; import "url";
  result = result.replace(/import\s*["'][^"']+["'];?/g, '');
  // Remove default imports: import X from "url"; import X from'url';
  result = result.replace(/import\s+\w+\s+from\s*["'][^"']+["'];?/g, '');
  // Remove named imports: import {X, Y} from "url"; import{X}from"url";
  result = result.replace(/import\s*\{[^}]*\}\s*from\s*["'][^"']+["'];?/g, '');
  // Remove imports with non-ASCII names: import 模板 from "url";
  result = result.replace(/import\s+[^\s;]+\s+from\s*["'][^"']+["'];?/g, '');
  // Remove any remaining import ... from "url";
  result = result.replace(/import\s+[^;]+\s+from\s*["'][^"']+["'];?/g, '');
  // Prepend library stubs
  const stubs = getLibraryStubs();
  result = stubs + '\n' + result;
  return result;
}


function getLibraryStubs(): string {
  const cryptoJsStub: string = 'var CryptoJS = { MD5: function(s) { return { toString: function() { return NativeBridge.md5(String(s)); } }; }, SHA1: function(s) { return { toString: function() { return String(); } }; }, SHA256: function(s) { return { toString: function() { return String(); } }; }, enc: { Hex: { stringify: function(b) { return b && b._str ? b._str : String(b); }, parse: function(s) { var hex = String(s); var str = String(); for (var i = 0; i + 1 < hex.length; i += 2) { str += String.fromCharCode(parseInt(hex.substr(i, 2), 16)); } return { _str: str, _hex: true }; } }, Base64: { stringify: function(b) { if (b && b._b64str) return b._b64str; if (b && b._str) return b._str; return String(b); }, parse: function(s) { return { _str: String(s), _b64str: String(s), _b64: true }; } }, Utf8: { stringify: function(b) { if (!b || !b._str) return String(); return b._str; }, parse: function(s) { return { _str: String(s), _utf8: true }; } } }, AES: { encrypt: function(msg, key, cfg) { var keyStr = key && key._str ? key._str : String(key); var ivStr = cfg && cfg.iv && cfg.iv._str ? cfg.iv._str : String(); var result = NativeBridge.aesX(String.fromCharCode(67,66,67), true, String(msg), false, keyStr, ivStr, true); return { toString: function() { return result; } }; }, decrypt: function(ct, key, cfg) { var keyStr = key && key._str ? key._str : String(key); var ivStr = cfg && cfg.iv && cfg.iv._str ? cfg.iv._str : String(); var inputStr = String(); var inB64 = false; if (ct && ct.ciphertext) { if (ct.ciphertext._b64str) { inputStr = ct.ciphertext._b64str; inB64 = true; } else { inputStr = ct.ciphertext._str || String(ct.ciphertext); } } else if (ct && ct._str) { if (ct._b64str) { inputStr = ct._b64str; inB64 = true; } else { inputStr = ct._str; } } else { inputStr = String(ct); } var result = NativeBridge.aesX(String.fromCharCode(67,66,67), false, inputStr, inB64, keyStr, ivStr, false); return { toString: function(enc) { return result; } }; } }, HmacMD5: function(msg, key) { return { toString: function() { return NativeBridge.md5(String(msg)); } }; }, HmacSHA256: function(msg, key) { return { toString: function() { return String(); } }; }, mode: { ECB: {}, CBC: {}, CFB: {}, OFB: {}, CTR: {} }, pad: { Pkcs7: {}, ZeroPadding: {}, NoPadding: {} }, format: { Hex: {}, OpenSSL: {} } };';
  const cheerioStub: string = 'var cheerio = { load: function(html) { return { html: function() { return html; }, text: function() { return String(html).replace(/<[^>]+>/g, String()); }, find: function() { return this; }, attr: function() { return String(); }, each: function(fn) { return this; }, first: function() { return this; }, last: function() { return this; }, next: function() { return this; }, prev: function() { return this; }, parent: function() { return this; }, children: function() { return []; }, remove: function() { return this; }, addClass: function() { return this; }, removeClass: function() { return this; }, hasClass: function() { return false; }, append: function() { return this; }, before: function() { return this; }, after: function() { return this; } }; }, jinja2: function(template, obj) { return template; }, jp: function(html, rule) { return NativeBridge.pdfh(html, rule); }, min: function(html, rule) { return NativeBridge.pdfh(html, rule); } };';
  const templateStub: string = 'var \u6a21\u677f = { HOST: String(), MOBILE_UA: String.fromCharCode(77,111,122,105,108,108,97,47,53,46,48,32,40,76,105,110,117,120,59,32,65,110,100,114,111,105,100,32,49,50,41,32,65,112,112,108,101,87,101,98,75,105,116,47,53,51,55,46,51,54), PC_UA: String.fromCharCode(77,111,122,105,108,108,97,47,53,46,48,32,40,87,105,110,100,111,119,115,32,78,84,32,49,48,46,48,59,32,87,105,110,54,52,59,32,120,54,52,41,32,65,112,112,108,101,87,101,98,75,105,116,47,53,51,55,46,51,54), pdfh: function(html, rule) { return NativeBridge.pdfh(html, rule); }, pdfa: function(html, rule) { return JSON.parse(NativeBridge.pdfa(html, rule)); }, pd: function(html, rule, url) { return NativeBridge.pd(html, rule, url || String()); }, req: function(url, options) { return req(url, options); }, urljoin: function(base, rel) { return NativeBridge.joinUrl(base, rel); }, getMubans: function() { return {}; }, getRules: function() { return {}; } };';
  const otherStubs: string = 'var gbkTool = function() { return { encode: function(s) { return s; }, decode: function(s) { return s; } }; }; var pako = { deflate: function(d) { throw new Error(String.fromCharCode(110,111,32,100,101,102,108,97,116,101)); }, inflate: function(d) { throw new Error(String.fromCharCode(110,111,32,105,110,102,108,97,116,101)); }, gzip: function(d) { throw new Error(String.fromCharCode(110,111,32,103,122,105,112)); }, ungzip: function(d) { throw new Error(String.fromCharCode(110,111,32,117,110,103,122,105,112)); } }; var JSEncrypt = function() { this.encrypt = function(s) { return s; }; this.decrypt = function(s) { return s; }; this.setPublicKey = function() {}; this.setPrivateKey = function() {}; this.encryptUnicodeLong = function(s) { return s; }; this.decryptUnicodeLong = function(s) { return s; }; }; var NodeRSA = function() { this.encrypt = function(s) { return s; }; this.decrypt = function(s) { return s; }; }; var JSON5 = { parse: function(s) { return JSON.parse(s); }, stringify: function(o) { return JSON.stringify(o); } };';
  return cheerioStub + cryptoJsStub + templateStub + otherStubs;
}

function loadSpider(jsCode: string, key: string): Promise<boolean> {

// Pre-process: strip ES module import statements and add library stubs
let code = preprocessModuleImports(jsCode);

// Transform code for evaluation
let evalCode: string;

if (code.includes('__JS_SPIDER__')) {
  evalCode = code.replace(/__JS_SPIDER__\s*=/, 'window.__spiders[' + JSON.stringify(key) + '] =');
} else if (code.includes('__jsEvalReturn')) {
  evalCode = 'window.req = window.http; window.__spiders[' + JSON.stringify(key) + '] = (function(){'
    + code
    + '; return __jsEvalReturn(); })();';
} else if (code.includes('export default')) {
  // Replace export default { with window.__spiders[key] = {
  evalCode = code.replace(/export\s+default\s*\{/g, 'window.__spiders[' + JSON.stringify(key) + '] = {');
  if (!evalCode.includes('window.__spiders[' + JSON.stringify(key) + ']')) {
    evalCode = code.replace(/export\s+default\s*/, 'window.__spiders[' + JSON.stringify(key) + '] = ');
  }
  evalCode = evalCode.replace(/export\s+(const|let|var|function|class)\s+/g, '$1 ');
} else {
  evalCode = '(function(){ ' + code + ' \n window.__spiders[' + JSON.stringify(key) + '] = typeof __JS_SPIDER__ !== "undefined" ? __JS_SPIDER__ : null; })();';
}

  console.info('[JsEngine] evalCode first 300: ' + evalCode.substring(0, Math.min(300, evalCode.length)));
  console.info('[JsEngine] evalCode last 200: ' + evalCode.substring(Math.max(0, evalCode.length - 200)));
  const dpGuard: string = "(function(){var _odp=Object.defineProperty;if(_odp.__patched)return;var p=function(o,k,d){try{if(o&&typeof o==='object'&&Object.prototype.hasOwnProperty.call(o,k)){try{delete o[k];}catch(e){}}if(d&&typeof d==='object'){d.configurable=true;}return _odp(o,k,d);}catch(e){return o;}};p.__patched=true;try{Object.defineProperty=p;}catch(e){}})();";
  const wrapped = 'try { ' + dpGuard + evalCode + ' } catch(e) { console.error("[JsEngine] loadSpider error:", e.message); window.__spider_error = e.message; }';

// Use callback-based runJavaScript to verify execution
return new Promise<boolean>((resolve) => {
  try {
    webController!.runJavaScript(wrapped, (err: Error, result: string) => {
      if (err) {
        console.error('[JsEngine] loadSpider runJavaScript error: ' + String(err));
        resolve(false);
      } else {
        spiderStates.set(key, { key: key, loaded: true, cat: false });
        webController!.runJavaScript('try { var sp = window.__spiders[' + JSON.stringify(key) + ']; NativeBridge.log("[JsEngine] check spider: " + (sp ? typeof sp : "null") + " error=" + (window.__spider_error || "none")); } catch(e) { NativeBridge.log("[JsEngine] check error: " + e.message); }', () => {});
        console.info('[JsEngine] Spider loaded: ' + key);

        resolve(true);
      }
    });
  } catch (_e) {
    console.error('[JsEngine] loadSpider exception: ' + String(_e));
    resolve(false);
  }
});
}

/**
 * Call a method on a loaded spider.
 * Returns the method result as a JSON string.
 * For async methods (returning Promise), polls until resolved.
 */
export function callSpiderMethod(key: string, method: string, argsJson: string): JsCallResult {
if (!webController) {
  return { success: false, result: '', error: 'No WebviewController' };
}

const state = spiderStates.get(key);
if (!state || !state.loaded) {
  return { success: false, result: '', error: 'Spider not loaded: ' + key };
}

const js = 'try { '
  + 'console.log(\"[JsEngine] JS: calling method on spider\"); var spider = window.__spiders[' + JSON.stringify(key) + ']; console.log(\"[JsEngine] JS: spider=\" + (spider ? typeof spider : \"null\")); '
  + 'if (!spider) { window.__call_result = JSON.stringify({ok:false, error:"spider not found"}); } '
  + 'else if (typeof spider[' + JSON.stringify(method) + '] !== "function") { window.__call_result = JSON.stringify({ok:false, error:"method not found: ' + method + '"}); } '
  + 'else { '
  + '  var args = ' + (argsJson.length > 0 ? argsJson : '[]') + '; '
  + '  var result = spider[' + JSON.stringify(method) + '].apply(spider, args); '
  + '  if (result && typeof result.then === "function") { '
  + '    result.then(function(r) { window.__call_result = JSON.stringify({ok:true, result:r}); })'
  + '      .catch(function(e) { window.__call_result = JSON.stringify({ok:false, error:String(e)}); }); '
  + '  } else { window.__call_result = JSON.stringify({ok:true, result:result}); } '
  + '} '
  + '} catch(e) { window.__call_result = JSON.stringify({ok:false, error:e.message}); }';

try {
  webController.runJavaScript(js);
  return retrieveCallResult();
} catch (e) {
  return { success: false, result: '', error: String(e) };
}
}

/**
 * Retrieve the result of a spider method call.
 * Polls window.__call_result via runJavaScript.
 * Since runJavaScript is async with callback, we use a sync polling approach.
 */
function retrieveCallResult(): JsCallResult {
if (!webController) {
  return { success: false, result: '', error: 'No controller' };
}

// The result is set synchronously for non-Promise returns
// For Promise returns, it's set asynchronously
// We use runJavaScriptCodeExt to get the result synchronously
let resultStr = '';

try {
  // Use runJavaScript with callback to get window.__call_result
  // Since we can't do sync, we return a placeholder and poll
  // Actually, runJavaScript in ArkWeb supports a callback
  // But for sync flow, we need a different approach

  // The trick: we set window.__call_result in the previous call
  // Now we read it. For sync results it's already set.
  // For async (Promise), we need to wait.

  // Poll for result with timeout
  const maxWait = 15000;
  const interval = 50;
  let waited = 0;

  while (waited < maxWait) {
    // Check if result is available
    // runJavaScript is async, so we can't get result synchronously
    // We need to use a different mechanism

    // Use evaluateJavaScript with Promise (API 12+)
    // Actually in HarmonyOS, WebviewController.runJavaScript returns void
    // and has a callback variant: runJavaScriptCallback

    // For now, use the callback-based approach
    break;
  }
} catch (_e) {
  // ignore
}

return { success: false, result: resultStr, error: 'Result retrieval not implemented' };
}

/**
 * Async version of callSpiderMethod - properly handles Promise returns.
 * Uses runJavaScriptCallback to retrieve results.
 */
export async function callSpiderMethodAsync(key: string, method: string, argsJson: string): Promise<JsCallResult> {
if (!webController) {
  return { success: false, result: '', error: 'No WebviewController' };
}

const state = spiderStates.get(key);
if (!state || !state.loaded) {
  return { success: false, result: '', error: 'Spider not loaded: ' + key };
}

// Reset call result
resetCallResult();
  const resetJs = 'window.__call_result = null; window.__call_done = false;';
webController.runJavaScript(resetJs);
await sleep(50);

// Build method call
const js = 'try { '
  + 'var spider = window.__spiders[' + JSON.stringify(key) + ']; '
  + 'if (!spider) { NativeBridge.setCallResult(JSON.stringify({ok:false, error:"spider not found"})); } '
  + 'else if (typeof spider[' + JSON.stringify(method) + '] !== "function") { NativeBridge.setCallResult(JSON.stringify({ok:false, error:"method not found: ' + method + '"})); } '
  + 'else { '
  + '  var args = ' + (argsJson.length > 0 ? argsJson : '[]') + '; '
  + '  var result = spider[' + JSON.stringify(method) + '].apply(spider, args); '
  + '  if (result && typeof result.then === "function") { '
  + '    result.then(function(r) { NativeBridge.setCallResult(JSON.stringify({ok:true, result:r})); })'
  + '      .catch(function(e) { NativeBridge.setCallResult(JSON.stringify({ok:false, error:String(e)})); }); '
  + '  } else { NativeBridge.setCallResult(JSON.stringify({ok:true, result:result})); } '
  + '} '
  + '} catch(e) { console.log(\"[JsEngine] method call error: \" + e.message); NativeBridge.setCallResult(JSON.stringify({ok:false, error:String(e)})); }';

webController.runJavaScript(js);

// Poll for result using runJavaScriptCallback
const maxWait = 30000;
const interval = 100;
let waited = 0;

while (waited < maxWait) {
  await sleep(interval);
  waited += interval;
  const done = isCallDone();
  if (done) {
    console.info('[JsEngine] done after ' + waited + 'ms method=' + method);
    const callResult = getCallResult();
    if (callResult && callResult.length > 0) {
      try {
        const parsed = JSON.parse(callResult) as Record<string, Object>;
        const ok = parsed['ok'] !== undefined && parsed['ok'] === true;
        const resultVal = parsed['result'] !== undefined ? JSON.stringify(parsed['result']) : '';
        const errorVal = parsed['error'] !== undefined ? String(parsed['error']) : '';
        console.info('[JsEngine] callResult method=' + method + ' ok=' + ok + ' resultLen=' + resultVal.length + ' resultPreview=' + resultVal.substring(0, Math.min(200, resultVal.length)));
        return { success: ok, result: resultVal, error: errorVal };
      } catch (_e) {
        return { success: false, result: '', error: 'Parse error: ' + callResult };
      }
    }
    return { success: false, result: '', error: 'Empty result' };
  }
}

return { success: false, result: '', error: 'Timeout waiting for JS result' };
}

/**
 * Read a JavaScript variable value from the WebView.
 * Uses runJavaScript with callback.
 */
function readJsVariable(varExpr: string): Promise<string> {
  return new Promise<string>((resolve: (v: string) => void) => {
    if (!webController) {
      resolve('');
      return;
    }
    try {
      webController.runJavaScript(
        'try { String(' + varExpr + '); } catch(e) { String(); }',
        (err: Error, result: string) => {
          if (err) {
            resolve('');
          } else {
            let val: string = result;
            if (val.length >= 2 && val.charAt(0) === '"' && val.charAt(val.length - 1) === '"') {
              try {
                val = String(JSON.parse(val));
              } catch(_e2) {
                // keep original
              }
            }
            resolve(val);
          }
        }
      );
    } catch (_e) {
      resolve('');
    }
  });
}

function sleep(ms: number): Promise<void> {
return new Promise<void>(resolve => setTimeout(resolve, ms));
}

/**
 * Fetch JS spider code from URL.
 * Handles http:// and https:// URLs.
 */
export async function fetchSpiderCode(apiUrl: string): Promise<string> {
console.info('[JsEngine] fetchSpiderCode url: ' + apiUrl);
return await httpGet(apiUrl, undefined, { ttlMs: 0 });
}

/**
 * Initialize a spider: load code and call init(ext).
 */
export async function initSpider(key: string, apiUrl: string, ext: string): Promise<boolean> {
console.info('[JsEngine] initSpider key=' + key + ' api=' + apiUrl + ' ext=' + ext.substring(0, 50));
// Wait for engine ready
let waitCount = 0;
while (!webReady && waitCount < 50) {
  await sleep(100);
  waitCount++;
}
if (!webReady) {
  console.error('[JsEngine] Engine not ready after 5s');
  return false;
}

// Fetch spider JS code
let jsCode: string;
try {
  jsCode = await fetchSpiderCode(apiUrl);
} catch (e) {
  console.error('[JsEngine] Failed to fetch spider code: ' + String(e));
  return false;
}

if (jsCode.length === 0) {
  console.error('[JsEngine] Empty spider code from: ' + apiUrl);
  return false;
}

// Load spider code
const loaded = await loadSpider(jsCode, key);
if (!loaded) {
  return false;
}

// 调用脚本 init(ext) 方法
if (ext.length > 0) {
  const initArgs = JSON.stringify([ext]);
  const initResult = await callSpiderMethodAsync(key, 'init', initArgs);
  if (!initResult.success) {
    console.warn('[JsEngine] Spider init failed: ' + initResult.error + ' result=' + initResult.result);
  }
}

return true;
}

/**
 * Remove a spider from the engine.
 */
export function removeSpider(key: string): void {
if (webController) {
  webController.runJavaScript('delete window.__spiders[' + JSON.stringify(key) + '];');
}
spiderStates.delete(key);
}

/**
 * Clear all spiders.
 */
export function clearAllSpiders(): void {
if (webController) {
  webController.runJavaScript('window.__spiders = {};');
}
spiderStates.clear();
}

/**
 * Check if a spider is loaded.
 */
export function isSpiderLoaded(key: string): boolean {
const state = spiderStates.get(key);
return state !== undefined && state.loaded;
}

/**
 * Get the bootstrap HTML that sets up the JS runtime environment.
 * This HTML is loaded into the WebView as the initial page.
 * It defines the 'http' function and the __spiders container.
 *
 * The 'http' function in JS calls NativeBridge.httpAsync() and polls for result.
 */
export function getBootstrapHtml(): string {
  const parts: string[] = [];
  parts.push('<!DOCTYPE html><html><head><meta charset="utf-8"><title>JsEngine</title></head><body><script>');
  parts.push('window.__spiders = {};');
  parts.push('window.__call_result = null;');
  parts.push('window.__call_done = false;');
  parts.push('window.__read_var_result = "";');

  // _http: synchronous HTTP via busy-wait polling NativeBridge
  // 同步 http 请求实现
  // 忙等实现同步语义以兼容脚本 init()
  parts.push('function _http(url, options) {');
  parts.push('  options = options || {};');
  parts.push('  var reqId = NativeBridge.httpAsync(url, JSON.stringify(options));');
  parts.push('  var maxWait = 100000; var waited = 0;');
  parts.push('  while (!NativeBridge.httpDone(reqId) && waited < maxWait) { waited += 1; if (waited % 200 === 0) { var t = Date.now(); while (Date.now() - t < 20) {} } }');
  parts.push('  if (!NativeBridge.httpDone(reqId)) {');
  parts.push('    return { content: "", headers: {}, ok: false, status: 0, url: url };');
  parts.push('  }');
  parts.push('  var resultJson = NativeBridge.httpResult(reqId);');
  parts.push('  try { return JSON.parse(resultJson); } catch(e) {');
  parts.push('    return { content: "", headers: {}, ok: false, status: 500, url: url };');
  parts.push('  }');
  parts.push('}');

  // http: 根据 options.async 选择异步或同步
  parts.push('function http(url, options) {');
  parts.push('  options = options || {};');
  parts.push('  if (options.async === false) return _http(url, options);');
  parts.push('  return new Promise(function(resolve) {');
  parts.push('    var res = _http(url, options);');
  parts.push('    resolve(res);');
  parts.push('  }).catch(function(err) {');
  parts.push('    return { ok: false, status: 500, url: url, content: "", headers: {} };');
  parts.push('  });');
  parts.push('}');

  // req: sync shortcut (net.js: req = (url, options) => http(url, {async:false, ...options}))
  parts.push('function req(url, options) {');
  parts.push('  options = options || {};');
  parts.push('  options.async = false;');
  parts.push('  return _http(url, options);');
  parts.push('}');

  // request: alias to req (sync)
  parts.push('function request(url, options) { return req(url, options); }');

  // post: sync POST shortcut
  parts.push('function post(url, options) {');
  parts.push('  options = options || {};');
  parts.push('  options.method = "POST";');
  parts.push('  options.async = false;');
  parts.push('  return _http(url, options);');
  parts.push('}');

  // Assign globals
  parts.push('window.http = http;');
  parts.push('window.req = req;');
  parts.push('window.request = request;');
  parts.push('window.post = post;');
  parts.push('window._http = _http;');

  // Native utility functions (from Global.java)
  parts.push('window.joinUrl = function(p, c) { return NativeBridge.joinUrl(p, c); };');
  parts.push('window.pdfh = function(h, r) { return NativeBridge.pdfh(h, r); };');
  parts.push('window.pd = function(h, r, u) { return NativeBridge.pd(h, r, u); };');
  parts.push('window.pdfa = function(h, r) { return JSON.parse(NativeBridge.pdfa(h, r)); };');
  parts.push('window.pdfla = function(h, p1, lt, lu, u) { return JSON.parse(NativeBridge.pdfla(h, p1, lt, lu, u)); };');
  parts.push('window.aesX = function(m, e, i, ib, k, iv, ob) { return NativeBridge.aesX(m, e, i, ib, k, iv, ob); };');
  parts.push('window.base64Encode = function(s) { return NativeBridge.base64Encode(s); };');
  parts.push('window.base64Decode = function(s) { return NativeBridge.base64Decode(s); };');
  parts.push('window.md5 = function(s) { return NativeBridge.md5(s); };');

  // fetch: http 的别名
  parts.push('window.fetch = function(url, options) { options = options || {}; options.async = false; return _http(url, options); };');

  // buildUrl: 拼接带查询参数的 URL
  parts.push("window.buildUrl = function(url, obj) { if (!obj || typeof obj !== 'object') return url; var parts = []; for (var k in obj) { if (obj.hasOwnProperty(k) && obj[k] !== undefined && obj[k] !== null) { parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(obj[k]))); } } if (parts.length === 0) return url; var sep = url.indexOf('?') >= 0 ? '&' : '?'; return url + sep + parts.join('&'); };");

  // Array.prototype.append: 追加元素并返回自身
  parts.push('if (!Array.prototype.append) { Array.prototype.append = function(item) { this.push(item); return this; }; }');

  // console and log
  parts.push('window.log = function(msg) { NativeBridge.log(String(msg)); };');
  parts.push('window.print = function(msg) { NativeBridge.log(String(msg)); };');
  parts.push('window.console = { log: function(msg) { NativeBridge.log(String(msg)); }, error: function(msg) { NativeBridge.log("ERROR: " + String(msg)); }, warn: function(msg) { NativeBridge.log("WARN: " + String(msg)); }, info: function(msg) { NativeBridge.log(String(msg)); }, debug: function(msg) { NativeBridge.log(String(msg)); } };');

  // RSA stubs
  parts.push('window.rsaX = function(mode, pub, encrypt, input, inBase64, key, outBase64) { return input; };');
  parts.push('window.rsaEncrypt = function(data, key, options) { return data; };');
  parts.push('window.rsaDecrypt = function(data, key, options) { return data; };');

  parts.push('console.log("[JsEngine] Bootstrap loaded");');
  parts.push('</script></body></html>');

  return parts.join('\n');
}

/**
 * Called when the WebView finishes loading the bootstrap HTML.
 */
export function onWebViewPageEnd(): void {
markJsEngineReady();
}

/**
 * Get the bootstrap HTML as a data: URL for direct loading in Web component src.
 */
export function getBootstrapDataUrl(): string {
const html: string = getBootstrapHtml();
return 'data:text/html;charset=utf-8,' + encodeURIComponent(html);
}