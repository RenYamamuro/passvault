// Watchtower（保管庫全体の弱点の洗い出し）と、2 つの保管庫のマージ。
// どちらも通信をせず、渡された値だけで判断する。

import { estimateBits, strengthLevel } from './crypto-extras.js';
import { displayTitle, primaryPassword } from './core.js';

// ============================================================
// Watchtower
// ============================================================

export const FINDING_KINDS = {
  reused: {
    title: '使い回している', icon: '🔁', severity: 0,
    explanation: '1つのサービスが漏れると、同じパスワードを使った他のサービスも芋づる式に破られます。',
  },
  weak: {
    title: '推測されやすい', icon: '⚠️', severity: 1,
    explanation: '総当たりや辞書攻撃で破られやすいパスワードです。生成機能で作り直すのが確実です。',
  },
  old: {
    title: '長く変えていない', icon: '🕰', severity: 2,
    explanation: '1年以上変えていないパスワードです。気づかないうちに漏れている可能性があります。',
  },
  insecureURL: {
    title: '保護されていないサイト', icon: '🔓', severity: 3,
    explanation: 'http:// のサイトは通信が暗号化されません。https:// が使えないか確認してください。',
  },
};

export const AGE_THRESHOLD_MS = 365 * 24 * 60 * 60 * 1000;
export const WEAK_THRESHOLD_BITS = 50;

/// 現在のパスワードを使い始めた日。
/// 履歴の最新は「1つ前のパスワードを捨てた日」＝今のパスワードを設定した日にあたる。
export function lastPasswordChange(item) {
  const times = (item.passwordHistory ?? []).map(change => Date.parse(change.changedAt));
  return times.length ? Math.max(...times) : Date.parse(item.createdAt);
}

export function audit(items, now = Date.now()) {
  const active = items.filter(item => !item.trashedAt);
  const findings = [];

  // 使い回し: 同じパスワードを持つアイテムが 2 つ以上ある
  const byPassword = new Map();
  for (const item of active) {
    const password = primaryPassword(item);
    if (!password) continue;
    if (!byPassword.has(password)) byPassword.set(password, []);
    byPassword.get(password).push(item);
  }
  for (const group of byPassword.values()) {
    if (group.length < 2) continue;
    for (const item of group) {
      const others = group.filter(other => other.id !== item.id).map(displayTitle).sort();
      findings.push({
        itemId: item.id, itemTitle: displayTitle(item), kind: 'reused',
        detail: `同じパスワードを ${others.join('、')} でも使っています`,
      });
    }
  }

  for (const item of active) {
    const password = primaryPassword(item);
    if (password) {
      const bits = estimateBits(password);
      if (bits < WEAK_THRESHOLD_BITS) {
        findings.push({
          itemId: item.id, itemTitle: displayTitle(item), kind: 'weak',
          detail: `推定 ${Math.floor(bits)} ビット相当（${strengthLevel(bits).label}）`,
        });
      }
      const changedAt = lastPasswordChange(item);
      if (now - changedAt > AGE_THRESHOLD_MS) {
        const years = (now - changedAt) / AGE_THRESHOLD_MS;
        findings.push({
          itemId: item.id, itemTitle: displayTitle(item), kind: 'old',
          detail: `最後に変更してから約 ${years.toFixed(1)} 年`,
        });
      }
    }
    for (const field of item.fields) {
      if (field.kind === 'url' && field.value.toLowerCase().startsWith('http://')) {
        findings.push({
          itemId: item.id, itemTitle: displayTitle(item), kind: 'insecureURL',
          detail: field.value,
        });
      }
    }
  }

  return findings.sort((a, b) => {
    const bySeverity = FINDING_KINDS[a.kind].severity - FINDING_KINDS[b.kind].severity;
    if (bySeverity !== 0) return bySeverity;
    return a.itemTitle.localeCompare(b.itemTitle, 'ja');
  });
}

// ============================================================
// マージ
// ============================================================
//
// 方針は「項目ごとに新しい方を採る」。
// 項目そのものは updatedAt、完全削除は墓標の deletedAt で比べる。
// どちらの側から取り込んでも同じ結果になり、何度繰り返しても増殖しない。

/// 墓標を保持しておく期間。これを過ぎたものは、
/// もうすべての端末に伝わっているとみなして捨てる。
export const TOMBSTONE_LIFETIME_MS = 180 * 24 * 60 * 60 * 1000;

export function merge(local, remote, now = Date.now()) {
  const summary = { added: 0, updated: 0, deleted: 0, unchanged: 0 };

  const pick = (items) => {
    const map = new Map();
    for (const item of items) {
      const existing = map.get(item.id);
      if (!existing || Date.parse(item.updatedAt) > Date.parse(existing.updatedAt)) {
        map.set(item.id, item);
      }
    }
    return map;
  };
  const localItems = pick(local.items);
  const remoteItems = pick(remote.items);

  const deletions = new Map();
  for (const deletion of [...(local.deletions ?? []), ...(remote.deletions ?? [])]) {
    const existing = deletions.get(deletion.id);
    if (!existing || Date.parse(deletion.deletedAt) > Date.parse(existing.deletedAt)) {
      deletions.set(deletion.id, deletion);
    }
  }

  const mergedItems = [];
  const allIds = new Set([...localItems.keys(), ...remoteItems.keys(), ...deletions.keys()]);

  for (const id of allIds) {
    const localItem = localItems.get(id);
    const remoteItem = remoteItems.get(id);
    let winner = null;
    if (localItem && remoteItem) {
      winner = Date.parse(remoteItem.updatedAt) > Date.parse(localItem.updatedAt) ? remoteItem : localItem;
    } else {
      winner = localItem ?? remoteItem ?? null;
    }
    if (!winner) continue;

    const deletion = deletions.get(id);
    if (deletion && Date.parse(deletion.deletedAt) > Date.parse(winner.updatedAt)) {
      if (localItem) summary.deleted += 1;
      continue;
    }

    mergedItems.push(winner);
    if (!localItem) summary.added += 1;
    else if (JSON.stringify(winner) !== JSON.stringify(localItem)) summary.updated += 1;
    else summary.unchanged += 1;
  }

  // 保存されるバイト列がぶれないよう順序を固定する
  mergedItems.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));

  const liveDeletions = [...deletions.values()]
    .filter(deletion => now - Date.parse(deletion.deletedAt) < TOMBSTONE_LIFETIME_MS)
    .sort((a, b) => Date.parse(a.deletedAt) - Date.parse(b.deletedAt));

  return { payload: { schemaVersion: 3, items: mergedItems, deletions: liveDeletions }, summary };
}

export function summaryText(summary) {
  const parts = [];
  if (summary.added) parts.push(`追加 ${summary.added}`);
  if (summary.updated) parts.push(`更新 ${summary.updated}`);
  if (summary.deleted) parts.push(`削除 ${summary.deleted}`);
  return parts.length ? parts.join('、') : '変更はありませんでした';
}
