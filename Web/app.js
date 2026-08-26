// 画面の組み立てと操作。core.js / crypto-extras.js / audit.js に依存する。

import * as V from './core.js';
import * as X from './crypto-extras.js';
import * as A from './audit.js';
import { icon, CATEGORY_LOOK } from './icons.js';

// ============================================================
// 状態
//
// 鍵と復号済みの項目はこのオブジェクトのメモリ上にしか無く、施錠すると捨てる。
// JavaScript では確保した領域をゼロ埋めできないので、そこはネイティブ版に劣る。
// ============================================================

export const state = {
  key: null,
  header: null,
  items: [],
  deletions: [],
  findings: [],
  fileHandle: null,   // File System Access API が使える場合の保存先
  fileName: null,
  fileMtime: null,    // 読み込んだ時点の更新時刻。外からの書き換えを見分けるのに使う
  localSavedAt: null, // 端末の中に保存した時刻（ファイルに書けない環境）
  dirty: false,       // どこにも書けていない変更があることを示す
  selection: { kind: 'all' },
  selectedId: null,
  search: '',
  revealed: new Set(),
  lastActivity: Date.now(),
  holds: 0,           // 0 より大きい間は自動施錠しない
  view: 'list',       // いま出している画面: list | detail
  cursor: -1,         // 一覧でキーボードが指している位置（-1 はまだ触っていない）
  stash: null,        // 施錠時に保存できていなかった変更（暗号化したまま）
};

export const CLIPBOARD_CLEAR_SECONDS = 30;
export const canUseFilePicker = typeof window.showSaveFilePicker === 'function';

export const settings = {
  get autoLockMinutes() {
    return Number(localStorage.getItem('passvault.autoLockMinutes') ?? 5);
  },
  set autoLockMinutes(value) {
    localStorage.setItem('passvault.autoLockMinutes', String(value));
  },
};

// ============================================================
// 小さな道具
// ============================================================

export const $ = selector => document.querySelector(selector);
export const el = (tag, props = {}, children = []) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    // aria-* や data-* のようにハイフンを含む名前は、プロパティとしては設定できない。
    // Object.assign だと黙って無視され、読み上げには何も伝わらないまま気づけない。
    if (key.includes('-')) node.setAttribute(key, value);
    else node[key] = value;
  }
  for (const child of [].concat(children)) {
    if (child != null) node.append(child);
  }
  return node;
};

let toastTimer = null;
export function toast(message) {
  const node = $('#toast');
  node.textContent = message;
  node.classList.add('on');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => node.classList.remove('on'), 2600);
  noteActivity();
}

export function noteActivity() { state.lastActivity = Date.now(); }

export async function copyPlain(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    toast(`${label}をコピーしました`);
  } catch {
    toast('コピーできませんでした（ブラウザが拒否しました）');
  }
}

/// 秘密はしばらくしたら消す。
/// ブラウザにはクリップボード履歴へ「保存するな」と伝える手段がないので、
/// ネイティブ版よりここは弱い。
export async function copySecret(text, label) {
  try {
    await navigator.clipboard.writeText(text);
    toast(`${label}をコピーしました（${CLIPBOARD_CLEAR_SECONDS}秒で消去）`);
    setTimeout(async () => {
      try {
        if ((await navigator.clipboard.readText()) === text) {
          await navigator.clipboard.writeText('');
        }
      } catch { /* 読み取りが拒否される場合は消せない */ }
    }, CLIPBOARD_CLEAR_SECONDS * 1000);
  } catch {
    toast('コピーできませんでした（ブラウザが拒否しました）');
  }
}

export const fmtDate = iso => new Date(iso).toLocaleDateString('ja-JP', { year: 'numeric', month: 'short', day: 'numeric' });
export const fmtDateTime = iso => new Date(iso).toLocaleString('ja-JP', { dateStyle: 'medium', timeStyle: 'short' });

// ============================================================
// 保管庫の読み書き
// ============================================================

function payload() {
  return { schemaVersion: V.SCHEMA_VERSION, items: state.items, deletions: state.deletions };
}

/// 保管庫を書き込む。**失敗を投げずに返す。**
///
/// 例外を投げっぱなしにすると、呼び出し側で握られずに
/// 「画面には反映されているがファイルには書かれていない」状態が
/// 何も表示されないまま残る。パスワード管理として最悪の失敗の仕方なので、
/// 必ず結果を返して呼び出し側に判断させる。
///
/// 戻り値: { ok, reason?, message?, unsaved? }
export async function persist({ force = false } = {}) {
  state.findings = A.audit(state.items);
  if (!state.key || !state.header) return { ok: true };

  let bytes;
  try {
    bytes = await V.seal(payload(), state.key, state.header);
  } catch (caught) {
    state.dirty = true;
    return { ok: false, reason: 'seal', message: `暗号化に失敗しました: ${describe(caught)}` };
  }

  if (!state.fileHandle) {
    // ファイルに書けない環境（iOS の Safari など）。この端末の中に置く。
    //
    // 以前はここで「抱えておく」とだけ返していたが、実際にはメモリ上にしか無く、
    // タブを閉じた時点で消えていた。保存したつもりのものが消えるのは
    // パスワード管理として最悪なので、必ずどこかに書く。
    try {
      await saveLocalVault(bytes, state.fileName ?? 'vault.pvlt');
      state.localSavedAt = V.isoNoMillis();
      state.dirty = false;
      noteActivity();
      return { ok: true, local: true };
    } catch (caught) {
      // 端末にも書けない。ここで ok を返すと消える変更を放置することになる。
      state.dirty = true;
      return { ok: false, reason: 'local',
               message: `この端末に保存できませんでした: ${describe(caught)}` };
    }
  }

  if (!force) {
    const conflict = await detectExternalChange();
    if (conflict) {
      state.dirty = true;
      return { ok: false, reason: 'conflict', message: conflict };
    }
  }

  try {
    const writable = await state.fileHandle.createWritable();
    await writable.write(bytes);
    await writable.close();
    state.fileMtime = (await state.fileHandle.getFile()).lastModified;
    state.dirty = false;
    noteActivity();
    return { ok: true };
  } catch (caught) {
    state.dirty = true;
    return { ok: false, reason: 'write', message: `ファイルに書けませんでした: ${describe(caught)}` };
  }
}

const describe = error => error?.message ?? String(error);

/// ファイルが自分以外に書き換えられていないかを見る。
///
/// クラウド同期のフォルダに置いている場合、別の端末の変更が降りてくることがある。
/// それに気づかず上書きすると、相手の変更が黙って消える。
async function detectExternalChange() {
  if (state.fileMtime == null) return null;
  try {
    const current = (await state.fileHandle.getFile()).lastModified;
    if (current > state.fileMtime) {
      const when = new Date(current).toLocaleString('ja-JP');
      return `保管庫ファイルが他の場所で変更されています（${when}）。`
           + 'クラウドの同期や、別の端末での編集が考えられます。';
    }
  } catch {
    // 消された・移動されたなど。書き込みのときに改めて失敗するのでここでは通す。
  }
  return null;
}

/// 別の端末の変更を、こちらから取りに行く。
///
/// 保存しようとするまで気づかない作りだと、相手の変更を知らないまま
/// 古い内容を眺めて編集し続けることになる。クラウド同期のフォルダに
/// 置いている場合、相手の変更はこちらに断りなく降りてくる。
///
/// 読み込むかどうかは必ず画面側が訊く。黙って差し替えると編集中の内容が消える。
let pollingRemote = false;
export async function pollRemoteChange() {
  if (!state.key || !state.fileHandle || state.fileMtime == null) return false;
  if (state.holds > 0 || pollingRemote || !hooks.onRemoteChange) return false;
  pollingRemote = true;
  try {
    const file = await state.fileHandle.getFile();
    if (file.lastModified <= state.fileMtime) return false;
    return await hooks.onRemoteChange(new Date(file.lastModified));
  } catch {
    // 消された・移動されたなど。保存のときに改めて失敗するのでここでは黙る。
    return false;
  } finally {
    pollingRemote = false;
  }
}

/// 画面から呼ぶ保存。失敗は必ず利用者に見える形にする。
export async function save() {
  const result = await persist();
  if (result.ok) return true;

  if (result.reason === 'conflict') {
    // 画面側が用意していれば、上書き／取り込み／何もしない の 3 択を出す。
    if (hooks.onConflict) return hooks.onConflict(result.message);

    // 画面側が用意されていない状況（本来は起きない）。
    // 訊ねる手段が無いまま上書きすると相手の変更を黙って消すので、何もしない。
    toast(`${result.message} 保存を中止しました。`);
    render();
    return false;
  }

  toast(result.message);
  render();
  return false;
}

/// 競合を承知の上で上書きする
export async function forceSave() {
  const forced = await persist({ force: true });
  if (forced.ok) { toast('上書きして保存しました'); return true; }
  toast(forced.message);
  render();
  return false;
}

/// いま保存先に入っているファイルの中身を読む（競合の解決に使う）。
///
/// rebase を付けたときだけ「これが今の下敷き」として更新時刻を覚え直す。
/// 読んだだけで覚え直してはいけない。取り込みを途中で取り消したとき、
/// 相手の変更を見なかったことにして、次の保存で黙って踏み潰すことになる。
export async function readVaultFileBytes({ rebase = false } = {}) {
  if (!state.fileHandle) return null;
  const file = await state.fileHandle.getFile();
  if (rebase) state.fileMtime = file.lastModified;
  return new Uint8Array(await file.arrayBuffer());
}

/// 相手の中身を取り込む。呼ぶ前に必ず利用者へ内容を見せて確認を取ること。
export async function applyMerge(remotePayload) {
  const merged = A.merge(
    { schemaVersion: V.SCHEMA_VERSION, items: state.items, deletions: state.deletions },
    remotePayload
  );
  state.items = merged.payload.items;
  state.deletions = merged.payload.deletions;
  // 取り込んだ結果を書き戻す。相手の変更は既に手元にあるので上書きしてよい。
  const written = await persist({ force: true });
  if (!written.ok) { toast(written.message); render(); return null; }
  return merged.summary;
}

/// 保管庫を暗号化したままファイルとして書き出す。
///
/// ブラウザにはダウンロードが完了したかを知る手段がない。
/// なので「書き出した」と言い切らず、確かめるよう促す。
/// 失敗しうるところは握りつぶさずに必ず画面へ出す。
export async function downloadVault({ forSync = false } = {}) {
  const base = (state.fileName ?? 'vault.pvlt').replace(/\.pvlt$/, '');
  // 控えには日付を入れる。本体と同じ名前にすると、どちらが使っている保管庫で
  // どちらが控えなのか区別できなくなる。
  //
  // 同期用は逆に、保管庫と同じ名前でなければならない。クラウド上の
  // 同じファイルに上書きして戻すのが目的なので、名前が変わると別物になる。
  const name = forSync
    ? `${base}.pvlt`
    : `${base}-backup-${V.isoNoMillis().slice(0, 10)}.pvlt`;

  let url = null;
  try {
    const bytes = await V.seal(payload(), state.key, state.header);
    url = URL.createObjectURL(new Blob([bytes], { type: 'application/octet-stream' }));

    // Safari では body に入っていないと click が効かないことがある
    const link = el('a', { href: url, download: name });
    document.body.append(link);
    link.click();
    link.remove();
  } catch (caught) {
    if (url) URL.revokeObjectURL(url);
    toast(`書き出せませんでした: ${describe(caught)}`);
    render();
    return false;
  }
  // 早く解放しすぎるとダウンロードが途中で壊れる
  setTimeout(() => URL.revokeObjectURL(url), 30_000);

  toast(forSync
    ? `${name} を書き出しました。クラウド上の保管庫に上書きしてください`
    : `${name} を書き出しました。ファイルができているか確かめてください`);
  render();
  return true;
}

// ---- この端末に置いておくもの ----
//
// 2 つの用途で IndexedDB を使う。どちらにも鍵とマスターパスワードは入らない。
//
//   handles: File System Access API のハンドル。「このファイルを触る権利」だけ。
//            次に開くときブラウザが許可を訊き直すので、勝手に読まれることもない。
//   vault:   暗号化した保管庫そのもの。ファイルに書けない環境（iOS の Safari）で使う。
//            取り出せてもマスターパスワードが無ければ中身は読めない。

const DB_NAME = 'passvault';
const DB_VERSION = 2;
const HANDLE_STORE = 'handles';
const VAULT_STORE = 'vault';

function openDB() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      // 版 1 から上がってくる場合があるので、無いものだけ作る
      const db = request.result;
      if (!db.objectStoreNames.contains(HANDLE_STORE)) db.createObjectStore(HANDLE_STORE);
      if (!db.objectStoreNames.contains(VAULT_STORE)) db.createObjectStore(VAULT_STORE);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

/// 失敗を投げる版。保管庫本体の読み書きに使う。
async function withStore(storeName, mode, action) {
  const db = await openDB();
  try {
    return await new Promise((resolve, reject) => {
      const transaction = db.transaction(storeName, mode);
      const request = action(transaction.objectStore(storeName));
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      // 書き込みが確定するのは transaction が終わったとき。
      // request.onsuccess だけを見ていると、容量超過のように
      // あとから起きる中断を取りこぼし、書けたつもりになる。
      transaction.onabort = () => reject(transaction.error ?? new Error('保存が中断されました'));
    });
  } finally {
    db.close();
  }
}

/// 失敗を握りつぶす版。ハンドルは無くても動作に支障がないので静かに諦める。
async function tryStore(storeName, mode, action) {
  try {
    return await withStore(storeName, mode, action);
  } catch {
    return undefined;
  }
}

export async function rememberVaultHandle(handle) {
  if (!handle) return;
  await tryStore(HANDLE_STORE, 'readwrite', store => store.put(handle, 'last'));
}

export async function recallVaultHandle() {
  return tryStore(HANDLE_STORE, 'readonly', store => store.get('last'));
}

export async function forgetVaultHandle() {
  await tryStore(HANDLE_STORE, 'readwrite', store => store.delete('last'));
}

/// 端末の中に保管庫を置く。**失敗は投げる**（呼び出し側が握って画面に出す）。
export async function saveLocalVault(bytes, name) {
  await withStore(VAULT_STORE, 'readwrite', store =>
    store.put({ bytes, name, savedAt: V.isoNoMillis() }, 'current'));
}

export async function loadLocalVault() {
  return tryStore(VAULT_STORE, 'readonly', store => store.get('current'));
}

export async function forgetLocalVault() {
  await withStore(VAULT_STORE, 'readwrite', store => store.delete('current'));
}

/// 保存領域を「消さないでほしい」とブラウザに申し出る。
///
/// iOS はしばらく使わないサイトの保存領域を消すことがある。
/// ホーム画面に追加してあると通りやすい。断られても動作は続くので、
/// 通ったかどうかを返して画面側に判断させる。
export async function requestDurableStorage() {
  try {
    if (!navigator.storage?.persist) return null;
    if (await navigator.storage.persisted()) return true;
    return await navigator.storage.persist();
  } catch {
    return null;
  }
}

export function lock() {
  state.key = null;
  state.header = null;
  state.items = [];
  state.deletions = [];
  state.findings = [];
  state.revealed.clear();
  state.selectedId = null;
  state.selection = { kind: 'all' };
  render();
}

/// 保存できていない変更を、暗号化したまま抱えておく。
///
/// 施錠は必ず行う（開けっ放しのほうが危ない）。ただし黙って捨てない。
/// 平文と鍵は捨てるので施錠の意味は保たれ、次に同じパスワードで
/// 解錠できたときだけ中身を取り戻せる。
async function stashUnsaved() {
  if (!state.dirty || !state.key || !state.header) return false;
  try {
    state.stash = {
      bytes: await V.seal(payload(), state.key, state.header),
      header: state.header,
      at: V.isoNoMillis(),
    };
    return true;
  } catch {
    return false;
  }
}

/// 自動施錠。保存できていない変更があれば、まず保存を試み、
/// それでも駄目なら暗号化して抱えてから施錠する。
async function lockForIdle() {
  let stashed = false;
  if (state.dirty) {
    const written = await persist();
    if (!written.ok || state.dirty) stashed = await stashUnsaved();
  }
  lock();
  toast(stashed
    ? '自動的に施錠しました。保存できていない変更は預かってあります'
    : '自動的に施錠しました');
}

/// 解錠したあと、預かっていた変更があれば取り戻せるか調べる。
/// 同じパスワードでなければ開けないので、取り違えは起きない。
async function recoverStash(key) {
  if (!state.stash) return null;
  const { bytes, header, at } = state.stash;
  try {
    const recovered = await V.open(bytes, key, header);
    return { payload: recovered, at };
  } catch {
    // 別の保管庫、あるいはパスワードを変えた後。取り戻せないので捨てる。
    state.stash = null;
    return null;
  }
}

// ============================================================
// 入口の画面
// ============================================================

function renderGate(mode) {
  const gate = $('#gate');
  gate.style.display = 'grid';
  $('#app').classList.remove('on');
  const card = mode === 'create' ? createCard() : unlockCard();
  gate.replaceChildren(card);
  // 前回の保管庫があれば、あとから差し込む（IndexedDB の読みは非同期なので）
  if (!state.pendingBytes) offerRememberedVault(card);
}

async function offerRememberedVault(card) {
  const handle = await recallVaultHandle();
  if (!handle) { await offerLocalVault(card); return; }
  if (state.pendingBytes) return;

  const button = el('button', { className: 'push', textContent: `前回の保管庫を開く（${handle.name}）` });
  button.onclick = async () => {
    button.disabled = true;
    try {
      // 一度閉じたあとは許可が切れているので、その場で訊き直す。
      // 利用者のクリックが起点でないとブラウザが訊いてくれない。
      let permission = await handle.queryPermission({ mode: 'readwrite' });
      if (permission !== 'granted') {
        permission = await handle.requestPermission({ mode: 'readwrite' });
      }
      if (permission !== 'granted') {
        toast('ファイルへのアクセスが許可されませんでした');
        button.disabled = false;
        return;
      }
      const file = await handle.getFile();
      state.fileHandle = handle;
      state.fileName = file.name;
      state.fileMtime = file.lastModified;
      state.pendingBytes = new Uint8Array(await file.arrayBuffer());
      renderGate('unlock');
    } catch (caught) {
      toast(`開けませんでした: ${caught.message ?? caught}`);
      await forgetVaultHandle();
      button.remove();
    }
  };

  offerButton(card, button);
}

/// ファイルに書けない環境（iOS の Safari など）で、この端末に置いた保管庫を出す。
async function offerLocalVault(card) {
  if (state.pendingBytes) return;
  const local = await loadLocalVault();
  if (!local?.bytes) return;

  const when = local.savedAt ? fmtDateTime(local.savedAt) : '時刻不明';
  const button = el('button', { className: 'push',
                                textContent: `この端末の保管庫を開く（${when}）` });
  button.onclick = () => {
    state.fileHandle = null;
    state.fileName = local.name ?? 'vault.pvlt';
    state.fileMtime = null;
    state.localSavedAt = local.savedAt ?? null;
    state.pendingBytes = new Uint8Array(local.bytes);
    renderGate('unlock');
  };
  offerButton(card, button);
}

/// 「新しい保管庫をつくる」より上に差し込む
function offerButton(card, button) {
  card.insertBefore(button, card.querySelector('.tip') ?? null);
  card.insertBefore(el('div', { style: 'height:8px' }), button.nextSibling);
}

function unlockCard() {
  const password = el('input', { className: 'field', type: 'password', placeholder: 'マスターパスワード' });
  const error = el('div', { className: 'error' });
  const button = el('button', { className: 'push primary', textContent: 'ロック解除' });

  const card = el('div', { className: 'gate-card' }, [
    el('div', { className: 'gate-mark' }, [icon('lock', 40)]),
    el('h1', { textContent: 'ロック中' }),
    el('p', { className: 'lead', textContent: state.fileName ?? '保管庫ファイルを選んでください。' }),
    password, error, button,
    el('div', { style: 'height:8px' }),
    el('button', { className: 'push', textContent: '別の保管庫ファイルを開く', onclick: pickVaultFile }),
    el('div', { style: 'height:8px' }),
    el('button', { className: 'push', textContent: '新しい保管庫をつくる', onclick: () => renderGate('create') }),
  ]);

  async function submit() {
    if (!state.pendingBytes) { error.textContent = '保管庫ファイルを選んでください。'; return; }
    if (!password.value) return;
    button.disabled = true;
    button.textContent = '確認中…';
    error.textContent = '';
    try {
      // 施錠中にファイルが外で変わっているかもしれない（クラウド同期など）。
      // 最初に読んだ内容のまま開くと、古い中身を編集することになる。
      if (state.fileHandle) {
        try { state.pendingBytes = await readVaultFileBytes({ rebase: true }) ?? state.pendingBytes; }
        catch { /* 読めなければ手元の内容で試す */ }
      }
      const header = V.decodeHeader(state.pendingBytes);
      const key = await V.deriveKey(password.value, header);
      const opened = await V.open(state.pendingBytes, key, header);
      password.value = '';
      state.key = key;
      state.header = header;
      state.items = opened.items;
      state.deletions = opened.deletions;
      state.findings = A.audit(state.items);

      // 施錠時に保存できていなかった変更があれば、戻すかどうか訊く
      const held = await recoverStash(key);
      if (held) {
        const restore = await hooks.askConfirm?.(
          '保存されていない変更があります',
          `${new Date(held.at).toLocaleString('ja-JP')} に施錠したとき、`
          + 'ファイルに書けていない変更が残っていました。取り戻しますか。',
          { confirmLabel: '取り戻す' });
        state.stash = null;
        if (restore) {
          state.items = held.payload.items;
          state.deletions = held.payload.deletions;
          state.findings = A.audit(state.items);
          state.dirty = true;
          const written = await persist();
          toast(written.ok && !state.dirty
            ? '保存されていない変更を取り戻して保存しました'
            : '取り戻しました。まだファイルに書けていません');
        }
      }
      // 古い形式で保存されていたら、現行形式に書き戻す
      // 古い形式で保存されていたら現行形式に書き戻す。
      // 失敗しても開くのは妨げないが、黙って済ませずに知らせる。
      if (opened.schemaVersion < V.SCHEMA_VERSION) {
        const written = await persist();
        if (!written.ok) toast(`形式の書き戻しに失敗しました: ${written.message}`);
      }
      noteActivity();
      render();
    } catch (caught) {
      error.textContent = caught.message ?? String(caught);
      button.disabled = false;
      button.textContent = 'ロック解除';
      password.value = '';
    }
  }
  button.onclick = submit;
  password.onkeydown = event => { if (event.key === 'Enter') submit(); };
  setTimeout(() => password.focus(), 0);
  return card;
}

function createCard() {
  const first = el('input', { className: 'field', type: 'password', placeholder: 'マスターパスワード' });
  const second = el('input', { className: 'field', type: 'password', placeholder: 'もう一度入力' });
  const hintLength = el('div', { className: 'hint' });
  const hintMatch = el('div', { className: 'hint' });
  const error = el('div', { className: 'error' });
  const button = el('button', { className: 'push primary', textContent: '保管庫を作成', disabled: true });

  function validate() {
    const longEnough = first.value.length >= 12;
    const same = first.value.length > 0 && first.value === second.value;
    const mark = (node, ok, label) => {
      node.className = `hint ${ok ? 'ok' : ''}`;
      // 未達は「×」ではなく空の丸にする。まだ入力していないだけの状態を
      // 間違いとして見せない。
      node.replaceChildren(icon(ok ? 'check' : 'circle', 13), label);
    };
    mark(hintLength, longEnough, '12文字以上');
    mark(hintMatch, same, '2回の入力が一致');
    button.disabled = !(longEnough && same);
  }
  first.oninput = second.oninput = validate;
  validate();

  button.onclick = async () => {
    button.disabled = true;
    button.textContent = '鍵を生成中…';
    error.textContent = '';
    try {
      state.header = V.makeHeader();
      state.key = await V.deriveKey(first.value, state.header);
      state.items = [];
      state.deletions = [];
      state.findings = [];
      first.value = second.value = '';

      if (canUseFilePicker) {
        const handle = await window.showSaveFilePicker({
          suggestedName: 'vault.pvlt',
          types: [{ description: 'PassVault の保管庫', accept: { 'application/octet-stream': ['.pvlt'] } }],
        });
        state.fileHandle = handle;
        state.fileName = handle.name;
        state.fileMtime = (await handle.getFile()).lastModified;
        await rememberVaultHandle(handle);
      } else {
        state.fileName = 'vault.pvlt';
      }
      // 最初の書き込みが失敗したら、作れたつもりにさせてはいけない。
      // 中身は空でも、ここで気づかないと以後の変更が全部宙に浮く。
      const written = await persist();
      if (!written.ok) {
        error.textContent = `保管庫を作成できませんでした。${written.message}`;
        state.key = null;
        state.header = null;
        state.fileHandle = null;
        await forgetVaultHandle();
        button.disabled = false;
        button.textContent = '保管庫を作成';
        validate();
        return;
      }
      noteActivity();
      render();
      if (!state.fileHandle) {
        // 端末の中に置いた。iOS はしばらく使わないと消すことがあるので、
        // 消さないよう申し出たうえで、控えを勧める。
        const durable = await requestDurableStorage();
        toast(durable
          ? 'この端末の中に保存しました。控えの書き出しもときどき行ってください'
          : 'この端末の中に保存しました。ブラウザの都合で消えることがあるので、控えを書き出してください');
      }
    } catch (caught) {
      error.textContent = caught.message ?? String(caught);
      state.key = null;
      button.disabled = false;
      button.textContent = '保管庫を作成';
      validate();
    }
  };

  return el('div', { className: 'gate-card' }, [
    el('div', { className: 'gate-mark' }, [icon('shieldCheck', 40)]),
    el('h1', { textContent: '保管庫をつくる' }),
    el('p', { className: 'lead', textContent: 'マスターパスワードだけがこの保管庫を開ける鍵です。どこにも保存されないので、忘れると中身は取り出せません。' }),
    first, second,
    el('div', { className: 'hints' }, [hintLength, hintMatch]),
    error, button,
    el('div', { style: 'height:8px' }),
    el('button', { className: 'push', textContent: '既にある保管庫を開く', onclick: pickVaultFile }),
    el('p', { className: 'tip', textContent: 'ヒント: 覚えやすい単語を4〜5個つないだ長い文（例: 紫の 亀 が 図書館 で 走る）は、記号混じりの短いパスワードより安全で覚えやすいです。' }),
    el('p', { className: 'tip', textContent: '保管庫のファイル（.pvlt）は暗号化されたデータなので、ダブルクリックしても開きません。いつもこの画面から選んで開いてください。' }),
  ]);
}

async function pickVaultFile() {
  try {
    let file;
    if (typeof window.showOpenFilePicker === 'function') {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description: 'PassVault の保管庫', accept: { 'application/octet-stream': ['.pvlt'] } }],
      });
      state.fileHandle = handle;
      await rememberVaultHandle(handle);
      file = await handle.getFile();
    } else {
      file = await pickViaInput();
      state.fileHandle = null;
    }
    state.pendingBytes = new Uint8Array(await file.arrayBuffer());
    state.fileName = file.name;
    state.fileMtime = file.lastModified;
    renderGate('unlock');
  } catch { /* 選択の取り消し */ }
}

function pickViaInput() {
  return new Promise((resolve, reject) => {
    const input = el('input', { type: 'file', accept: '.pvlt,application/octet-stream' });
    input.onchange = () => input.files[0] ? resolve(input.files[0]) : reject();
    input.click();
  });
}

// ============================================================
// 一覧の絞り込み
// ============================================================

export const activeItems = () => state.items.filter(item => !item.trashedAt);
export const trashedItems = () => state.items.filter(item => item.trashedAt);

function allTags() {
  return [...new Set(activeItems().flatMap(item => item.tags))]
    .filter(Boolean).sort((a, b) => a.localeCompare(b, 'ja'));
}

function itemsFor(selection) {
  switch (selection.kind) {
    case 'all': return activeItems();
    case 'favorites': return activeItems().filter(item => item.isFavorite);
    case 'category': return activeItems().filter(item => item.category === selection.value);
    case 'tag': return activeItems().filter(item => item.tags.includes(selection.value));
    case 'watchtower': {
      const flagged = new Set(state.findings.map(finding => finding.itemId));
      return activeItems().filter(item => flagged.has(item.id));
    }
    case 'trash': return trashedItems();
    default: return activeItems();
  }
}

function visibleItems() {
  return itemsFor(state.selection)
    .filter(item => V.matches(item, state.search))
    .sort((a, b) => V.displayTitle(a).localeCompare(V.displayTitle(b), 'ja'));
}

const selectionTitle = selection => ({
  all: 'すべて', favorites: 'お気に入り', watchtower: '点検', trash: 'ゴミ箱',
  category: V.CATEGORIES[selection.value]?.name, tag: selection.value,
}[selection.kind] ?? 'すべて');

const sameSelection = (a, b) => a.kind === b.kind && a.value === b.value;

// ============================================================
// 描画
// ============================================================

let lastShownItemId = null;

export function render() {
  // 別の項目に移ったら、表示にしていた欄を伏せ字に戻す。
  // 解除したままだと、画面を人に見せたときに前の項目の中身まで出てしまう。
  if (state.selectedId !== lastShownItemId) {
    state.revealed.clear();
    lastShownItemId = state.selectedId;
  }

  if (!state.key) {
    renderGate(state.pendingBytes ? 'unlock' : 'create');
    return;
  }
  $('#gate').style.display = 'none';
  $('#app').classList.add('on');

  // 詳細を出している最中に項目が消えた（削除・取り込みなど）ら一覧へ戻す。
  // 戻さないと、何も無い画面に取り残される。
  if (state.view === 'detail' && !state.items.some(item => item.id === state.selectedId)) {
    state.view = 'list';
  }

  renderBar();
  if (state.view === 'detail') renderDetail();
  else renderListView();
}

/// 上の帯。検索がこのアプリの主役なので、いちばん広い場所を与える。
function renderBar() {
  const bar = $('#bar');

  const tools = (...extra) => el('div', { className: 'bar-tools' }, [
    ...extra,
    el('button', { className: 'iconbtn', title: 'パスワード生成',
                   'aria-label': 'パスワード生成', onclick: openGenerator }, [icon('wand')]),
    el('button', { className: 'iconbtn', title: '設定',
                   'aria-label': '設定', onclick: openSettings }, [icon('gear')]),
    el('button', { className: 'iconbtn', title: 'ロック',
                   'aria-label': 'ロック', onclick: lock }, [icon('lock')]),
  ]);

  if (state.view === 'detail') {
    const item = state.items.find(candidate => candidate.id === state.selectedId);
    bar.replaceChildren(
      el('button', { className: 'backbtn', title: '一覧へ戻る（Esc）',
                     'aria-label': '一覧へ戻る', onclick: showList },
         [icon('back', 18), el('span', { textContent: selectionTitle(state.selection) })]),
      // 帯にも名前を出す。下へ辿ったときに何を見ているか分からなくならないように。
      el('div', { className: 'bar-title', textContent: item ? V.displayTitle(item) : '' }),
      tools(),
    );
    return;
  }

  const search = el('input', {
    id: 'search', type: 'search', placeholder: '検索', value: state.search,
    autocomplete: 'off', spellcheck: false,
    oninput: event => {
      state.search = event.target.value;
      state.cursor = -1;
      noteActivity();
      renderListView();
    },
  });

  bar.replaceChildren(
    el('div', { className: 'brand', title: state.dirty ? '保存できていない変更があります' : '' }, [
      icon('shieldCheck', 17),
      el('span', { textContent: 'PassVault' }),
      state.dirty ? el('span', { className: 'unsaved', textContent: '未保存' }) : null,
    ]),
    el('div', { className: 'searchwrap' }, [search]),
    tools(el('button', { className: 'iconbtn', title: '新しい項目',
                         'aria-label': '新しい項目', onclick: openNewItemMenu }, [icon('plus')])),
  );
}

/// 絞り込みの札。縦のサイドバーをやめて横一列にした。
/// 中身のある区分しか出さない。空の器が並んでも選ぶ理由がない。
function renderChips() {
  const chips = [];
  const add = (selection, label, extra) => {
    const selected = sameSelection(selection, state.selection);
    chips.push(el('button', {
      className: `chip${selected ? ' sel' : ''}`,
      onclick: () => {
        state.selection = selection;
        state.cursor = -1;
        noteActivity();
        renderListView();
      },
    }, [label, extra ?? null]));
  };

  // 出すのは「検索では言い表せない見方」だけにする。
  // 種別もタグも検索語で絞れるので、札にすると器が並ぶだけになる。
  // （実際、種別とタグを全部出したら 16 個並んで、縦のサイドバーの
  //   散らかりを横に移しただけになった）
  const n = (value, cls) => el('span', { className: cls ? `n ${cls}` : 'n', textContent: String(value) });

  add({ kind: 'all' }, 'すべて', n(activeItems().length));
  const favorites = itemsFor({ kind: 'favorites' }).length;
  if (favorites) add({ kind: 'favorites' }, 'お気に入り', n(favorites));
  if (state.findings.length) add({ kind: 'watchtower' }, '点検', n(state.findings.length, 'warn'));
  if (trashedItems().length) add({ kind: 'trash' }, 'ゴミ箱', n(trashedItems().length));

  // 種別やタグから入ってきた場合は、いま何で絞っているかを見せて戻せるようにする
  if (state.selection.kind === 'category' || state.selection.kind === 'tag') {
    add(state.selection, selectionTitle(state.selection), n(itemsFor(state.selection).length));
  }

  return el('div', { className: 'chips' }, chips);
}

function renderListView() {
  const items = visibleItems();
  const isTrash = state.selection.kind === 'trash';

  // 選んでいた区分が空になったら「すべて」へ落とす（最後の 1 件を消したときなど）
  if (!sameSelection(state.selection, { kind: 'all' }) && !items.length && !state.search) {
    const stillThere = itemsFor(state.selection).length;
    if (!stillThere) state.selection = { kind: 'all' };
  }

  // -1（まだキーボードを触っていない）はそのまま残す。
  // ここで 0 に丸めると、開いた直後から 1 行目が光って選択済みに見える。
  if (state.cursor >= 0) state.cursor = Math.min(state.cursor, items.length - 1);

  const parts = [renderChips()];

  if (isTrash && trashedItems().length) {
    parts.push(el('div', { className: 'listtools' }, [
      el('button', { className: 'linkbtn', onclick: emptyTrash }, [icon('broom', 14), 'ゴミ箱を空にする']),
    ]));
  }

  if (items.length) {
    parts.push(el('div', { className: 'list' }, items.map((item, index) => itemRow(item, index))));
    parts.push(el('div', { className: 'listfoot', textContent: `${items.length} 件` }));
  } else {
    parts.push(el('div', { className: 'empty' }, [
      el('span', { className: 'big' }, [icon(isTrash ? 'trash' : (state.search ? 'search' : 'inbox'), 38)]),
      el('span', { className: 'lead', textContent:
        isTrash ? 'ゴミ箱は空です'
                : (state.search ? `「${state.search}」に一致するものはありません` : 'まだ何もありません') }),
      state.search || isTrash ? null
        : el('span', { textContent: '右上の ＋ から追加できます。' }),
    ]));
  }

  $('#main').replaceChildren(el('div', { className: 'sheet' }, parts));
}

async function emptyTrash() {
  const ok = await hooks.askConfirm?.('ゴミ箱を空にする',
    'ゴミ箱の中身を完全に削除します。取り消せません。',
    { confirmLabel: '完全に削除', destructive: true });
  if (!ok) return;
  const removed = trashedItems();
  state.items = state.items.filter(item => !item.trashedAt);
  state.deletions.push(...removed.map(item => ({ id: item.id, deletedAt: V.isoNoMillis() })));
  if (!await save()) return;
  toast('ゴミ箱を空にしました');
  render();
}

export function showList() {
  state.view = 'list';
  noteActivity();
  render();
}

/// 種別やタグで絞って一覧へ戻る。詳細から「同じ仲間」へ行くための道。
export function filterBy(selection) {
  state.selection = selection;
  state.search = '';
  state.cursor = -1;
  state.view = 'list';
  noteActivity();
  render();
}

export function openItem(id) {
  state.selectedId = id;
  state.view = 'detail';
  noteActivity();
  render();
}

function itemRow(item, index) {
  const look = CATEGORY_LOOK[item.category];
  const marks = el('span', { className: 'marks' });
  if (item.oneTimePasswordSecret) {
    const mark = icon('clock', 14); mark.setAttribute('aria-label', 'ワンタイムパスワードあり');
    marks.append(mark);
  }
  if (state.findings.some(finding => finding.itemId === item.id)) {
    const mark = icon('warning', 14); mark.classList.add('warn');
    mark.setAttribute('aria-label', '点検の指摘あり');
    marks.append(mark);
  }
  if (item.isFavorite) {
    const mark = icon('starFill', 14); mark.classList.add('fav');
    mark.setAttribute('aria-label', 'お気に入り');
    marks.append(mark);
  }

  const row = el('div', {
    className: `item-row${index === state.cursor ? ' cur' : ''}`,
  }, [
    el('button', {
      className: 'item-open', onclick: () => openItem(item.id),
    }, [
      el('span', { className: 'avatar', style: `--hue:${look.hue}` }, [icon(look.icon, 17)]),
      el('span', { className: 'lines' }, [
        el('span', { className: 't', textContent: V.displayTitle(item) }),
        V.subtitle(item) ? el('span', { className: 's', textContent: V.subtitle(item) }) : null,
      ]),
      marks,
    ]),
  ]);

  // 一覧から直接コピーできるようにする。9 割はこれで用が済むので、
  // わざわざ詳細を開かせる理由がない。
  const password = V.primaryPassword(item);
  if (password && !item.trashedAt) {
    row.append(el('button', {
      className: 'quick', title: 'パスワードをコピー', 'aria-label': `${V.displayTitle(item)} のパスワードをコピー`,
      onclick: event => { event.stopPropagation(); copySecret(password, 'パスワード'); },
    }, [icon('copy', 15)]));
  }
  return row;
}

// 詳細と各ダイアログは detail.js 側に置く（この時点では未読込でも動くよう遅延で解決）
export const hooks = {};
const renderDetail = () => hooks.renderDetail?.();
const openGenerator = () => hooks.openGenerator?.();
const openSettings = () => hooks.openSettings?.();
const openNewItemMenu = () => hooks.openNewItemMenu?.();

// ============================================================
// 自動施錠
// ============================================================

let lockingForIdle = false;
setInterval(async () => {
  if (!state.key || state.holds > 0 || lockingForIdle) return;
  const minutes = settings.autoLockMinutes;
  if (minutes > 0 && Date.now() - state.lastActivity >= minutes * 60_000) {
    lockingForIdle = true;
    try { await lockForIdle(); } finally { lockingForIdle = false; }
  }
}, 5000);

// 別の端末の変更を見に行く。ファイルの更新時刻を見るだけなので軽い。
setInterval(() => { pollRemoteChange(); }, 15_000);

// 画面に戻ってきたときは、待たずに一度見る。
// 別の端末を触ってから戻ってくる、というのが実際いちばん多い。
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) pollRemoteChange();
});

// ============================================================
// キーボード
// ============================================================
//
// 検索から手を離さずに目的の項目へ行けること。
// この造りだと、探す→選ぶ→コピーが一続きの操作になる。

document.addEventListener('keydown', event => {
  if (!state.key || state.holds > 0) return;   // 施錠中とダイアログ表示中は触らない

  const search = $('#search');
  const typing = document.activeElement?.tagName === 'INPUT'
              || document.activeElement?.tagName === 'TEXTAREA';

  if (event.key === 'Escape') {
    if (state.view === 'detail') { showList(); event.preventDefault(); return; }
    if (state.search) {
      state.search = '';
      state.cursor = -1;
      renderListView();
      search?.focus();
      event.preventDefault();
    }
    return;
  }

  if (state.view !== 'list') return;

  const items = visibleItems();

  if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
    if (!items.length) return;
    const step = event.key === 'ArrowDown' ? 1 : -1;
    state.cursor = Math.max(0, Math.min(items.length - 1, state.cursor + step));
    renderListView();
    $('.item-row.cur')?.scrollIntoView({ block: 'nearest' });
    event.preventDefault();
    return;
  }

  if (event.key === 'Enter' && items[state.cursor]) {
    // 検索欄で入力中でも開ける。矢印で選んでそのまま Enter が自然な流れ。
    openItem(items[state.cursor].id);
    event.preventDefault();
    return;
  }

  // 選んでいる項目のパスワードを、開かずに写す
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'c' && items[state.cursor]) {
    if (!window.getSelection()?.toString()) {
      const password = V.primaryPassword(items[state.cursor]);
      if (password) { copySecret(password, 'パスワード'); event.preventDefault(); }
    }
    return;
  }

  // 文字を打ったら検索へ吸い込む。どこを触っていても探し始められる。
  if (!typing && event.key.length === 1 && !event.metaKey && !event.ctrlKey && !event.altKey) {
    search?.focus();
  }
});

for (const event of ['click', 'keydown', 'pointermove']) {
  document.addEventListener(event, noteActivity, { passive: true });
}

window.addEventListener('beforeunload', event => {
  if (state.dirty) { event.preventDefault(); event.returnValue = ''; }
});

