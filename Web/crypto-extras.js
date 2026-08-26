// TOTP、パスワード生成、強度推定、Watchtower、同期のマージ。
// Swift 版の同名の処理を移したもので、テストベクタも同じものを使う。

// ============================================================
// ワンタイムパスワード（RFC 6238）
// ============================================================

const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Decode(text) {
  const cleaned = text.toUpperCase().replace(/[=\s-]/g, '');
  if (!cleaned) return null;
  const out = [];
  let buffer = 0;
  let bits = 0;
  for (const character of cleaned) {
    const index = BASE32_ALPHABET.indexOf(character);
    if (index < 0) return null;
    buffer = (buffer << 5) | index;
    bits += 5;
    if (bits >= 8) {
      out.push((buffer >> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return out.length ? new Uint8Array(out) : null;
}

export function base32Encode(bytes) {
  let result = '';
  let buffer = 0;
  let bits = 0;
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      result += BASE32_ALPHABET[(buffer >> (bits - 5)) & 0x1f];
      bits -= 5;
    }
  }
  if (bits > 0) result += BASE32_ALPHABET[(buffer << (5 - bits)) & 0x1f];
  return result;
}

const HASH_NAMES = { SHA1: 'SHA-1', SHA256: 'SHA-256', SHA512: 'SHA-512' };

/// QR コードの中身（otpauth://totp/...）でも、素の Base32 文字列でも受け付ける。
export function parseOTP(raw) {
  const trimmed = (raw ?? '').trim();
  if (!trimmed) return null;

  if (trimmed.toLowerCase().startsWith('otpauth://')) {
    let url;
    try { url = new URL(trimmed); } catch { return null; }
    if (url.host.toLowerCase() !== 'totp') return null;

    const secret = base32Decode(url.searchParams.get('secret') ?? '');
    if (!secret) return null;

    const digits = Number(url.searchParams.get('digits'));
    const period = Number(url.searchParams.get('period'));
    const algorithm = (url.searchParams.get('algorithm') ?? 'SHA1').toUpperCase();

    let issuer = url.searchParams.get('issuer') ?? null;
    let account = null;
    const label = decodeURIComponent(url.pathname.replace(/^\/+/, ''));
    if (label) {
      const separator = label.indexOf(':');
      if (separator >= 0) {
        issuer = issuer ?? label.slice(0, separator);
        account = label.slice(separator + 1).trim();
      } else {
        account = label;
      }
    }
    return {
      secret,
      digits: digits >= 6 && digits <= 8 ? digits : 6,
      period: period > 0 ? period : 30,
      algorithm: HASH_NAMES[algorithm] ? algorithm : 'SHA1',
      issuer, account,
    };
  }

  const secret = base32Decode(trimmed);
  if (!secret) return null;
  return { secret, digits: 6, period: 30, algorithm: 'SHA1', issuer: null, account: null };
}

export async function otpCode(config, date = new Date()) {
  const counter = Math.floor(date.getTime() / 1000 / config.period);
  return otpCodeForCounter(config, counter);
}

export async function otpCodeForCounter(config, counter) {
  const key = await crypto.subtle.importKey(
    'raw', config.secret, { name: 'HMAC', hash: HASH_NAMES[config.algorithm] }, false, ['sign']
  );
  const message = new Uint8Array(8);
  new DataView(message.buffer).setBigUint64(0, BigInt(counter), false);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, message));

  // RFC 4226 の動的切り出し: 最終バイト下位 4 ビットを開始位置に使う
  const offset = mac[mac.length - 1] & 0x0f;
  const truncated = ((mac[offset] & 0x7f) << 24) | (mac[offset + 1] << 16)
                  | (mac[offset + 2] << 8) | mac[offset + 3];
  return String(truncated % 10 ** config.digits).padStart(config.digits, '0');
}

export function otpSecondsRemaining(config, date = new Date()) {
  return config.period - Math.floor(date.getTime() / 1000) % config.period;
}

export function formatOTP(code) {
  return code.length === 6 ? `${code.slice(0, 3)} ${code.slice(3)}` : code;
}

// ============================================================
// パスワード生成
// ============================================================

const AMBIGUOUS = new Set('0O1lI|`\'"~,.;:'.split(''));

export const GENERATOR_SETS = {
  lower: 'abcdefghijklmnopqrstuvwxyz',
  upper: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  digits: '0123456789',
  symbols: '!#$%&()*+-/<=>?@[]^_{|}~',
};

/// 剰余バイアスを避けた一様乱数。`% n` で済ませると小さい値が出やすくなる。
function randomIndex(bound) {
  const limit = Math.floor(0x100000000 / bound) * bound;
  const buffer = new Uint32Array(1);
  let value;
  do {
    crypto.getRandomValues(buffer);
    value = buffer[0];
  } while (value >= limit);
  return value % bound;
}

export function generatePassword(options) {
  const pools = [];
  if (options.lower) pools.push(GENERATOR_SETS.lower);
  if (options.upper) pools.push(GENERATOR_SETS.upper);
  if (options.digits) pools.push(GENERATOR_SETS.digits);
  if (options.symbols) pools.push(GENERATOR_SETS.symbols);

  const filtered = pools
    .map(pool => options.avoidAmbiguous
      ? [...pool].filter(character => !AMBIGUOUS.has(character)).join('')
      : pool)
    .filter(pool => pool.length > 0);
  if (filtered.length === 0) return '';

  const all = filtered.join('');
  const length = Math.max(options.length, filtered.length);

  // 有効にした種類が必ず 1 文字以上入るよう、先に 1 文字ずつ確保してから混ぜる
  const characters = filtered.map(pool => pool[randomIndex(pool.length)]);
  while (characters.length < length) characters.push(all[randomIndex(all.length)]);
  for (let i = characters.length - 1; i > 0; i--) {
    const j = randomIndex(i + 1);
    [characters[i], characters[j]] = [characters[j], characters[i]];
  }
  return characters.join('');
}

export function generatorEntropyBits(options) {
  const pools = [];
  if (options.lower) pools.push(GENERATOR_SETS.lower);
  if (options.upper) pools.push(GENERATOR_SETS.upper);
  if (options.digits) pools.push(GENERATOR_SETS.digits);
  if (options.symbols) pools.push(GENERATOR_SETS.symbols);
  const size = pools
    .map(pool => options.avoidAmbiguous
      ? [...pool].filter(character => !AMBIGUOUS.has(character)).length
      : pool.length)
    .reduce((total, count) => total + count, 0);
  return size > 1 ? options.length * Math.log2(size) : 0;
}

// ============================================================
// 強度の見積もり
// ============================================================
//
// あくまで目安。実際の解読しやすさを保証するものではない。
// 文字種・長さ・繰り返し・並び・ありがちな単語だけを見ている。

const COMMON_PASSWORDS = new Set([
  'password', 'passw0rd', 'letmein', 'welcome', 'admin', 'root', 'qwerty',
  'monkey', 'dragon', 'iloveyou', 'sunshine', 'princess', 'football',
  'baseball', 'abc', 'test', 'guest', 'master', 'login', 'hello',
  'freedom', 'whatever', 'trustno', 'starwars', 'pokemon', 'computer',
]);
const KEYBOARD_RUNS = ['qwerty', 'asdf', 'zxcv', '1234', 'qwertz', 'azerty'];

function characterPoolSize(password) {
  let pool = 0;
  if (/[a-z]/.test(password)) pool += 26;
  if (/[A-Z]/.test(password)) pool += 26;
  if (/[0-9]/.test(password)) pool += 10;
  if (/[^A-Za-z0-9-￿]/.test(password)) pool += 33;
  if (/[-￿]/.test(password)) pool += 200; // 日本語など
  return pool;
}

function isContinuation(previous, current) {
  if (previous === current) return true;
  const a = previous.codePointAt(0);
  const b = current.codePointAt(0);
  if (a > 127 || b > 127) return false;
  return b === a + 1 || b + 1 === a;
}

/// 連続した同じ文字や abc / 123 のような並びは 1 文字分として数えない
function effectiveLength(password) {
  let total = 0;
  let runLength = 0;
  let previous = null;
  for (const character of password) {
    if (previous !== null && isContinuation(previous, character)) {
      runLength += 1;
      total += Math.max(0.25, 1 - runLength * 0.25);
    } else {
      runLength = 0;
      total += 1;
    }
    previous = character;
  }
  return total;
}

export function estimateBits(password) {
  if (!password) return 0;
  const pool = characterPoolSize(password);
  if (pool <= 1) return 0;

  let bits = effectiveLength(password) * Math.log2(pool);
  const uniqueRatio = new Set(password).size / password.length;
  bits *= 0.55 + 0.45 * uniqueRatio;

  const normalized = password.toLowerCase();
  const lettersOnly = normalized.replace(/[^a-z]/g, '');
  if (COMMON_PASSWORDS.has(lettersOnly) || COMMON_PASSWORDS.has(normalized)) {
    return Math.min(bits, 8);
  }
  if ([...COMMON_PASSWORDS].some(word => word.length >= 5 && normalized.includes(word))) bits *= 0.5;
  if (KEYBOARD_RUNS.some(run => normalized.includes(run))) bits *= 0.7;

  return Math.max(bits, 1);
}

export const STRENGTH_LEVELS = [
  { limit: 28, label: 'とても弱い', rank: 0 },
  { limit: 50, label: '弱い', rank: 1 },
  { limit: 80, label: 'まずまず', rank: 2 },
  { limit: 110, label: '強い', rank: 3 },
  { limit: Infinity, label: 'とても強い', rank: 4 },
];

export function strengthLevel(bits) {
  return STRENGTH_LEVELS.find(level => bits < level.limit);
}
