// PassVault web 版のコア部分。画面の描画は含まない。
//
// ファイル形式は Swift 版とバイト単位で互換。
//   ヘッダ 44 バイト: "PVLT"(4) + version u16BE(2) + kdfID u16BE(2)
//                     + iterations u32BE(4) + salt(32)
//   本体: AES-GCM の nonce(12) + 暗号文 + 認証タグ(16)
//   AAD: ヘッダ 44 バイトそのもの（これで反復回数の切り下げ攻撃を防ぐ）
//   鍵: PBKDF2-HMAC-SHA512(パスワードのUTF-8, salt, iterations) の 32 バイト

// ============================================================
// 保管庫の暗号
// ============================================================

export const HEADER_BYTES = 44;
const MAGIC = [0x50, 0x56, 0x4c, 0x54]; // "PVLT"
export const SCHEMA_VERSION = 3;

// Web Crypto の PBKDF2 は Swift 版より 4 倍ほど速いので、同じ体感の重さにするには
// 反復回数を上げる必要がある。反復回数はファイルに記録されるので、
// ここを上げても古い保管庫はそのまま開ける。
export const DEFAULT_ITERATIONS = 1_200_000;

export class VaultError extends Error {}

export function makeHeader(iterations = DEFAULT_ITERATIONS) {
  const salt = crypto.getRandomValues(new Uint8Array(32));
  return buildHeader(1, 1, iterations, salt);
}

function buildHeader(version, kdfID, iterations, salt) {
  const raw = new Uint8Array(HEADER_BYTES);
  raw.set(MAGIC, 0);
  const view = new DataView(raw.buffer);
  view.setUint16(4, version, false);
  view.setUint16(6, kdfID, false);
  view.setUint32(8, iterations, false);
  raw.set(salt, 12);
  return { version, kdfID, iterations, salt, raw };
}

export function decodeHeader(bytes) {
  if (bytes.length < HEADER_BYTES) throw new VaultError('保管庫ファイルが壊れているか、形式が違います。');
  for (let i = 0; i < 4; i++) {
    if (bytes[i] !== MAGIC[i]) throw new VaultError('保管庫ファイルが壊れているか、形式が違います。');
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, HEADER_BYTES);
  const version = view.getUint16(4, false);
  const kdfID = view.getUint16(6, false);
  const iterations = view.getUint32(8, false);
  if (version !== 1) throw new VaultError(`対応していないファイル形式です（version ${version}）。`);
  if (kdfID !== 1) throw new VaultError(`対応していない鍵導出方式です（id ${kdfID}）。`);
  if (iterations === 0) throw new VaultError('保管庫ファイルが壊れているか、形式が違います。');
  return buildHeader(version, kdfID, iterations, bytes.slice(12, HEADER_BYTES));
}

export async function deriveKey(password, header) {
  const material = await crypto.subtle.importKey(
    'raw', new TextEncoder().encode(password), 'PBKDF2', false, ['deriveBits']
  );
  const bits = await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-512', salt: header.salt, iterations: header.iterations },
    material, 256
  );
  return crypto.subtle.importKey('raw', bits, { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

/// Swift の JSONDecoder の iso8601 は小数秒を受け付けないので、ミリ秒を落とす。
export function isoNoMillis(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export async function seal(payload, key, header) {
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const plaintext = new TextEncoder().encode(JSON.stringify(payload));
  const sealed = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, additionalData: header.raw, tagLength: 128 }, key, plaintext
  ));
  const file = new Uint8Array(HEADER_BYTES + 12 + sealed.length);
  file.set(header.raw, 0);
  file.set(nonce, HEADER_BYTES);
  file.set(sealed, HEADER_BYTES + 12);
  return file;
}

export async function open(bytes, key, header) {
  const body = bytes.slice(HEADER_BYTES);
  if (body.length === 0) throw new VaultError('保管庫ファイルが壊れているか、形式が違います。');
  let plaintext;
  try {
    plaintext = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: body.slice(0, 12), additionalData: header.raw, tagLength: 128 },
      key, body.slice(12)
    );
  } catch {
    // 認証タグが合わない。パスワード違いと改ざんは区別できない（区別する必要もない）。
    throw new VaultError('マスターパスワードが違います。');
  }
  return normalizePayload(JSON.parse(new TextDecoder().decode(plaintext)));
}

/// 古い形式（v1 = entries、v2 = 墓標なし）も読めるようにする
export function normalizePayload(raw) {
  if (Array.isArray(raw.items)) {
    return {
      schemaVersion: raw.schemaVersion ?? 2,
      items: raw.items.map(normalizeItem),
      deletions: raw.deletions ?? [],
    };
  }
  if (Array.isArray(raw.entries)) {
    return {
      schemaVersion: 1,
      items: raw.entries.map(entry => ({
        id: entry.id,
        category: 'login',
        title: entry.title ?? '',
        fields: [
          { id: crypto.randomUUID(), label: 'ユーザー名', value: entry.username ?? '', kind: 'username', isCustom: false },
          { id: crypto.randomUUID(), label: 'パスワード', value: entry.password ?? '', kind: 'password', isCustom: false },
          { id: crypto.randomUUID(), label: 'ウェブサイト', value: entry.url ?? '', kind: 'url', isCustom: false },
        ],
        notes: entry.notes ?? '',
        tags: entry.folder ? [entry.folder] : [],
        isFavorite: false,
        oneTimePasswordSecret: '',
        passwordHistory: [],
        createdAt: entry.createdAt,
        updatedAt: entry.updatedAt,
      })),
      deletions: [],
    };
  }
  return { schemaVersion: SCHEMA_VERSION, items: [], deletions: [] };
}

function normalizeItem(item) {
  return {
    id: item.id ?? crypto.randomUUID(),
    category: item.category ?? 'login',
    title: item.title ?? '',
    fields: (item.fields ?? []).map(field => ({
      id: field.id ?? crypto.randomUUID(),
      label: field.label ?? '',
      value: field.value ?? '',
      kind: field.kind ?? 'text',
      isCustom: field.isCustom ?? false,
    })),
    notes: item.notes ?? '',
    tags: item.tags ?? [],
    isFavorite: item.isFavorite ?? false,
    oneTimePasswordSecret: item.oneTimePasswordSecret ?? '',
    passwordHistory: item.passwordHistory ?? [],
    trashedAt: item.trashedAt,
    createdAt: item.createdAt ?? isoNoMillis(),
    updatedAt: item.updatedAt ?? isoNoMillis(),
  };
}

// ============================================================
// 種別
// ============================================================

export const FIELD_KINDS = {
  text: { label: 'テキスト', concealed: false },
  username: { label: 'ユーザー名', concealed: false },
  password: { label: 'パスワード', concealed: true },
  email: { label: 'メールアドレス', concealed: false },
  url: { label: 'URL', concealed: false },
  phone: { label: '電話番号', concealed: false },
  pin: { label: '暗証番号', concealed: true },
  cardNumber: { label: 'カード番号', concealed: true },
  monthYear: { label: '有効期限', concealed: false },
  multiline: { label: '複数行テキスト', concealed: false },
};

export const CATEGORIES = {
  login: {
    name: 'ログイン', otp: true,
    template: [['ユーザー名', 'username'], ['パスワード', 'password'], ['ウェブサイト', 'url']],
    placeholder: 'GitHub',
  },
  secureNote: {
    name: 'セキュアメモ', otp: false,
    template: [], placeholder: '自宅のWi-Fi設定メモ',
  },
  creditCard: {
    name: 'クレジットカード', otp: false,
    template: [['名義人', 'text'], ['カード番号', 'cardNumber'], ['有効期限', 'monthYear'],
               ['セキュリティコード', 'pin'], ['暗証番号', 'pin'], ['カード会社', 'text']],
    placeholder: '楽天カード',
  },
  identity: {
    name: 'ID・個人情報', otp: false,
    template: [['氏名', 'text'], ['生年月日', 'text'], ['住所', 'multiline'],
               ['メールアドレス', 'email'], ['電話番号', 'phone']],
    placeholder: '自分のプロフィール',
  },
  apiCredential: {
    name: 'APIキー', otp: true,
    template: [['サービス名', 'text'], ['APIキー', 'password'], ['エンドポイント', 'url'], ['有効期限', 'text']],
    placeholder: 'OpenAI API',
  },
  wifi: {
    name: 'Wi-Fi', otp: false,
    template: [['ネットワーク名（SSID）', 'text'], ['パスワード', 'password'], ['暗号化方式', 'text']],
    placeholder: '自宅ルーター',
  },
  license: {
    name: 'ライセンス', otp: false,
    template: [['ライセンス名義', 'text'], ['ライセンスキー', 'password'], ['バージョン', 'text'], ['購入元', 'url']],
    placeholder: 'Sketch ライセンス',
  },
};

export function makeItem(category = 'login') {
  const now = isoNoMillis();
  return {
    id: crypto.randomUUID(),
    category,
    title: '',
    fields: CATEGORIES[category].template.map(([label, kind]) => ({
      id: crypto.randomUUID(), label, value: '', kind, isCustom: false,
    })),
    notes: '',
    tags: [],
    isFavorite: false,
    oneTimePasswordSecret: '',
    passwordHistory: [],
    createdAt: now,
    updatedAt: now,
  };
}

export const isConcealed = kind => FIELD_KINDS[kind]?.concealed ?? false;
export const displayTitle = item => item.title.trim() || '名称未設定';
export const primaryPassword = item =>
  item.fields.find(f => f.kind === 'password' && f.value)?.value ?? null;
export const primaryUsername = item =>
  item.fields.find(f => (f.kind === 'username' || f.kind === 'email') && f.value)?.value ?? null;
export const primaryURL = item => item.fields.find(f => f.kind === 'url' && f.value)?.value ?? null;

export function groupedCardNumber(value) {
  const digits = value.replace(/\D/g, '');
  if (digits.length <= 4) return value;
  return digits.match(/.{1,4}/g).join(' ');
}

export function subtitle(item) {
  if (item.category === 'creditCard') {
    const digits = (item.fields.find(f => f.kind === 'cardNumber')?.value ?? '').replace(/\D/g, '');
    if (digits.length >= 4) return '•••• ' + digits.slice(-4);
    return item.fields.find(f => f.kind === 'text' && f.value)?.value ?? '';
  }
  // セキュアメモの中身は一覧に出さない。
  // 秘密を隠すための種別なのに、1 行目を一覧に並べたら意味がなくなる
  // （暗証番号をメモしていた場合、それがそのまま見えてしまう）。
  if (item.category === 'secureNote') {
    const lines = item.notes.trim() ? item.notes.trim().split('\n').length : 0;
    return lines ? `${lines} 行のメモ` : '';
  }
  return primaryUsername(item) ?? primaryURL(item) ?? '';
}

/// 伏せ字の欄は値を検索対象にしない。
/// 検索結果からパスワードの中身が推測できてしまうのを避けるため。
export function matches(item, query) {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  if (displayTitle(item).toLowerCase().includes(q)) return true;
  if (item.tags.some(tag => tag.toLowerCase().includes(q))) return true;
  if (item.notes.toLowerCase().includes(q)) return true;
  return item.fields.some(field => {
    if (isConcealed(field.kind)) return field.label.toLowerCase().includes(q);
    return field.label.toLowerCase().includes(q) || field.value.toLowerCase().includes(q);
  });
}
