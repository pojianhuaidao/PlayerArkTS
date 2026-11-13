/**
 * AES 加解密工具
 * 支持 AES/CBC/PKCS7Padding 和 AES/ECB/PKCS7Padding 解密
 * 以及 $#<key>#$ 加密配置解密 (FindResult)
 */
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer, util } from '@kit.ArkTS';

/** 右补齐到指定长度 */
export function rightPadding(key: string, replace: string, length: number): string {
  const trimmed = key.trim();
  if (trimmed.length > length) return trimmed.substring(0, length);
  if (trimmed.length === length) return trimmed;
  let result = trimmed;
  while (result.length < length) result += replace;
  return result;
}

/** 十六进制字符串转 byte[] (Uint8Array) */
export function hexToBytes(hex: string): Uint8Array {
  const cleanHex = hex.replace(/\s+/g, '');
  const len = Math.floor(cleanHex.length / 2);
  const ret = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    ret[i] = parseInt(cleanHex.substring(i * 2, i * 2 + 2), 16);
  }
  return ret;
}

/** byte[] 转十六进制字符串 */
export function bytesToHex(bytes: Uint8Array): string {
  let hex = '';
  for (let i = 0; i < bytes.length; i++) {
    hex += bytes[i].toString(16).padStart(2, '0');
  }
  return hex;
}

/** Base64 编解码 */
export function base64Encode(data: Uint8Array): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(data, util.Type.BASIC);
}

export function base64Decode(str: string): Uint8Array {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.decodeSync(str);
}

export function base64UrlSafeEncode(data: Uint8Array): string {
  const helper: util.Base64Helper = new util.Base64Helper();
  return helper.encodeToStringSync(data, util.Type.BASIC_URL_SAFE).replace(/=/g, '');
}

export function base64UrlSafeDecode(str: string): Uint8Array {
  const helper: util.Base64Helper = new util.Base64Helper();
  const padded = str + '='.repeat((4 - str.length % 4) % 4);
  return helper.decodeSync(padded.replace(/-/g, '+').replace(/_/g, '/'));
}

/** 判断字符串是否为合法 JSON */
export function isJson(content: string): boolean {
  if (!content || content.length === 0) return false;
  const trimmed = content.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return false;
  try {
    JSON.parse(trimmed);
    return true;
  } catch (_e) {
    return false;
  }
}

/** AES/ECB/PKCS7Padding 解密，data 为十六进制字符串，key 为字符串 */
export async function aesECBDecrypt(hexData: string, key: string): Promise<string> {
  const paddedKey = rightPadding(key, '0', 16);
  const keyBytes = new Uint8Array(buffer.from(paddedKey, 'utf-8').buffer);
  const dataBytes = hexToBytes(hexData);

  const symKey = await createSymKey('AES128', keyBytes);
  const cipher = cryptoFramework.createCipher('AES128|ECB|PKCS7');
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, null);
  const result = await cipher.doFinal({ data: dataBytes });
  return buffer.from(result.data).toString('utf-8');
}

/** AES/CBC/PKCS7Padding 解密，data 为十六进制字符串，key 和 iv 为字符串 */
export async function aesCBCDecrypt(hexData: string, key: string, iv: string): Promise<string> {
  const paddedKey = rightPadding(key, '0', 16);
  const paddedIv = rightPadding(iv, '0', 16);
  const keyBytes = new Uint8Array(buffer.from(paddedKey, 'utf-8').buffer);
  const ivBytes = new Uint8Array(buffer.from(paddedIv, 'utf-8').buffer);
  const dataBytes = hexToBytes(hexData);

  const symKey = await createSymKey('AES128', keyBytes);
  const cipher = cryptoFramework.createCipher('AES128|CBC|PKCS7');
  const ivSpec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: ivBytes }
  };
  await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
  const result = await cipher.doFinal({ data: dataBytes });
  return buffer.from(result.data).toString('utf-8');
}

async function createSymKey(algName: string, keyBytes: Uint8Array): Promise<cryptoFramework.SymKey> {
  const keyGen = cryptoFramework.createSymKeyGenerator(algName);
  const keyBlob: cryptoFramework.DataBlob = { data: keyBytes };
  return await keyGen.convertKey(keyBlob);
}

/**
 * 加密配置解密
 * 处理三种格式:
 * 1. 纯 JSON -> 直接返回
 * 2. [A-Za-z0-9]{8}** 前缀 -> Base64 解码后继续处理
 * 3. "2423" 开头 (即 $#) -> AES/CBC 解密
 * 4. configKey 非空且非 JSON -> AES/ECB 解密
 * @param json 原始响应内容
 * @param configKey 可选的 ECB 解密密钥 (来自 ;pk; 参数)
 */
export async function findResult(json: string, configKey: string | null): Promise<string> {
  let content = json;
  try {
    if (isJson(content)) return content;

    // 检查 [A-Za-z0-9]{8}** 前缀 -> Base64 解码
    const pattern = /[A-Za-z0-9]{8}\*\*/;
    const match = pattern.exec(content);
    if (match) {
      const markerEnd = content.indexOf(match[0]) + 10;
      content = content.substring(markerEnd);
      const decoded = base64Decode(content);
      content = buffer.from(decoded).toString('utf-8');
    }

    content = content.trim();

    if (content.startsWith('2423')) {
      // $#<key>#$ 加密格式
      content = content.replace(/\s+/g, '');
      const idx2324 = content.indexOf('2324');
      const data = content.substring(idx2324 + 4, content.length - 26);

      // hex 解码整个 content 为字符串，再 toLowerCase
      const fullDecoded = buffer.from(hexToBytes(content)).toString('utf-8').toLowerCase();

      const keyStart = fullDecoded.indexOf('$#') + 2;
      const keyEnd = fullDecoded.indexOf('#$');
      const rawKey = fullDecoded.substring(keyStart, keyEnd);
      const key = rightPadding(rawKey, '0', 16);

      const iv13 = fullDecoded.substring(fullDecoded.length - 13);
      const iv = rightPadding(iv13, '0', 16);

      return await aesCBCDecrypt(data, key, iv);
    } else if (configKey !== null && configKey.length > 0 && !isJson(content)) {
      return await aesECBDecrypt(content, configKey);
    } else {
      return content;
    }
  } catch (_e) {
    return json;
  }
}

/** MD5 哈希 */
export async function md5(input: string): Promise<string> {
  const md5Gen = cryptoFramework.createMd('MD5');
  await md5Gen.update({ data: new Uint8Array(buffer.from(input, 'utf-8').buffer) });
  const result = await md5Gen.digest();
  return bytesToHex(result.data);
}
