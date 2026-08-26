// 項目の詳細表示と、各ダイアログ（編集・生成・設定）。

import * as V from './core.js';
import * as X from './crypto-extras.js';
import * as A from './audit.js';
import { icon, CATEGORY_LOOK, FINDING_ICONS } from './icons.js';
import {
  state, settings, save, forceSave, downloadVault, toast, noteActivity, filterBy,
  readVaultFileBytes, applyMerge,
  copyPlain, copySecret, el, $, fmtDateTime,
  activeItems, trashedItems, CLIPBOARD_CLEAR_SECONDS,
  render, hooks,
} from './app.js';

const STRENGTH_COLORS = ['var(--danger)', 'var(--danger)', 'var(--warn)', 'var(--ok)', 'var(--accent)'];

function strengthRow(password) {
  const bits = X.estimateBits(password);
  const level = X.strengthLevel(bits);
  const color = STRENGTH_COLORS[level.rank];
  return el('div', { className: 'strength' }, [
    el('span', { className: 'bar' }, [
      el('i', { style: `width:${Math.min(bits / 128, 1) * 100}%;background:${color}` }),
    ]),
    el('span', { className: 'lv', style: `color:${color}`, textContent: `${level.label}（推定 ${Math.floor(bits)} ビット）` }),
  ]);
}

// ============================================================
// 詳細
// ============================================================

let otpTimer = null;

hooks.renderDetail = function renderDetail() {
  clearInterval(otpTimer);
  const column = $('#main');
  const item = state.items.find(candidate => candidate.id === state.selectedId);

  if (!item) {
    // render() が一覧へ戻すので普通は通らない。通ったときに空白を残さないための備え。
    column.replaceChildren(el('div', { className: 'sheet' }, [
      el('div', { className: 'empty' }, [
        el('span', { className: 'big' }, [icon('inbox', 38)]),
        el('span', { className: 'lead', textContent: 'この項目は見つかりませんでした' }),
      ]),
    ]));
    return;
  }

  const findings = state.findings.filter(finding => finding.itemId === item.id);
  const parts = [];

  const look = CATEGORY_LOOK[item.category];
  const favButton = el('button', {
    className: `iconbtn${item.isFavorite ? ' on' : ''}`,
    title: item.isFavorite ? 'お気に入りから外す' : 'お気に入りに追加',
    'aria-label': item.isFavorite ? 'お気に入りから外す' : 'お気に入りに追加',
    onclick: async () => { item.isFavorite = !item.isFavorite; item.updatedAt = V.isoNoMillis(); await save(); render(); },
  }, [icon(item.isFavorite ? 'starFill' : 'star', 19)]);
  if (item.isFavorite) favButton.style.color = '#e8b021';

  parts.push(el('div', { className: 'detail-head' }, [
    el('div', { className: 'avatar', style: `--hue:${look.hue}` }, [icon(look.icon, 26)]),
    el('div', { className: 'grow' }, [
      el('h1', { textContent: V.displayTitle(item) }),
      el('button', {
        className: 'cat', title: `${V.CATEGORIES[item.category].name}だけを見る`,
        onclick: () => filterBy({ kind: 'category', value: item.category }),
        textContent: V.CATEGORIES[item.category].name,
      }),
    ]),
    favButton,
  ]));

  if (item.trashedAt) {
    parts.push(el('div', { className: 'banner quiet' }, [
      icon('trash'),
      el('div', {}, [
        el('div', { className: 'bt', textContent: 'この項目はゴミ箱にあります' }),
        el('div', { className: 'bd', textContent: '元に戻すまで検索結果には出てきません。' }),
      ]),
    ]));
  }

  for (const finding of findings) {
    const kind = A.FINDING_KINDS[finding.kind];
    parts.push(el('div', { className: 'banner' }, [
      icon(FINDING_ICONS[finding.kind]),
      el('div', {}, [
        el('div', { className: 'bt', textContent: kind.title }),
        el('div', { className: 'bd', textContent: finding.detail }),
      ]),
    ]));
  }

  const filled = item.fields.filter(field => field.value.trim());
  if (filled.length) {
    parts.push(el('div', { className: 'card' }, filled.map(field => fieldRow(field))));
  }

  if (item.oneTimePasswordSecret) {
    const otpCard = el('div', { className: 'card' });
    parts.push(otpCard);
    mountOTP(otpCard, item.oneTimePasswordSecret);
  }

  if (item.tags.length) {
    // 押したらそのタグで絞る。札から種別とタグを外したぶん、
    // ここが「同じ仲間を見る」ための入口になる。
    parts.push(el('div', { className: 'tags' },
      item.tags.map(tag => el('button', {
        className: 'tag', title: `「${tag}」で絞り込む`,
        onclick: () => filterBy({ kind: 'tag', value: tag }),
      }, [icon('tag', 12), tag]))));
  }

  if (item.notes) {
    parts.push(el('div', { className: 'lab', style: 'font-size:12px;color:var(--text-2);margin-bottom:4px', textContent: 'メモ' }));
    parts.push(el('div', { className: 'notes', textContent: item.notes }));
  }

  if (item.passwordHistory.length) {
    const list = el('div', { className: 'card' }, item.passwordHistory.map(change =>
      el('div', { className: 'row' }, [
        el('div', { className: 'grow' }, [
          el('div', { className: 'val mono', textContent: change.value }),
          el('div', { className: 'lab', textContent: `${fmtDateTime(change.changedAt)} まで使用` }),
        ]),
        el('button', {
          className: 'iconbtn', title: 'コピー', 'aria-label': '以前のパスワードをコピー',
          onclick: () => copySecret(change.value, '以前のパスワード'),
        }, [icon('copy')]),
      ])));
    parts.push(el('details', { className: 'history' }, [
      el('summary', { textContent: `以前のパスワード（${item.passwordHistory.length}件）` }),
      list,
    ]));
  }

  parts.push(el('div', { className: 'meta', textContent:
    // 並べて出すので書式を揃える。片方だけ和暦風だと目が引っかかる。
    `更新: ${fmtDateTime(item.updatedAt)}　作成: ${fmtDateTime(item.createdAt)}` }));

  const actions = el('div', { className: 'actions' });
  if (item.trashedAt) {
    actions.append(
      el('button', { className: 'push primary', textContent: '元に戻す', onclick: async () => {
        delete item.trashedAt; item.updatedAt = V.isoNoMillis();
        if (!await save()) return;
        toast('元に戻しました'); render();
      } }),
      el('button', { className: 'push', textContent: '完全に削除', onclick: async () => {
        const ok = await hooks.askConfirm('完全に削除',
          `「${V.displayTitle(item)}」を完全に削除します。取り消せません。`,
          { confirmLabel: '完全に削除', destructive: true });
        if (!ok) return;
        state.items = state.items.filter(candidate => candidate.id !== item.id);
        state.deletions.push({ id: item.id, deletedAt: V.isoNoMillis() });
        state.selectedId = null;
        state.view = 'list';
        if (!await save()) return;
        toast('完全に削除しました'); render();
      } }),
    );
  } else {
    actions.append(
      el('button', { className: 'push primary', textContent: '編集', onclick: () => openEditor(item) }),
      el('button', { className: 'push', textContent: 'ゴミ箱に入れる', onclick: async () => {
        item.trashedAt = V.isoNoMillis(); item.updatedAt = item.trashedAt;
        state.selectedId = null;
        state.view = 'list';
        if (!await save()) return;
        toast('ゴミ箱に入れました'); render();
      } }),
    );
  }
  parts.push(actions);

  column.replaceChildren(el('div', { className: 'sheet detail' }, parts));
};

function fieldRow(field) {
  const concealed = V.isConcealed(field.kind);
  const revealed = state.revealed.has(field.id);
  const shown = concealed && !revealed
    ? '•'.repeat(Math.min(Math.max(field.value.length, 8), 24))
    : (field.kind === 'cardNumber' ? V.groupedCardNumber(field.value) : field.value);

  const value = field.kind === 'url'
    ? el('a', { className: 'val', href: normalizeURL(field.value), target: '_blank', rel: 'noreferrer noopener', textContent: field.value })
    : el('div', { className: `val${concealed ? ' mono' : ''}`, textContent: shown });

  const body = el('div', { className: 'grow' }, [
    el('div', { className: 'lab', textContent: field.label }),
    value,
    field.kind === 'password' && field.value ? strengthRow(field.value) : null,
  ]);

  const row = el('div', { className: 'row' }, [body]);
  if (concealed) {
    row.append(el('button', {
      className: 'iconbtn', title: revealed ? '隠す' : '表示',
      'aria-label': revealed ? `${field.label}を隠す` : `${field.label}を表示`,
      onclick: () => {
        revealed ? state.revealed.delete(field.id) : state.revealed.add(field.id);
        hooks.renderDetail();
      },
    }, [icon(revealed ? 'eyeOff' : 'eye')]));
  }
  row.append(el('button', {
    className: 'iconbtn', title: 'コピー', 'aria-label': `${field.label}をコピー`,
    onclick: () => concealed ? copySecret(field.value, field.label) : copyPlain(field.value, field.label),
  }, [icon('copy')]));
  return row;
}

function normalizeURL(value) {
  return value.includes('://') ? value : `https://${value}`;
}

/// ワンタイムパスワード。1 秒ごとに残り時間の輪が縮んでいく。
function mountOTP(container, secret) {
  const config = X.parseOTP(secret);
  if (!config) {
    container.replaceChildren(el('div', { className: 'row' }, [
      icon('warning'),
      el('div', { className: 'grow', textContent: 'ワンタイムパスワードの設定を読み取れませんでした' }),
    ]));
    return;
  }

  const code = el('div', { className: 'code', textContent: '••• •••' });
  const ring = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  ring.setAttribute('viewBox', '0 0 32 32');
  ring.setAttribute('class', 'ring');
  ring.innerHTML =
    '<circle cx="16" cy="16" r="14" fill="none" stroke="var(--hairline)" stroke-width="3"/>' +
    '<circle id="arc" cx="16" cy="16" r="14" fill="none" stroke="var(--accent)" stroke-width="3"' +
    ' stroke-linecap="round" transform="rotate(-90 16 16)"/>' +
    '<text x="16" y="20" text-anchor="middle">0</text>';

  container.replaceChildren(el('div', { className: 'otp' }, [
    el('div', { className: 'grow' }, [
      el('div', { className: 'lab', textContent: 'ワンタイムパスワード' }),
      code,
    ]),
    ring,
    el('button', {
      className: 'iconbtn', title: 'コピー', 'aria-label': 'ワンタイムパスワードをコピー',
      onclick: async () => copySecret(await X.otpCode(config), 'ワンタイムパスワード'),
    }, [icon('copy')]),
  ]));

  const circumference = 2 * Math.PI * 14;
  async function tick() {
    const remaining = X.otpSecondsRemaining(config);
    code.textContent = X.formatOTP(await X.otpCode(config));
    code.style.color = remaining <= 5 ? 'var(--warn)' : '';
    const arc = ring.querySelector('#arc');
    arc.setAttribute('stroke-dasharray', String(circumference));
    arc.setAttribute('stroke-dashoffset', String(circumference * (1 - remaining / config.period)));
    arc.setAttribute('stroke', remaining <= 5 ? 'var(--warn)' : 'var(--accent)');
    ring.querySelector('text').textContent = String(remaining);
  }
  tick();
  otpTimer = setInterval(tick, 1000);
}

// ============================================================
// 新規作成
// ============================================================

hooks.openNewItemMenu = function () {
  const dialog = makeDialog('新しい項目', null);
  const body = dialog.querySelector('.dlg-body');
  body.append(el('div', { className: 'group' }, Object.entries(V.CATEGORIES).map(([id, category]) =>
    el('button', { className: 'g-row', style: 'display:flex;gap:10px;align-items:center',
      onclick: () => { dialog.close(); openEditor(V.makeItem(id), true); },
    }, [
      el('span', { className: 'avatar small', style: `--hue:${CATEGORY_LOOK[id].hue}` },
        [icon(CATEGORY_LOOK[id].icon, 14)]),
      el('span', { textContent: category.name }),
    ]))));
  dialog.showModal();
};

// ============================================================
// 編集
// ============================================================

function openEditor(original, isNew = false) {
  const draft = structuredClone(original);
  const category = V.CATEGORIES[draft.category];
  let tagText = draft.tags.join(', ');

  const dialog = makeDialog(isNew ? `新規${category.name}` : '編集', async () => {
    const title = draft.title.trim();
    if (!title) { toast('タイトルを入力してください'); return false; }
    draft.tags = tagText.split(',').map(tag => tag.trim()).filter(Boolean);
    draft.oneTimePasswordSecret = draft.oneTimePasswordSecret.trim();
    draft.updatedAt = V.isoNoMillis();

    const index = state.items.findIndex(item => item.id === draft.id);
    if (index >= 0) {
      // パスワードが変わったら、古いものを履歴に残す
      const previous = V.primaryPassword(state.items[index]);
      if (previous && previous !== V.primaryPassword(draft)) {
        draft.passwordHistory = [{ id: crypto.randomUUID(), value: previous, changedAt: V.isoNoMillis() },
                                 ...draft.passwordHistory].slice(0, 20);
      }
      state.items[index] = draft;
    } else {
      state.items.push(draft);
    }
    state.selectedId = draft.id;
    if (!await save()) return false;   // 失敗したらダイアログを閉じない
    toast('保存しました');
    render();
    return true;
  });

  const body = dialog.querySelector('.dlg-body');

  const titleInput = el('input', { className: 'field', value: draft.title, placeholder: category.placeholder,
    oninput: event => { draft.title = event.target.value; } });
  body.append(el('div', { className: 'group' }, [
    el('div', { className: 'g-row' }, [el('span', { className: 'g-lab', textContent: 'タイトル' }), titleInput]),
    el('div', { className: 'g-row between' }, [
      el('span', { textContent: '種別' }),
      el('span', { className: 'inline', style: 'color:var(--text-2)' },
        [icon(CATEGORY_LOOK[draft.category].icon, 15), category.name]),
    ]),
  ]));

  const fieldsGroup = el('div', { className: 'group' });
  const renderFields = () => {
    fieldsGroup.replaceChildren(...draft.fields.map((field, index) => editorField(draft, field, index, renderFields)));
  };
  renderFields();
  if (draft.fields.length) {
    body.append(el('div', { className: 'g-title', textContent: '項目' }), fieldsGroup);
  } else {
    body.append(fieldsGroup);
  }

  body.append(el('div', { className: 'group' }, [
    el('button', { className: 'g-row', style: 'color:var(--accent)',
      textContent: '＋ 欄を追加',
      onclick: async () => {
        const label = await hooks.askText('欄を追加', '欄の名前',
          { placeholder: '例: 復旧コード' });
        if (!label) return;
        draft.fields.push({ id: crypto.randomUUID(), label, value: '', kind: 'text', isCustom: true });
        renderFields();
      } }),
  ]));

  if (category.otp) {
    const preview = el('div', { className: 'lab', style: 'display:flex;align-items:center;gap:5px' });
    const otpInput = el('input', {
      className: 'field', value: draft.oneTimePasswordSecret,
      placeholder: 'otpauth://totp/... または Base32 のシークレット',
      style: 'font-family:ui-monospace,monospace',
      oninput: async event => { draft.oneTimePasswordSecret = event.target.value; await updatePreview(); },
    });
    async function updatePreview() {
      const config = X.parseOTP(draft.oneTimePasswordSecret);
      if (!draft.oneTimePasswordSecret.trim()) { preview.replaceChildren(); return; }
      if (!config) {
        preview.style.color = 'var(--warn)';
        preview.replaceChildren(icon('warning', 13), 'この文字列からはコードを作れません');
        return;
      }
      preview.style.color = 'var(--ok)';
      preview.replaceChildren(icon('check', 13),
        `${X.formatOTP(await X.otpCode(config))}（残り ${X.otpSecondsRemaining(config)} 秒）`);
    }
    updatePreview();
    body.append(
      el('div', { className: 'g-title', textContent: 'ワンタイムパスワード' }),
      el('div', { className: 'group' }, [el('div', { className: 'g-row' }, [otpInput, preview])]),
      el('div', { className: 'g-foot', textContent: '認証アプリの登録画面に出る「手動入力用のキー」か、QRコードの中身（otpauth://…）をそのまま貼り付けてください。' }),
    );
  }

  const tagInput = el('input', { className: 'field', value: tagText, placeholder: 'カンマ区切り（例: 仕事, 経理）',
    oninput: event => { tagText = event.target.value; } });
  const existing = [...new Set(activeItems().flatMap(item => item.tags))].filter(Boolean).sort();
  const suggestions = el('div', { style: 'display:flex;flex-wrap:wrap;gap:6px;margin-top:8px' },
    existing.map(tag => el('button', { className: 'pill', textContent: tag, onclick: () => {
      const tags = tagInput.value.split(',').map(t => t.trim()).filter(Boolean);
      if (!tags.includes(tag)) tags.push(tag);
      tagInput.value = tagText = tags.join(', ');
    } })));
  body.append(
    el('div', { className: 'g-title', textContent: 'タグ' }),
    el('div', { className: 'group' }, [el('div', { className: 'g-row' }, [tagInput, existing.length ? suggestions : null])]),
  );

  const notes = el('textarea', { className: 'field', rows: 4, value: draft.notes,
    oninput: event => { draft.notes = event.target.value; } });
  body.append(
    el('div', { className: 'g-title', textContent: 'メモ' }),
    el('div', { className: 'group' }, [el('div', { className: 'g-row' }, [notes])]),
  );

  dialog.showModal();
  setTimeout(() => titleInput.focus(), 0);
}

function editorField(draft, field, index, refresh) {
  const concealed = V.isConcealed(field.kind);
  const key = `edit-${field.id}`;
  const revealed = state.revealed.has(key);

  const input = field.kind === 'multiline'
    ? el('textarea', { className: 'field', rows: 3, value: field.value })
    : el('input', { className: 'field', type: concealed && !revealed ? 'password' : 'text', value: field.value });
  input.oninput = event => { field.value = event.target.value; if (field.kind === 'password') refreshStrength(); };
  if (concealed) input.style.fontFamily = 'ui-monospace, monospace';

  const strength = el('div');
  const refreshStrength = () => {
    strength.replaceChildren(field.value ? strengthRow(field.value) : el('span'));
  };
  refreshStrength();

  const controls = el('div', { className: 'inline' }, [el('span', { className: 'grow' }, [input])]);
  if (concealed) {
    controls.append(el('button', { className: 'iconbtn',
      title: revealed ? '隠す' : '表示', 'aria-label': revealed ? '隠す' : '表示',
      onclick: () => { revealed ? state.revealed.delete(key) : state.revealed.add(key); refresh(); } },
      [icon(revealed ? 'eyeOff' : 'eye')]));
  }
  if (field.kind === 'password') {
    controls.append(el('button', { className: 'iconbtn', title: 'パスワードを生成',
      'aria-label': 'パスワードを生成',
      onclick: () => hooks.openGenerator(generated => {
        field.value = generated;
        input.value = generated;
        state.revealed.add(key);
        refresh();
      }) }, [icon('wand')]));
  }

  const header = el('div', { className: 'inline' }, [
    el('span', { className: 'g-lab grow', textContent: field.label }),
    field.isCustom ? el('button', { className: 'iconbtn', title: 'この欄を削除',
      'aria-label': 'この欄を削除',
      onclick: () => { draft.fields.splice(index, 1); refresh(); } }, [icon('close', 14)]) : null,
  ]);

  return el('div', { className: 'g-row' }, [header, controls, field.kind === 'password' ? strength : null]);
}

// ============================================================
// パスワード生成
// ============================================================

hooks.openGenerator = function (onUse) {
  const options = { length: 20, lower: true, upper: true, digits: true, symbols: true, avoidAmbiguous: true };
  let current = '';

  const output = el('div', { className: 'val mono', style: 'font-size:17px;word-break:break-all;min-height:24px' });
  const strength = el('div');
  const lengthLabel = el('span', { textContent: '20 文字' });
  const bitsLabel = el('span', { style: 'color:var(--text-2);font-size:12px' });

  function regenerate() {
    current = X.generatePassword(options);
    output.textContent = current;
    strength.replaceChildren(current ? strengthRow(current) : el('span'));
    lengthLabel.textContent = `${options.length} 文字`;
    bitsLabel.textContent = `約 ${Math.floor(X.generatorEntropyBits(options))} ビット`;
  }

  const dialog = makeDialog('パスワード生成', onUse ? () => { onUse(current); return true; } : async () => {
    await copySecret(current, '生成したパスワード');
    return true;
  }, onUse ? '使う' : 'コピー');

  const body = dialog.querySelector('.dlg-body');
  body.append(el('div', { className: 'group' }, [
    el('div', { className: 'g-row' }, [output, strength]),
    el('div', { className: 'g-row' }, [
      el('button', { className: 'push', style: 'width:auto', onclick: regenerate },
        [icon('wand', 14), ' 作り直す']),
    ]),
  ]));

  const slider = el('input', { type: 'range', min: '8', max: '64', value: String(options.length),
    style: 'width:100%', oninput: event => { options.length = Number(event.target.value); regenerate(); } });
  body.append(
    el('div', { className: 'g-title', textContent: '長さ' }),
    el('div', { className: 'group' }, [
      el('div', { className: 'g-row' }, [
        el('div', { className: 'between' }, [lengthLabel, bitsLabel]),
        slider,
      ]),
    ]),
  );

  const toggles = [
    ['lower', '小文字 a-z'], ['upper', '大文字 A-Z'], ['digits', '数字 0-9'],
    ['symbols', '記号 !#$%…'], ['avoidAmbiguous', '紛らわしい文字を除く（0 O 1 l I など）'],
  ];
  body.append(
    el('div', { className: 'g-title', textContent: '使う文字' }),
    el('div', { className: 'group' }, toggles.map(([key, label]) =>
      el('label', { className: 'g-row between' }, [
        el('span', { textContent: label }),
        el('input', { type: 'checkbox', checked: options[key],
          onchange: event => { options[key] = event.target.checked; regenerate(); } }),
      ]))),
  );

  regenerate();
  dialog.showModal();
};

// ============================================================
// 設定
// ============================================================

hooks.openSettings = function () {
  const dialog = makeDialog('設定', null);
  const body = dialog.querySelector('.dlg-body');

  const awaySwitch = el('input', { type: 'checkbox', checked: settings.lockWhenAway,
    onchange: event => { settings.lockWhenAway = event.target.checked; } });

  const lockSelect = el('select', { className: 'field', style: 'width:auto',
    onchange: event => { settings.autoLockMinutes = Number(event.target.value); } });
  for (const minutes of [0, 1, 5, 15, 30, 60]) {
    lockSelect.append(el('option', { value: String(minutes),
      textContent: minutes === 0 ? 'しない' : `${minutes} 分後`,
      selected: settings.autoLockMinutes === minutes }));
  }

  body.append(
    el('div', { className: 'g-title', textContent: 'セキュリティ' }),
    el('div', { className: 'group' }, [
      el('div', { className: 'g-row between' }, [el('span', { textContent: '自動ロック' }), lockSelect]),
      el('button', { className: 'g-row', style: 'color:var(--accent)',
        textContent: 'マスターパスワードを変更…', onclick: () => { dialog.close(); openPasswordChange(); } }),
      el('div', { className: 'g-row between' }, [
        el('span', { textContent: '画面を離れたら施錠' }),
        awaySwitch,
      ]),
      el('button', { className: 'g-row', style: 'color:var(--accent)',
        textContent: '緊急用シートを作る…', onclick: () => { dialog.close(); openEmergencyKit(); } }),
    ]),
    el('div', { className: 'g-foot', textContent:
      'マスターパスワードを忘れると中身は永久に取り出せません。復旧の窓口はありません。'
      + '緊急用シートは、その備えとして紙に残すためのものです。' }),
  );

  const onFile = Boolean(state.fileHandle);
  const fileRows = [
    el('div', { className: 'g-row between' }, [
      el('span', { textContent: '保存先' }),
      el('span', { style: 'color:var(--text-2)',
                   textContent: onFile ? (state.fileName ?? '未設定') : 'この端末の中' }),
    ]),
    el('div', { className: 'g-row between' }, [
      el('span', { textContent: '自動保存' }),
      el('span', { style: 'color:var(--text-2)',
                   textContent: onFile ? 'ファイルへ書き込み' : 'この端末へ書き込み' }),
    ]),
  ];
  if (!onFile) {
    fileRows.push(el('button', { className: 'g-row', style: 'color:var(--accent)',
      textContent: '同期用に書き出す…',
      onclick: () => downloadVault({ forSync: true }) }));
  }
  fileRows.push(
    el('button', { className: 'g-row', style: 'color:var(--accent)',
      textContent: '保管庫を書き出す（バックアップ）', onclick: () => downloadVault() }),
    el('button', { className: 'g-row', style: 'color:var(--accent)',
      textContent: '別の保管庫を取り込む…', onclick: () => { dialog.close(); importFromFile(); } }),
    el('button', { className: 'g-row', style: 'color:var(--accent)',
      textContent: '他のアプリから取り込む（CSV）…', onclick: () => { dialog.close(); importFromCSV(); } }),
  );

  body.append(
    el('div', { className: 'g-title', textContent: onFile ? 'ファイル' : '保存と同期' }),
    el('div', { className: 'group' }, fileRows),
    el('div', { className: 'g-foot', textContent: onFile
      ? '書き出したファイルをコピーしておけばバックアップになります。中身は暗号化されているので、そのままクラウドに置いても平文は漏れません。ただしマスターパスワードを忘れると復元は不可能です。'
      : 'このブラウザはファイルに直接書けないので、保管庫はこの端末の中に暗号化して置いてあります。'
        + '別の端末と合わせるときは「同期用に書き出す」でクラウド上の保管庫に上書きし、'
        + '相手の変更は「別の保管庫を取り込む」で受け取ってください。'
        + 'ブラウザの保存領域は消えることがあるので、控えの書き出しも忘れずに。' }),
  );

  body.append(
    el('div', { className: 'g-title', textContent: '保管庫' }),
    el('div', { className: 'group' }, [
      row('登録件数', `${activeItems().length} 件`),
      row('ゴミ箱', `${trashedItems().length} 件`),
      row('暗号化', 'AES-256-GCM'),
      row('鍵導出', `PBKDF2-SHA512 / ${state.header.iterations.toLocaleString()} 回`),
      row('クリップボード', `${CLIPBOARD_CLEAR_SECONDS} 秒で自動消去`),
      // どの版が動いているかを見えるようにしておく。置き場所から配っている場合、
      // 中身が入れ替わったかどうかを確かめる手がかりがこれしかない。
      row('この画面の版', window.PASSVAULT_BUILD ?? '開発中（ビルド前）'),
    ]),
  );

  function row(label, value) {
    return el('div', { className: 'g-row between' }, [
      el('span', { textContent: label }),
      el('span', { style: 'color:var(--text-2)', textContent: value }),
    ]);
  }

  dialog.showModal();
};

function openPasswordChange() {
  const current = el('input', { className: 'field', type: 'password', placeholder: '現在のマスターパスワード' });
  const next = el('input', { className: 'field', type: 'password', placeholder: '新しいマスターパスワード（12文字以上）' });
  const confirmField = el('input', { className: 'field', type: 'password', placeholder: 'もう一度入力' });
  const error = el('div', { className: 'error' });

  const dialog = makeDialog('マスターパスワードを変更', async () => {
    error.textContent = '';
    if (next.value.length < 12) { error.textContent = '新しいパスワードは12文字以上にしてください。'; return false; }
    if (next.value !== confirmField.value) { error.textContent = '新しいパスワードの入力が一致していません。'; return false; }
    try {
      // 現在のパスワードが本当に合っているかを、いまの鍵で作った暗号文で確かめる
      const probe = await V.seal(payloadSnapshot(), state.key, state.header);
      const currentKey = await V.deriveKey(current.value, state.header);
      await V.open(probe, currentKey, state.header);
    } catch {
      error.textContent = '現在のマスターパスワードが違います。';
      return false;
    }
    // 鍵を差し替える前に、書き込めることを確かめる。
    // 書けないまま鍵だけ変えると、画面の鍵とファイルの鍵が食い違う。
    const previousHeader = state.header;
    const previousKey = state.key;
    state.header = V.makeHeader();
    state.key = await V.deriveKey(next.value, state.header);
    if (!await save()) {
      state.header = previousHeader;
      state.key = previousKey;
      error.textContent = 'ファイルに書けなかったため、変更を取り消しました。';
      return false;
    }
    toast('マスターパスワードを変更しました');
    return true;
  }, '変更');

  dialog.querySelector('.dlg-body').append(
    el('div', { className: 'group' }, [
      el('div', { className: 'g-row' }, [current]),
      el('div', { className: 'g-row' }, [next]),
      el('div', { className: 'g-row' }, [confirmField]),
    ]),
    error,
    el('div', { className: 'g-foot', textContent: '変更すると保管庫全体を新しい鍵で書き直します。古いパスワードでは開けなくなります。' }),
  );
  dialog.showModal();
}

const payloadSnapshot = () =>
  ({ schemaVersion: V.SCHEMA_VERSION, items: state.items, deletions: state.deletions });

// ============================================================
// 取り込み（マージ）
// ============================================================
//
// 失った同期の代わり。2 つの保管庫ファイルを突き合わせて、
// 項目ごとに更新時刻の新しい方を残す。どちら側から取り込んでも同じ結果になる。

/// 相手のファイルを開く。まず手元の鍵を試し、駄目ならパスワードを訊く。
/// 別の端末でマスターパスワードを変えていた場合は鍵が違うため。
async function decryptForeignVault(bytes) {
  const header = V.decodeHeader(bytes);

  const sameHeader = state.header
    && header.raw.length === state.header.raw.length
    && header.raw.every((byte, index) => byte === state.header.raw[index]);
  if (sameHeader) {
    try { return await V.open(bytes, state.key, header); } catch { /* 訊きに回る */ }
  }

  const password = await askPassword();
  if (password === null) return null;
  const key = await V.deriveKey(password, header);
  return V.open(bytes, key, header);  // 違えば例外が出る
}

function askPassword() {
  return new Promise(resolve => {
    const input = el('input', { className: 'field', type: 'password',
      placeholder: 'そのファイルのマスターパスワード' });
    let answered = false;
    const dialog = makeDialog('パスワードを入力', () => {
      if (!input.value) return false;
      answered = true;
      resolve(input.value);
      return true;
    }, '開く');
    dialog.onDismiss = () => { if (!answered) resolve(null); };
    dialog.querySelector('.dlg-body').append(
      el('div', { className: 'group' }, [el('div', { className: 'g-row' }, [input])]),
      el('div', { className: 'g-foot', textContent:
        'いま開いている保管庫とは別のパスワードで作られている場合に必要です。' }),
    );
    dialog.showModal();
    setTimeout(() => input.focus(), 0);
  });
}

/// 取り込む前に、何が起きるかを見せて確かめてもらう
function confirmMerge(remotePayload, sourceLabel) {
  return new Promise(resolve => {
    const preview = A.merge(
      { schemaVersion: V.SCHEMA_VERSION, items: state.items, deletions: state.deletions },
      remotePayload
    );
    const localIds = new Set(state.items.map(item => item.id));
    const added = preview.payload.items.filter(item => !localIds.has(item.id));
    const updated = preview.payload.items.filter(item => {
      const mine = state.items.find(candidate => candidate.id === item.id);
      return mine && JSON.stringify(mine) !== JSON.stringify(item);
    });

    let answered = false;
    const dialog = makeDialog('取り込みの確認', () => {
      answered = true;
      resolve(true);
      return true;
    }, '取り込む');
    dialog.onDismiss = () => { if (!answered) resolve(false); };

    const body = dialog.querySelector('.dlg-body');
    body.append(
      el('div', { className: 'g-foot', style: 'margin-top:0', textContent: `取り込み元: ${sourceLabel}` }),
      el('div', { className: 'group' }, [
        el('div', { className: 'g-row between' }, [
          el('span', { textContent: '結果' }),
          el('span', { style: 'color:var(--text-2)', textContent: A.summaryText(preview.summary) }),
        ]),
        el('div', { className: 'g-row between' }, [
          el('span', { textContent: '取り込み後の件数' }),
          el('span', { style: 'color:var(--text-2)',
                       textContent: `${preview.payload.items.filter(i => !i.trashedAt).length} 件` }),
        ]),
      ]),
    );

    const listGroup = (title, items) => {
      if (!items.length) return;
      body.append(
        el('div', { className: 'g-title', textContent: `${title}（${items.length}）` }),
        el('div', { className: 'group' }, items.slice(0, 12).map(item =>
          el('div', { className: 'g-row' }, [
            icon(CATEGORY_LOOK[item.category].icon, 14),
            el('span', { style: 'margin-left:7px', textContent: V.displayTitle(item) }),
          ]))),
      );
      if (items.length > 12) {
        body.append(el('div', { className: 'g-foot', textContent: `ほか ${items.length - 12} 件` }));
      }
    };
    listGroup('追加される項目', added);
    listGroup('上書きされる項目', updated);

    if (preview.summary.deleted) {
      body.append(el('div', { className: 'g-foot', style: 'color:var(--warn)', textContent:
        `相手側で完全に削除された ${preview.summary.deleted} 件は、こちらからも消えます。` }));
    }
    if (!added.length && !updated.length && !preview.summary.deleted) {
      body.append(el('div', { className: 'g-foot', textContent: '変わるものはありません。' }));
    }

    dialog.showModal();
  });
}

/// file を 1 つ選ばせる。取り消されたら null。
///
/// 選んでいる間は自動施錠を止める。環境によっては file 選択の窓が出た時点で
/// こちらが「隠れた」扱いになり、離席施錠が誤爆して、
/// 選び終えたときには施錠済み、ということが起こりうる。
async function pickFile(accept, description) {
  state.holds += 1;
  try {
    if (typeof window.showOpenFilePicker === 'function') {
      const [handle] = await window.showOpenFilePicker({
        types: [{ description, accept: { 'application/octet-stream': accept.split(',') } }],
      });
      return await handle.getFile();
    }
    return await new Promise((resolve, reject) => {
      const input = el('input', { type: 'file', accept });
      input.onchange = () => (input.files[0] ? resolve(input.files[0]) : reject());
      input.click();
    });
  } catch {
    return null;
  } finally {
    state.holds = Math.max(0, state.holds - 1);
    noteActivity();
  }
}

/// 相手のファイルを選んで取り込む
async function importFromFile() {
  const file = await pickFile('.pvlt', 'PassVault の保管庫');
  if (!file) return;
  await importBytes(new Uint8Array(await file.arrayBuffer()), file.name);
}

/// 他のアプリが書き出した CSV を取り込む。
///
/// Chrome / Safari / Bitwarden / 1Password / KeePassXC の書き出しを確認済み。
/// 列は見出しの名前で当てる。位置で決め打つと、書き出し元が変わった途端に
/// パスワードとユーザー名が入れ替わったまま気づけない。
async function importFromCSV() {
  const file = await pickFile('.csv,.txt', 'CSV');
  if (!file) return;

  let parsed;
  try {
    parsed = C.toRecords(C.parseCSV(await file.text()));
  } catch (caught) {
    toast(`読めませんでした: ${caught.message ?? caught}`);
    return;
  }
  if (!parsed) {
    toast('見出し行を読み取れませんでした。パスワードの列がある CSV を選んでください');
    return;
  }
  if (!parsed.records.length) {
    toast('中身のある行がありませんでした');
    return;
  }

  // 既にあるものは飛ばす。飛ばさないと、2 回取り込んだだけで全部が倍になる。
  const known = new Set(state.items.map(item =>
    C.identity(V.displayTitle(item), V.primaryUsername(item) ?? '')));
  const fresh = parsed.records.filter(record => !known.has(C.identity(record.title, record.username)));
  const skipped = parsed.records.length - fresh.length;

  if (!await confirmCSV(file.name, parsed, fresh, skipped)) {
    toast('取り込みを中止しました');
    return;
  }
  if (!fresh.length) return;

  for (const record of fresh) {
    const item = V.makeItem('login');
    item.title = record.title;
    item.fields[0].value = record.username;
    item.fields[1].value = record.password;
    item.fields[2].value = record.url;
    item.notes = record.notes;
    item.tags = record.tags;
    item.isFavorite = record.favorite;
    if (record.totp && X.parseOTP(record.totp)) item.oneTimePasswordSecret = record.totp;
    state.items.push(item);
  }
  if (!await save()) return;
  toast(`${fresh.length} 件を取り込みました`);
  render();
}

/// 取り込む前に中身を見せる。パスワードは出さない。
function confirmCSV(sourceName, parsed, fresh, skipped) {
  return new Promise(resolve => {
    let answered = false;
    const dialog = makeDialog('CSV の取り込み', () => { answered = true; resolve(true); return true; },
                              fresh.length ? '取り込む' : '閉じる');
    dialog.onDismiss = () => { if (!answered) resolve(false); };

    const found = Object.keys(parsed.mapping);
    const body = dialog.querySelector('.dlg-body');
    body.append(
      el('div', { className: 'g-foot', style: 'margin-top:0', textContent: `取り込み元: ${sourceName}` }),
      el('div', { className: 'group' }, [
        el('div', { className: 'g-row between' }, [
          el('span', { textContent: '読めた行' }),
          el('span', { style: 'color:var(--text-2)', textContent: `${parsed.records.length} 件` }),
        ]),
        el('div', { className: 'g-row between' }, [
          el('span', { textContent: '新しく入るもの' }),
          el('span', { style: 'color:var(--accent)', textContent: `${fresh.length} 件` }),
        ]),
        skipped ? el('div', { className: 'g-row between' }, [
          el('span', { textContent: '既にあるので飛ばすもの' }),
          el('span', { style: 'color:var(--text-2)', textContent: `${skipped} 件` }),
        ]) : null,
        el('div', { className: 'g-row between' }, [
          el('span', { textContent: '当てられた列' }),
          el('span', { style: 'color:var(--text-2)', textContent: found.join('、') }),
        ]),
      ]),
    );

    if (parsed.mapping.password === undefined) {
      body.append(el('div', { className: 'banner', style: 'margin-bottom:14px' }, [
        icon('warning'),
        el('div', {}, [
          el('div', { className: 'bt', textContent: 'パスワードの列が見つかりません' }),
          el('div', { className: 'bd', textContent: 'このまま取り込むと、パスワードは空のまま入ります。' }),
        ]),
      ]));
    }

    if (fresh.length) {
      body.append(
        el('div', { className: 'g-title', textContent: `入るもの（${fresh.length}）` }),
        el('div', { className: 'group' }, fresh.slice(0, 12).map(record =>
          el('div', { className: 'g-row' }, [
            icon('key', 14),
            el('span', { style: 'margin-left:7px', textContent: record.title }),
            record.username
              ? el('span', { style: 'margin-left:8px;color:var(--text-3);font-size:12px',
                             textContent: record.username })
              : null,
          ]))),
      );
      if (fresh.length > 12) {
        body.append(el('div', { className: 'g-foot', textContent: `ほか ${fresh.length - 12} 件` }));
      }
      body.append(el('div', { className: 'g-foot', textContent:
        'すべて「ログイン」として入ります。取り込んだ後で種別を変えられます。'
        + ' 元の CSV はパスワードが平文なので、取り込んだら消してください。' }));
    } else {
      body.append(el('div', { className: 'g-foot', textContent:
        'すべて既にある項目でした。取り込むものはありません。' }));
    }

    dialog.showModal();
  });
}

/// 緊急用のシート。忘れたとき・自分がいなくなったときのための紙。
///
/// このアプリは復旧の窓口を持たない。マスターパスワードを失えば中身は永久に出ない。
/// せめて「これが何で、どこにあって、どう開けるのか」だけは紙に残せるようにする。
function openEmergencyKit() {
  const dialog = makeDialog('緊急用シート', null);
  const body = dialog.querySelector('.dlg-body');
  const where = state.fileHandle ? state.fileName : 'この端末のブラウザの中（ファイルではありません）';
  const opened = window.location.href.split('?')[0];

  body.append(el('div', { className: 'kit' }, [
    el('h2', { textContent: 'PassVault 緊急用シート' }),
    el('p', { textContent:
      'この紙は、パスワードの保管庫を開くための手引きです。'
      + '保管庫そのものは暗号化されていて、下に書く「マスターパスワード」なしには誰にも開けません。' }),

    el('h3', { textContent: '1. 保管庫の場所' }),
    el('div', { className: 'kit-line', textContent: where }),

    el('h3', { textContent: '2. 開き方' }),
    el('div', { className: 'kit-line', textContent: opened }),
    el('p', { textContent:
      'この住所をブラウザで開き、上の保管庫ファイルを選んで、下のマスターパスワードを入れます。'
      + '保管庫ファイル（.pvlt）は、ダブルクリックしても開きません。' }),

    el('h3', { textContent: '3. マスターパスワード' }),
    el('p', { textContent: 'ここに手で書いてください。アプリは決して書き込みません。' }),
    el('div', { className: 'kit-blank' }),
    el('p', { className: 'kit-warn', textContent:
      'これを失うと、中身は永久に取り出せません。復旧の窓口はありません。'
      + 'この紙は、金庫や重要書類と同じ場所に保管してください。' }),

    el('h3', { textContent: '4. 技術的な内容（詳しい人向け）' }),
    el('div', { className: 'kit-line', textContent:
      `形式 PVLT / AES-256-GCM / PBKDF2-HMAC-SHA512 ${state.header.iterations.toLocaleString()} 回` }),
    el('p', { textContent:
      'ファイルの先頭 44 バイトが平文の見出しで、続きが暗号文です。'
      + '仕様は PassVault の README にあります。' }),

    el('div', { className: 'kit-foot', textContent: `作成: ${fmtDateTime(V.isoNoMillis())}` }),
  ]));

  body.append(el('div', { className: 'g-foot', textContent:
    '印刷したら、この画面は閉じてください。画面に出したままにしないこと。' }));

  const head = dialog.querySelector('.dlg-head');
  head.append(el('button', { textContent: '印刷', onclick: () => window.print() }));
  dialog.showModal();
}

async function importBytes(bytes, sourceLabel) {
  let remote;
  try {
    remote = await decryptForeignVault(bytes);
  } catch (caught) {
    toast(`取り込めませんでした: ${caught.message ?? caught}`);
    return false;
  }
  if (!remote) return false;  // パスワードの入力を取り消した

  if (!await confirmMerge(remote, sourceLabel)) {
    toast('取り込みを中止しました');
    return false;
  }

  const summary = await applyMerge(remote);
  if (!summary) return false;
  toast(`取り込みました。${A.summaryText(summary)}`);
  render();
  return true;
}

/// 別の端末の変更が降りてきたときに出す（app.js の pollRemoteChange から）。
///
/// 「あとで」を選んだ版を覚えておく。覚えないと 15 秒ごとに同じことを訊きにくる。
/// さらに新しい版が届けば、改めて訊く。
let ignoredRemoteAt = 0;
hooks.onRemoteChange = async function (when) {
  if (when.getTime() <= ignoredRemoteAt) return false;

  return new Promise(resolve => {
    let answered = false;
    const dialog = makeDialog('別の端末の変更が届いています', null);
    const finish = value => { answered = true; resolve(value); dialog.close(); };
    const later = () => { ignoredRemoteAt = when.getTime(); finish(false); };
    dialog.onDismiss = () => { if (!answered) { ignoredRemoteAt = when.getTime(); resolve(false); } };

    dialog.querySelector('.dlg-body').append(
      el('div', { className: 'banner', style: 'margin-bottom:14px' }, [
        icon('reuse'),
        el('div', {}, [
          el('div', { className: 'bd', textContent:
            `保管庫ファイルが ${fmtDateTime(when.toISOString())} に更新されています。`
            + (state.dirty
                ? 'こちらにも、まだ保存できていない変更があります。'
                : '別の端末での編集が考えられます。') }),
        ]),
      ]),
      el('div', { className: 'group' }, [
        el('button', { className: 'g-row',
          onclick: async () => {
            const bytes = await readVaultFileBytes();
            if (!bytes) { toast('ファイルを読めませんでした'); finish(false); return; }
            dialog.close();
            finish(await importBytes(bytes, `保存先のファイル（${state.fileName}）`));
          } }, [
          el('div', {}, [
            el('div', { style: 'color:var(--accent);font-weight:600', textContent: '取り込む（おすすめ）' }),
            el('div', { className: 'bd', textContent:
              '中身を見せてから、項目ごとに新しい方を残します。取り込む前に内容を確認できます。' }),
          ]),
        ]),
        el('button', { className: 'g-row', onclick: later }, [
          el('div', {}, [
            el('div', { style: 'font-weight:600', textContent: 'あとで' }),
            el('div', { className: 'bd', textContent:
              'この画面は古い内容のままになります。保存しようとしたときに改めて訊きます。' }),
          ]),
        ]),
      ]),
    );
    dialog.showModal();
  });
};

/// 保存しようとしたらファイルが外から変わっていた場合の 3 択
hooks.onConflict = function (message) {
  return new Promise(resolve => {
    let answered = false;
    const dialog = makeDialog('保管庫が外から変更されています', null);
    const finish = value => { answered = true; resolve(value); dialog.close(); };
    dialog.onDismiss = () => { if (!answered) resolve(false); };

    dialog.querySelector('.dlg-body').append(
      el('div', { className: 'banner', style: 'margin-bottom:14px' }, [
        icon('warning'),
        el('div', {}, [
          el('div', { className: 'bd', textContent: message }),
        ]),
      ]),
      el('div', { className: 'group' }, [
        el('button', { className: 'g-row',
          onclick: async () => {
            const bytes = await readVaultFileBytes();
            if (!bytes) { toast('ファイルを読めませんでした'); finish(false); return; }
            dialog.close();
            finish(await importBytes(bytes, `保存先のファイル（${state.fileName}）`));
          } }, [
          el('div', {}, [
            el('div', { style: 'color:var(--accent);font-weight:600', textContent: '取り込む（おすすめ）' }),
            el('div', { className: 'bd', textContent: 'そちらの変更と手元の変更を突き合わせ、項目ごとに新しい方を残します。' }),
          ]),
        ]),
        el('button', { className: 'g-row',
          onclick: async () => { const ok = await forceSave(); render(); finish(ok); } }, [
          el('div', {}, [
            el('div', { style: 'font-weight:600', textContent: '上書きする' }),
            el('div', { className: 'bd', textContent: 'そちらの変更は失われます。' }),
          ]),
        ]),
        el('button', { className: 'g-row',
          onclick: () => { toast('保存しませんでした。変更はまだファイルに書かれていません'); render(); finish(false); } }, [
          el('div', {}, [
            el('div', { style: 'font-weight:600', textContent: '何もしない' }),
            el('div', { className: 'bd', textContent: '手元の変更は保存されないまま残ります。' }),
          ]),
        ]),
      ]),
    );
    dialog.showModal();
  });
};

// ============================================================
// 訊ねるための小さなダイアログ
// ============================================================
//
// ブラウザ標準の prompt / confirm を使わない理由:
// 見た目が揃わないうえ、prompt は環境によっては封じられていて、
// そのとき「欄を追加する」機能そのものが使えなくなる。

/// はい / いいえ を訊く。閉じられた場合は「いいえ」。
hooks.askConfirm = function (title, message, { confirmLabel = 'OK', destructive = false } = {}) {
  return new Promise(resolve => {
    let answered = false;
    const dialog = makeDialog(title, () => { answered = true; resolve(true); return true; }, confirmLabel);
    dialog.onDismiss = () => { if (!answered) resolve(false); };
    if (destructive) dialog.querySelector('.dlg-head button:last-child')?.classList.add('danger');

    dialog.querySelector('.dlg-body').append(
      el('div', { className: 'group' }, [
        el('div', { className: 'g-row' }, [
          el('div', { style: 'line-height:1.65', textContent: message }),
        ]),
      ]),
    );
    dialog.showModal();
  });
};

/// 短い文字列を訊く。空のままなら確定させない。閉じられた場合は null。
hooks.askText = function (title, label, { placeholder = '', initial = '', confirmLabel = '追加' } = {}) {
  return new Promise(resolve => {
    const input = el('input', { className: 'field', value: initial, placeholder });
    let answered = false;
    const dialog = makeDialog(title, () => {
      const value = input.value.trim();
      if (!value) return false;   // 空では閉じない
      answered = true;
      resolve(value);
      return true;
    }, confirmLabel);
    dialog.onDismiss = () => { if (!answered) resolve(null); };

    dialog.querySelector('.dlg-body').append(
      el('div', { className: 'group' }, [
        el('div', { className: 'g-row' }, [
          el('span', { className: 'g-lab', textContent: label }),
          input,
        ]),
      ]),
    );
    input.onkeydown = event => {
      if (event.key === 'Enter') dialog.querySelector('.dlg-head button:last-child')?.click();
    };
    dialog.showModal();
    setTimeout(() => input.focus(), 0);
  });
};

// ============================================================
// ダイアログの枠
// ============================================================

function makeDialog(title, onConfirm, confirmLabel = '保存') {
  const dialog = el('dialog');
  const confirmButton = onConfirm
    ? el('button', { textContent: confirmLabel, onclick: async () => {
        if (await onConfirm() !== false) dialog.close();
      } })
    : el('span', { style: 'width:44px' });

  dialog.append(
    el('div', { className: 'dlg-head' }, [
      el('button', { textContent: onConfirm ? 'キャンセル' : '閉じる', onclick: () => dialog.close() }),
      el('h2', { textContent: title }),
      confirmButton,
    ]),
    el('div', { className: 'dlg-body' }),
  );

  // ダイアログを開いている間は画面を触らない時間が続くので、自動施錠を止める。
  state.holds += 1;

  // 後始末を close イベント任せにしない。
  // 環境によっては <dialog> の close/cancel が飛んでこないことがあり、
  // そうなると holds が減らないまま自動施錠が永久に止まる。
  // close() を包んで、確実に一度だけ後始末する。
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    state.holds = Math.max(0, state.holds - 1);
    noteActivity();
    dialog.remove();
    dialog.onDismiss?.();
  };
  const nativeClose = dialog.close.bind(dialog);
  dialog.close = (...args) => {
    try { nativeClose(...args); } finally { finish(); }
  };
  // Esc で閉じられた場合の保険（発火する環境ではこちらが働く）
  dialog.addEventListener('cancel', finish);
  dialog.addEventListener('close', finish);

  document.body.append(dialog);
  return dialog;
}

render();
