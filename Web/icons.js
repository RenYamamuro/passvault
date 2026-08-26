// アイコン。SF Symbols に寄せた線画で、太さと角の丸めを揃えてある。
//
// 絵文字をやめた理由: 環境ごとに絵柄が変わり、フルカラーで主張が強く、
// 大きさも揃わない。単色の線画なら文字色に追従するので、
// 選択行の上でも暗い背景でも同じように読める。

const STROKED = {
  // 種別
  key: '<circle cx="8.5" cy="8.5" r="4"/><path d="M11.6 11.6 20 20M17 17l2-2M14.5 14.5l2.5-2.5"/>',
  note: '<rect x="5" y="3.5" width="14" height="17" rx="2.5"/><path d="M8.5 8h7M8.5 12h7M8.5 16h4"/>',
  card: '<rect x="2.5" y="5" width="19" height="14" rx="2.5"/><path d="M2.5 9.5h19M6 15h3"/>',
  identity: '<rect x="2.5" y="4.5" width="19" height="15" rx="2.5"/><circle cx="8.5" cy="10.5" r="2.2"/><path d="M5 16.2c.6-1.6 2-2.4 3.5-2.4s2.9.8 3.5 2.4M15 9.5h4M15 13h4"/>',
  terminal: '<rect x="2.5" y="4" width="19" height="16" rx="2.5"/><path d="M7 9.5 10 12l-3 2.5M12.5 15h5"/>',
  wifi: '<path d="M2.5 8.6a15 15 0 0 1 19 0M5.8 12.2a10 10 0 0 1 12.4 0M9.2 15.7a5 5 0 0 1 5.6 0"/><circle cx="12" cy="19" r="1.1" fill="currentColor" stroke="none"/>',
  seal: '<path d="M12 2.8 14.3 5l3-.4 1 2.9 2.6 1.6-1.1 2.9 1.1 2.9-2.6 1.6-1 2.9-3-.4L12 21.2 9.7 19l-3 .4-1-2.9L3.1 15l1.1-2.9L3.1 9.2l2.6-1.6 1-2.9 3 .4z"/><path d="m9 12 2.2 2.2L15.3 10"/>',

  // 画面の道具
  grid: '<rect x="3.5" y="3.5" width="7" height="7" rx="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="2"/><rect x="3.5" y="13.5" width="7" height="7" rx="2"/><rect x="13.5" y="13.5" width="7" height="7" rx="2"/>',
  star: '<path d="m12 3.6 2.6 5.3 5.9.9-4.3 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8L3.5 9.8l5.9-.9z"/>',
  shield: '<path d="M12 2.8 20 6v6c0 4.4-3.2 7.9-8 9.2-4.8-1.3-8-4.8-8-9.2V6z"/>',
  shieldCheck: '<path d="M12 2.8 20 6v6c0 4.4-3.2 7.9-8 9.2-4.8-1.3-8-4.8-8-9.2V6z"/><path d="m8.6 11.8 2.4 2.4 4.4-4.6"/>',
  tag: '<path d="M3.6 11.3V4.8a1.2 1.2 0 0 1 1.2-1.2h6.5c.3 0 .6.1.9.4l8 8a1.2 1.2 0 0 1 0 1.7l-6.5 6.5a1.2 1.2 0 0 1-1.7 0l-8-8c-.3-.3-.4-.6-.4-.9z"/><circle cx="7.8" cy="7.8" r="1.3"/>',
  trash: '<path d="M4.5 6.5h15M9.5 6.5V4.8a1.3 1.3 0 0 1 1.3-1.3h2.4a1.3 1.3 0 0 1 1.3 1.3v1.7M6.3 6.5l.8 12a1.8 1.8 0 0 0 1.8 1.7h6.2a1.8 1.8 0 0 0 1.8-1.7l.8-12M10.5 10.5v6M13.5 10.5v6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  search: '<circle cx="10.7" cy="10.7" r="6.7"/><path d="m15.6 15.6 4.4 4.4"/>',
  gear: '<circle cx="12" cy="12" r="3.2"/><path d="M19.4 14.5a1.4 1.4 0 0 0 .3 1.6l.1.1a1.7 1.7 0 1 1-2.4 2.4l-.1-.1a1.4 1.4 0 0 0-1.6-.3 1.4 1.4 0 0 0-.9 1.3v.2a1.7 1.7 0 1 1-3.4 0v-.1a1.4 1.4 0 0 0-.9-1.3 1.4 1.4 0 0 0-1.6.3l-.1.1a1.7 1.7 0 1 1-2.4-2.4l.1-.1a1.4 1.4 0 0 0 .3-1.6 1.4 1.4 0 0 0-1.3-.9h-.2a1.7 1.7 0 1 1 0-3.4h.1a1.4 1.4 0 0 0 1.3-.9 1.4 1.4 0 0 0-.3-1.6l-.1-.1a1.7 1.7 0 1 1 2.4-2.4l.1.1a1.4 1.4 0 0 0 1.6.3h.1a1.4 1.4 0 0 0 .9-1.3v-.2a1.7 1.7 0 1 1 3.4 0v.1a1.4 1.4 0 0 0 .9 1.3 1.4 1.4 0 0 0 1.6-.3l.1-.1a1.7 1.7 0 1 1 2.4 2.4l-.1.1a1.4 1.4 0 0 0-.3 1.6v.1a1.4 1.4 0 0 0 1.3.9h.2a1.7 1.7 0 1 1 0 3.4h-.1a1.4 1.4 0 0 0-1.3.9z"/>',
  lock: '<rect x="4.5" y="10.5" width="15" height="10" rx="2.5"/><path d="M8 10.5V7.6a4 4 0 0 1 8 0v2.9"/>',
  copy: '<rect x="8.5" y="8.5" width="12" height="12" rx="2.5"/><path d="M15.5 5.5v-.7a1.3 1.3 0 0 0-1.3-1.3H4.8a1.3 1.3 0 0 0-1.3 1.3v9.4a1.3 1.3 0 0 0 1.3 1.3h.7"/>',
  eye: '<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="3"/>',
  eyeOff: '<path d="M9.9 5.8A9.6 9.6 0 0 1 12 5.5c6 0 9.5 6.5 9.5 6.5a17 17 0 0 1-2.7 3.6M6.4 7.5A17 17 0 0 0 2.5 12S6 18.5 12 18.5c1.2 0 2.3-.3 3.3-.7M3 3l18 18M10 10a3 3 0 0 0 4 4"/>',
  wand: '<path d="M10.4 3.2 12.3 8.1 17.2 10 12.3 11.9 10.4 16.8 8.5 11.9 3.6 10l4.9-1.9z"/><path d="M17.6 14.3l.9 2.2 2.2.9-2.2.9-.9 2.2-.9-2.2-2.2-.9 2.2-.9z"/>',
  clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7.2V12l3.2 2"/>',
  warning: '<path d="M12 4.2 21 19.5H3z"/><path d="M12 10v4M12 16.8v.1"/>',
  reuse: '<path d="M4.6 12a7.4 7.4 0 0 1 12.6-5.2l2.3 2.3M19.5 4.6v4.5H15"/><path d="M19.4 12a7.4 7.4 0 0 1-12.6 5.2l-2.3-2.3M4.5 19.4v-4.5H9"/>',
  unlocked: '<rect x="4.5" y="10.5" width="15" height="10" rx="2.5"/><path d="M8 10.5V7.6a4 4 0 0 1 7.5-1.9"/>',
  back: '<path d="M15 5.5 8.5 12l6.5 6.5"/>',
  broom: '<path d="M14.5 3.5 9 9M7.5 10.5 5 13c-1.5 1.5-1.5 4 0 5.5s4 1.5 5.5 0l2.5-2.5M6.5 9.5l4 4M12 20.5h8M14.5 17.5l4-4"/>',
  inbox: '<path d="M3.5 13.5h4l1.3 2.5h6.4l1.3-2.5h4"/><path d="M5.6 5.2h12.8l3.1 8.3v3.8a2 2 0 0 1-2 2H4.5a2 2 0 0 1-2-2v-3.8z"/>',
  download: '<path d="M12 3.5v11M7.5 10 12 14.5 16.5 10M4 17.5v1.4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1.4"/>',
  upload: '<path d="M12 14.5v-11M7.5 8 12 3.5 16.5 8M4 17.5v1.4a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-1.4"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 6.5"/>',
  circle: '<circle cx="12" cy="12" r="7.5"/>',
  close: '<path d="M6 6l12 12M18 6 6 18"/>',
};

// 塗りで描くもの（線画だと意味が伝わりにくいもの）
const FILLED = {
  starFill: '<path d="m12 3.6 2.6 5.3 5.9.9-4.3 4.1 1 5.8-5.2-2.7-5.2 2.7 1-5.8L3.5 9.8l5.9-.9z"/>',
};

export function icon(name, size = 17) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('width', String(size));
  svg.setAttribute('height', String(size));
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('icon');

  if (FILLED[name]) {
    svg.setAttribute('fill', 'currentColor');
    svg.setAttribute('stroke', 'none');
    svg.innerHTML = FILLED[name];
  } else {
    svg.setAttribute('fill', 'none');
    svg.setAttribute('stroke', 'currentColor');
    svg.setAttribute('stroke-width', '1.7');
    svg.setAttribute('stroke-linecap', 'round');
    svg.setAttribute('stroke-linejoin', 'round');
    svg.innerHTML = STROKED[name] ?? STROKED.note;
  }
  return svg;
}

/// 種別ごとのアイコンと色。色は一覧を目で追うための手がかりで、
/// macOS のフォルダタグのように控えめな彩度にしてある。
export const CATEGORY_LOOK = {
  login: { icon: 'key', hue: 211 },
  secureNote: { icon: 'note', hue: 45 },
  creditCard: { icon: 'card', hue: 145 },
  identity: { icon: 'identity', hue: 280 },
  apiCredential: { icon: 'terminal', hue: 15 },
  wifi: { icon: 'wifi', hue: 190 },
  license: { icon: 'seal', hue: 330 },
};

export const FINDING_ICONS = {
  reused: 'reuse',
  weak: 'warning',
  old: 'clock',
  insecureURL: 'unlocked',
};
