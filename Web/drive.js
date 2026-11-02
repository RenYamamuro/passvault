// Google Drive の「アプリ専用フォルダ」に、暗号化済みの保管庫を置く。
//
// ここが扱うのは暗号化済みのバイト列だけで、平文にも鍵にも触れない。
// Google に渡るのは、書き出した .pvlt と同じ読めない塊だけになる。
//
// ログインは Google の画面へ移って戻ってくる方式（OAuth 2.0 のトークン方式）。
// Google が配っているログイン用の部品は読み込まない。解錠済みの保管庫と
// 同じ画面で他人のコードを動かすことになるため。
//
// 許可の範囲は drive.appdata だけ。このアプリが作った隠しフォルダの中にしか
// 触れず、利用者の Drive にある他のファイルは読めも書けもしない。

/// Google Cloud で作った OAuth クライアントの ID。空のあいだは同期の項目を出さない。
export const DRIVE_CLIENT_ID = '514737616951-6cgnvfqlak3cq053g7i8asnvcte3vsru.apps.googleusercontent.com';

const DRIVE_SCOPE = 'https://www.googleapis.com/auth/drive.appdata';
const DRIVE_FILE_NAME = 'vault.pvlt';
const DRIVE_API = 'https://www.googleapis.com/drive/v3';
const DRIVE_UPLOAD = 'https://www.googleapis.com/upload/drive/v3';

// トークンは sessionStorage に置く。Google の画面から戻ってくると
// ページが読み込み直されるので、メモリだけでは持ち越せない。
// タブを閉じれば消え、範囲はアプリ専用フォルダだけ、有効期限は 1 時間。
const DRIVE_TOKEN_KEY = 'passvault.drive.token';
const DRIVE_STATE_KEY = 'passvault.drive.state';
const DRIVE_PENDING_KEY = 'passvault.drive.pending';

/// 通信の差し替え口（検証ページが偽の Drive をつなぐ）
export const driveIO = { fetch: (...args) => fetch(...args) };

export class DriveAuthError extends Error {}

export function driveAvailable() {
  if (!DRIVE_CLIENT_ID) return false;
  // Google は https か localhost にしか戻してくれない
  return location.protocol === 'https:' || location.hostname === 'localhost';
}

/// Google から戻ってくる先。Google Cloud に登録した URI と 1 文字でも違うと断られる。
/// ホーム画面のアプリは index.html で開くので、末尾が / のときもそちらに揃える。
export function driveRedirectURI() {
  const path = location.pathname.endsWith('/') ? `${location.pathname}index.html` : location.pathname;
  return location.origin + path;
}

/// Google のログイン画面へ移る。戻ってきたら driveTakeRedirect で受け取る。
export function driveBeginSignIn() {
  // 戻ってきた応答が、自分の出した依頼への返事であることを確かめる合言葉
  const nonce = [...crypto.getRandomValues(new Uint8Array(16))]
    .map(byte => byte.toString(16).padStart(2, '0')).join('');
  sessionStorage.setItem(DRIVE_STATE_KEY, nonce);
  sessionStorage.setItem(DRIVE_PENDING_KEY, 'sync');
  const params = new URLSearchParams({
    client_id: DRIVE_CLIENT_ID,
    redirect_uri: driveRedirectURI(),
    response_type: 'token',
    scope: DRIVE_SCOPE,
    state: nonce,
    include_granted_scopes: 'true',
  });
  location.assign(`https://accounts.google.com/o/oauth2/v2/auth?${params}`);
}

/// URL の # 以降に Google の応答があれば受け取る。
///
/// 戻り値: null（応答ではない）/ { ok: true } / { ok: false, message }
/// 応答だったときは、呼び出し側で # 以降を消すこと（トークンを URL に残さない）。
export function driveTakeRedirect(hash, now = Date.now()) {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  if (!params.has('access_token') && !params.has('error')) return null;

  const expected = sessionStorage.getItem(DRIVE_STATE_KEY);
  sessionStorage.removeItem(DRIVE_STATE_KEY);
  if (!expected || params.get('state') !== expected) {
    // 自分が出していない依頼への応答。誰かに押し付けられたトークンかもしれない。
    sessionStorage.removeItem(DRIVE_PENDING_KEY);
    return { ok: false, message: 'Google からの応答を確かめられませんでした。もう一度やり直してください。' };
  }
  if (params.has('error')) {
    sessionStorage.removeItem(DRIVE_PENDING_KEY);
    const denied = params.get('error') === 'access_denied';
    return { ok: false, message: denied ? 'Google Drive への接続を取りやめました。'
                                        : `Google のログインに失敗しました（${params.get('error')}）。` };
  }
  const granted = (params.get('scope') ?? '').split(' ');
  if (!granted.includes(DRIVE_SCOPE)) {
    sessionStorage.removeItem(DRIVE_PENDING_KEY);
    return { ok: false, message: 'Drive の保存場所を使う許可がもらえませんでした。' };
  }
  const seconds = Number(params.get('expires_in') ?? 3600);
  sessionStorage.setItem(DRIVE_TOKEN_KEY, JSON.stringify({
    token: params.get('access_token'),
    expiresAt: now + seconds * 1000,
  }));
  return { ok: true };
}

/// 有効なトークン。無いか、切れかけなら null。
export function driveToken(now = Date.now()) {
  try {
    const saved = JSON.parse(sessionStorage.getItem(DRIVE_TOKEN_KEY));
    // 通信の途中で切れないよう、残り 1 分を切ったら無いものとして扱う
    if (saved?.token && saved.expiresAt - 60_000 > now) return saved.token;
  } catch { /* 壊れていれば無いものとして扱う */ }
  return null;
}

/// ログインから戻ったあと、同期を続きからやるべきか。訊くと同時に印を消す。
export function driveTakePending() {
  const pending = sessionStorage.getItem(DRIVE_PENDING_KEY) === 'sync';
  sessionStorage.removeItem(DRIVE_PENDING_KEY);
  return pending;
}

export function driveSignOut() {
  const token = driveToken();
  sessionStorage.removeItem(DRIVE_TOKEN_KEY);
  sessionStorage.removeItem(DRIVE_PENDING_KEY);
  // Google 側の許可も取り消す。失敗しても手元のトークンは消えているので先へ進む。
  if (token) {
    driveIO.fetch('https://oauth2.googleapis.com/revoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ token }),
    }).catch(() => {});
  }
}

async function driveRequest(url, init = {}) {
  const token = driveToken();
  if (!token) throw new DriveAuthError('Google のログインが切れています。');
  let response;
  try {
    response = await driveIO.fetch(url, {
      ...init,
      headers: { ...(init.headers ?? {}), Authorization: `Bearer ${token}` },
    });
  } catch {
    throw new Error('Google Drive につながりません。通信の状態を確かめてください。');
  }
  if (response.status === 401) {
    sessionStorage.removeItem(DRIVE_TOKEN_KEY);
    throw new DriveAuthError('Google のログインが切れています。');
  }
  if (!response.ok) {
    throw new Error(`Google Drive がエラーを返しました（${response.status}）。`);
  }
  return response;
}

/// アプリ専用フォルダの保管庫。まだ無ければ null。
export async function driveFindVault() {
  const params = new URLSearchParams({
    spaces: 'appDataFolder',
    q: `name = '${DRIVE_FILE_NAME}' and trashed = false`,
    fields: 'files(id, modifiedTime)',
    orderBy: 'modifiedTime desc',
  });
  const { files } = await (await driveRequest(`${DRIVE_API}/files?${params}`)).json();
  return files?.[0] ?? null;
}

export async function driveDownload(id) {
  const response = await driveRequest(`${DRIVE_API}/files/${encodeURIComponent(id)}?alt=media`);
  return new Uint8Array(await response.arrayBuffer());
}

/// 書き込む。id があれば上書き、無ければアプリ専用フォルダに新しく作る。
export async function driveUpload(bytes, id = null) {
  if (id) {
    const response = await driveRequest(
      `${DRIVE_UPLOAD}/files/${encodeURIComponent(id)}?uploadType=media&fields=id,modifiedTime`,
      { method: 'PATCH', headers: { 'Content-Type': 'application/octet-stream' }, body: bytes });
    return response.json();
  }
  // 新規作成は「置き場所の指定」と「中身」を 1 回で送る必要がある（multipart）
  const boundary = `passvault-${crypto.randomUUID()}`;
  const metadata = JSON.stringify({ name: DRIVE_FILE_NAME, parents: ['appDataFolder'] });
  const body = new Blob([
    `--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n`,
    `--${boundary}\r\nContent-Type: application/octet-stream\r\n\r\n`,
    bytes,
    `\r\n--${boundary}--`,
  ]);
  const response = await driveRequest(
    `${DRIVE_UPLOAD}/files?uploadType=multipart&fields=id,modifiedTime`,
    { method: 'POST', headers: { 'Content-Type': `multipart/related; boundary=${boundary}` }, body });
  return response.json();
}
