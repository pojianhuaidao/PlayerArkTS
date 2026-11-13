/**
 * SMB 所需密码学实现（纯 ArkTS，32 位整数运算，不依赖 cryptoFramework）：
 *   - MD4 / MD5：NTLM 认证（NTOWFv1、NTProofStr）
 *   - HMAC-MD5：NTLMv2 响应与会话基密钥
 *   - SHA256 / HMAC-SHA256：SMB2 报文签名
 *   - RC4：NTLM key exchange（保留能力）
 * 全部算法已用标准测试向量校验（MD4 "password"=8846f7ea…、HMAC-MD5 RFC2202、RC4 "Key"…）。
 */

const MD5_K: number[] = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391
];
const MD5_S: number[] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
];
const SHA256_K: number[] = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];

/** 字节数组工具 */
export class Bytes {
  static ascii(s: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) {
      out[i] = s.charCodeAt(i) & 0xff;
    }
    return out;
  }

  /** 字节数组按 ASCII/Latin-1 还原成字符串（HTTP 请求头解析用） */
  static fromAscii(u: Uint8Array): string {
    let out: string = '';
    for (let i = 0; i < u.length; i++) {
      out += String.fromCharCode(u[i] & 0xff);
    }
    return out;
  }

  /** UTF-16LE（NTLM 字符串编码） */
  static utf16le(s: string): Uint8Array {
    const out: Uint8Array = new Uint8Array(s.length * 2);
    for (let i = 0; i < s.length; i++) {
      const c: number = s.charCodeAt(i);
      out[i * 2] = c & 0xff;
      out[i * 2 + 1] = (c >> 8) & 0xff;
    }
    return out;
  }

  static hex(u: Uint8Array): string {
    let s: string = '';
    for (let i = 0; i < u.length; i++) {
      const h: string = u[i].toString(16);
      s += h.length === 1 ? `0${h}` : h;
    }
    return s;
  }

  static concat(a: Uint8Array, b: Uint8Array): Uint8Array {
    const out: Uint8Array = new Uint8Array(a.length + b.length);
    out.set(a, 0);
    out.set(b, a.length);
    return out;
  }

  static random(n: number): Uint8Array {
    const out: Uint8Array = new Uint8Array(n);
    for (let i = 0; i < n; i++) {
      out[i] = Math.floor(Math.random() * 256) & 0xff;
    }
    return out;
  }

  static slice(u: Uint8Array, start: number, len: number): Uint8Array {
    const s: number = start < 0 ? 0 : start;
    const e: number = s + len > u.length ? u.length : s + len;
    return u.slice(s, e);
  }
}

export class SmbHash {
  private static rotl(x: number, n: number): number {
    return ((x << n) | (x >>> (32 - n))) | 0;
  }

  private static rotr(x: number, n: number): number {
    return ((x >>> n) | (x << (32 - n))) | 0;
  }

  /** MD4/MD5 的小端长度填充 */
  private static padLE(data: Uint8Array): Uint8Array {
    const len: number = data.length;
    const bitLen: number = len * 8;
    let extra: number = 64 - ((len + 9) % 64);
    if (extra === 64) {
      extra = 0;
    }
    const total: number = len + 9 + extra;
    const out: Uint8Array = new Uint8Array(total);
    out.set(data, 0);
    out[len] = 0x80;
    // 64 位长度：低 32 位在前（小端）
    const lo: number = bitLen >>> 0;
    const hi: number = Math.floor(bitLen / 4294967296);
    for (let i = 0; i < 4; i++) {
      out[total - 8 + i] = (lo >>> (i * 8)) & 0xff;
      out[total - 4 + i] = (hi >>> (i * 8)) & 0xff;
    }
    return out;
  }

  /** SHA256 的大端长度填充 */
  private static padBE(data: Uint8Array): Uint8Array {
    const len: number = data.length;
    const bitLen: number = len * 8;
    let extra: number = 64 - ((len + 9) % 64);
    if (extra === 64) {
      extra = 0;
    }
    const total: number = len + 9 + extra;
    const out: Uint8Array = new Uint8Array(total);
    out.set(data, 0);
    out[len] = 0x80;
    const lo: number = bitLen >>> 0;
    const hi: number = Math.floor(bitLen / 4294967296);
    for (let i = 0; i < 4; i++) {
      out[total - 8 + i] = (hi >>> ((3 - i) * 8)) & 0xff;
      out[total - 4 + i] = (lo >>> ((3 - i) * 8)) & 0xff;
    }
    return out;
  }

  private static leWord(b: Uint8Array, o: number): number {
    return (b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)) | 0;
  }

  static md5(data: Uint8Array): Uint8Array {
    const msg: Uint8Array = SmbHash.padLE(data);
    let a0: number = 0x67452301 | 0;
    let b0: number = 0xefcdab89 | 0;
    let c0: number = 0x98badcfe | 0;
    let d0: number = 0x10325476 | 0;
    for (let off = 0; off < msg.length; off += 64) {
      const m: number[] = [];
      for (let i = 0; i < 16; i++) {
        m.push(SmbHash.leWord(msg, off + i * 4));
      }
      let a: number = a0;
      let b: number = b0;
      let c: number = c0;
      let d: number = d0;
      for (let i = 0; i < 64; i++) {
        let f: number = 0;
        let g: number = 0;
        if (i < 16) {
          f = (b & c) | (~b & d);
          g = i;
        } else if (i < 32) {
          f = (d & b) | (~d & c);
          g = (5 * i + 1) % 16;
        } else if (i < 48) {
          f = b ^ c ^ d;
          g = (3 * i + 5) % 16;
        } else {
          f = c ^ (b | ~d);
          g = (7 * i) % 16;
        }
        f = (f + a + MD5_K[i] + m[g]) | 0;
        const tmp: number = d;
        d = c;
        c = b;
        b = (b + SmbHash.rotl(f, MD5_S[i])) | 0;
        a = tmp;
      }
      a0 = (a0 + a) | 0;
      b0 = (b0 + b) | 0;
      c0 = (c0 + c) | 0;
      d0 = (d0 + d) | 0;
    }
    const out: Uint8Array = new Uint8Array(16);
    const st: number[] = [a0, b0, c0, d0];
    for (let w = 0; w < 4; w++) {
      for (let i = 0; i < 4; i++) {
        out[w * 4 + i] = (st[w] >>> (i * 8)) & 0xff;
      }
    }
    return out;
  }

  static md4(data: Uint8Array): Uint8Array {
    const msg: Uint8Array = SmbHash.padLE(data);
    let a0: number = 0x67452301 | 0;
    let b0: number = 0xefcdab89 | 0;
    let c0: number = 0x98badcfe | 0;
    let d0: number = 0x10325476 | 0;
    for (let off = 0; off < msg.length; off += 64) {
      const x: number[] = [];
      for (let i = 0; i < 16; i++) {
        x.push(SmbHash.leWord(msg, off + i * 4));
      }
      let a: number = a0;
      let b: number = b0;
      let c: number = c0;
      let d: number = d0;
      // 第 1 轮
      for (let i = 0; i < 16; i++) {
        const k1: number = i;
        const s1: number = [3, 7, 11, 19][i % 4];
        const f1: number = (b & c) | (~b & d);
        const t: number = SmbHash.rotl((a + f1 + x[k1]) | 0, s1);
        a = d;
        d = c;
        c = b;
        b = t;
      }
      // 第 2 轮
      for (let i = 0; i < 16; i++) {
        const k2: number = (i % 4) * 4 + Math.floor(i / 4);
        const s2: number = [3, 5, 9, 13][i % 4];
        const f2: number = (b & c) | (b & d) | (c & d);
        const t: number = SmbHash.rotl((a + f2 + x[k2] + 0x5a827999) | 0, s2);
        a = d;
        d = c;
        c = b;
        b = t;
      }
      // 第 3 轮
      const order: number[] = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
      for (let i = 0; i < 16; i++) {
        const k3: number = order[i];
        const s3: number = [3, 9, 11, 15][i % 4];
        const f3: number = b ^ c ^ d;
        const t: number = SmbHash.rotl((a + f3 + x[k3] + 0x6ed9eba1) | 0, s3);
        a = d;
        d = c;
        c = b;
        b = t;
      }
      a0 = (a0 + a) | 0;
      b0 = (b0 + b) | 0;
      c0 = (c0 + c) | 0;
      d0 = (d0 + d) | 0;
    }
    const out: Uint8Array = new Uint8Array(16);
    const st: number[] = [a0, b0, c0, d0];
    for (let w = 0; w < 4; w++) {
      for (let i = 0; i < 4; i++) {
        out[w * 4 + i] = (st[w] >>> (i * 8)) & 0xff;
      }
    }
    return out;
  }

  static hmacMd5(key: Uint8Array, data: Uint8Array): Uint8Array {
    let k: Uint8Array = key;
    if (k.length > 64) {
      k = SmbHash.md5(k);
    }
    const inner: Uint8Array = new Uint8Array(64 + data.length);
    for (let i = 0; i < 64; i++) {
      inner[i] = (i < k.length ? k[i] : 0) ^ 0x36;
    }
    inner.set(data, 64);
    const innerHash: Uint8Array = SmbHash.md5(inner);
    const outer: Uint8Array = new Uint8Array(64 + innerHash.length);
    for (let i = 0; i < 64; i++) {
      outer[i] = (i < k.length ? k[i] : 0) ^ 0x5c;
    }
    outer.set(innerHash, 64);
    return SmbHash.md5(outer);
  }

  static sha256(data: Uint8Array): Uint8Array {
    const msg: Uint8Array = SmbHash.padBE(data);
    let h0: number = 0x6a09e667 | 0;
    let h1: number = 0xbb67ae85 | 0;
    let h2: number = 0x3c6ef372 | 0;
    let h3: number = 0xa54ff53a | 0;
    let h4: number = 0x510e527f | 0;
    let h5: number = 0x9b05688c | 0;
    let h6: number = 0x1f83d9ab | 0;
    let h7: number = 0x5be0cd19 | 0;
    const w: number[] = [];
    for (let i = 0; i < 64; i++) {
      w.push(0);
    }
    for (let off = 0; off < msg.length; off += 64) {
      for (let i = 0; i < 16; i++) {
        const b: number = off + i * 4;
        w[i] = (msg[b] << 24) | (msg[b + 1] << 16) | (msg[b + 2] << 8) | msg[b + 3];
      }
      for (let i = 16; i < 64; i++) {
        const s0: number = (SmbHash.rotr(w[i - 15], 7) ^ SmbHash.rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3)) | 0;
        const s1: number = (SmbHash.rotr(w[i - 2], 17) ^ SmbHash.rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10)) | 0;
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
      }
      let a: number = h0;
      let b2: number = h1;
      let c: number = h2;
      let d: number = h3;
      let e: number = h4;
      let f: number = h5;
      let g: number = h6;
      let h: number = h7;
      for (let i = 0; i < 64; i++) {
        const s1: number = (SmbHash.rotr(e, 6) ^ SmbHash.rotr(e, 11) ^ SmbHash.rotr(e, 25)) | 0;
        const ch: number = (e & f) ^ (~e & g);
        const t1: number = (h + s1 + ch + SHA256_K[i] + w[i]) | 0;
        const s0: number = (SmbHash.rotr(a, 2) ^ SmbHash.rotr(a, 13) ^ SmbHash.rotr(a, 22)) | 0;
        const maj: number = (a & b2) ^ (a & c) ^ (b2 & c);
        const t2: number = (s0 + maj) | 0;
        h = g;
        g = f;
        f = e;
        e = (d + t1) | 0;
        d = c;
        c = b2;
        b2 = a;
        a = (t1 + t2) | 0;
      }
      h0 = (h0 + a) | 0;
      h1 = (h1 + b2) | 0;
      h2 = (h2 + c) | 0;
      h3 = (h3 + d) | 0;
      h4 = (h4 + e) | 0;
      h5 = (h5 + f) | 0;
      h6 = (h6 + g) | 0;
      h7 = (h7 + h) | 0;
    }
    const st: number[] = [h0, h1, h2, h3, h4, h5, h6, h7];
    const out: Uint8Array = new Uint8Array(32);
    for (let i = 0; i < 8; i++) {
      out[i * 4] = (st[i] >>> 24) & 0xff;
      out[i * 4 + 1] = (st[i] >>> 16) & 0xff;
      out[i * 4 + 2] = (st[i] >>> 8) & 0xff;
      out[i * 4 + 3] = st[i] & 0xff;
    }
    return out;
  }

  static hmacSha256(key: Uint8Array, data: Uint8Array): Uint8Array {
    let k: Uint8Array = key;
    if (k.length > 64) {
      k = SmbHash.sha256(k);
    }
    const inner: Uint8Array = new Uint8Array(64 + data.length);
    for (let i = 0; i < 64; i++) {
      inner[i] = (i < k.length ? k[i] : 0) ^ 0x36;
    }
    inner.set(data, 64);
    const innerHash: Uint8Array = SmbHash.sha256(inner);
    const outer: Uint8Array = new Uint8Array(64 + innerHash.length);
    for (let i = 0; i < 64; i++) {
      outer[i] = (i < k.length ? k[i] : 0) ^ 0x5c;
    }
    outer.set(innerHash, 64);
    return SmbHash.sha256(outer);
  }

  static rc4(key: Uint8Array, data: Uint8Array): Uint8Array {
    const s: number[] = [];
    for (let i = 0; i < 256; i++) {
      s.push(i);
    }
    let j: number = 0;
    for (let i = 0; i < 256; i++) {
      j = (j + s[i] + (key.length > 0 ? key[i % key.length] : 0)) & 0xff;
      const t: number = s[i];
      s[i] = s[j];
      s[j] = t;
    }
    const out: Uint8Array = new Uint8Array(data.length);
    let i2: number = 0;
    j = 0;
    for (let n = 0; n < data.length; n++) {
      i2 = (i2 + 1) & 0xff;
      j = (j + s[i2]) & 0xff;
      const t: number = s[i2];
      s[i2] = s[j];
      s[j] = t;
      out[n] = data[n] ^ s[(s[i2] + s[j]) & 0xff];
    }
    return out;
  }
}
