/**
 * Byte/signing primitives shared by manifest fixtures. These intentionally avoid Node-only
 * Buffer/TextEncoder APIs so the fixtures exercise the same Hermes-compatible encodings as the
 * production verifier.
 */
/* eslint-disable no-bitwise -- base64 and UTF-8 codecs are inherently byte-twiddling */
import * as ed from '@noble/ed25519';
import { sha256 } from '@noble/hashes/sha2.js';

const BASE64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

export function base64ToBytes(encoded: string): Uint8Array {
  if (encoded.length % 4 !== 0) {
    throw new Error(`bad test base64: ${encoded}`);
  }
  const padding = encoded.endsWith('==') ? 2 : encoded.endsWith('=') ? 1 : 0;
  const out = new Uint8Array((encoded.length / 4) * 3 - padding);
  let buffer = 0;
  let bits = 0;
  let outIndex = 0;
  for (let i = 0; i < encoded.length - padding; i++) {
    const value = BASE64_ALPHABET.indexOf(encoded[i]);
    if (value < 0) {
      throw new Error(`bad test base64: ${encoded}`);
    }
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[outIndex++] = (buffer >> bits) & 0xff;
    }
  }
  return out;
}

export function bytesToBase64(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const chunk = [bytes[i], bytes[i + 1], bytes[i + 2]];
    out += BASE64_ALPHABET[chunk[0] >> 2];
    out += BASE64_ALPHABET[((chunk[0] & 0x03) << 4) | ((chunk[1] ?? 0) >> 4)];
    out +=
      i + 1 < bytes.length
        ? BASE64_ALPHABET[((chunk[1] & 0x0f) << 2) | ((chunk[2] ?? 0) >> 6)]
        : '=';
    out += i + 2 < bytes.length ? BASE64_ALPHABET[chunk[2] & 0x3f] : '=';
  }
  return out;
}

/** UTF-8 encode without ambient TextEncoder (test bodies are well-formed strings). */
export function utf8Bytes(text: string): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < text.length; i++) {
    const code = text.codePointAt(i) as number;
    if (code > 0xffff) {
      i++;
    }
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      out.push(
        0xe0 | (code >> 12),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    } else {
      out.push(
        0xf0 | (code >> 18),
        0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f),
        0x80 | (code & 0x3f),
      );
    }
  }
  return Uint8Array.from(out);
}

/** Lowercase hex of the first eight SHA-256 bytes over the raw public key. */
export function deriveKeyId(publicKey: Uint8Array): string {
  return ed.etc.bytesToHex(sha256(publicKey).slice(0, 8));
}
