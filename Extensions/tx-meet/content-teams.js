/**
 * tx Teams Bridge — Content Script
 *
 * Observa o DOM do Microsoft Teams (web) para detectar mute/unmute do microfone
 * e enviar ao app tx via POST http://127.0.0.1:49200/
 */

const TX_BRIDGE_URL = 'http://127.0.0.1:49200/';
const TX_VERSION = '1.2.0';

console.log('[tx-teams] content script carregado v' + TX_VERSION + ' em', location.href);

let lastMicMuted = null;

/**
 * Coleta TODOS os documentos acessíveis (top + iframes same-origin).
 * Teams v2 às vezes empurra a UI da call para iframes.
 */
function getAllDocuments() {
  const docs = [document];
  for (const iframe of document.querySelectorAll('iframe')) {
    try {
      if (iframe.contentDocument) docs.push(iframe.contentDocument);
    } catch (_) { /* cross-origin: ignora */ }
  }
  return docs;
}

/**
 * Detecta se o microfone está mutado no Teams (v1 e v2).
 * Cobre rótulos em inglês e português (Mute/Unmute, Ativar som/Desativar som).
 * Retorna null se não conseguir detectar.
 */
function getMicMuted() {
  const selectors = [
    'button[data-tid="toggle-mute"]',
    'button[data-tid="microphone-button"]',
    'button[data-tid="call-microphone-button"]',
    'button[aria-label*="Mute" i]',
    'button[aria-label*="Unmute" i]',
    'button[aria-label*="microphone" i]',
    'button[aria-label*="microfone" i]',
    'button[aria-label*="ativar som" i]',
    'button[aria-label*="desativar som" i]',
    'button[aria-label*="silenciar" i]',
    'button[title*="Mute" i]',
    'button[title*="Unmute" i]',
    'button[title*="microfone" i]',
    'button[title*="ativar som" i]',
    'button[title*="desativar som" i]',
  ];

  for (const doc of getAllDocuments()) {
    for (const sel of selectors) {
      let btns;
      try { btns = doc.querySelectorAll(sel); } catch (_) { continue; }
      for (const btn of btns) {
        const label = (btn.getAttribute('aria-label') || btn.getAttribute('title') || '').toLowerCase();
        if (!label) continue;

        // PT-BR: "Ativar som" = atualmente mutado; "Desativar som" = atualmente ativo
        if (label.includes('ativar som') && !label.includes('desativar')) return true;
        if (label.includes('desativar som')) return false;
        if (label.includes('silenciar') && !label.includes('reativar')) return false;
        if (label.includes('reativar')) return true;

        // EN: "Unmute" = atualmente mutado (ação é desmutar)
        if (label.includes('unmute')) return true;
        if (label.includes('mute')) return false;

        // Fallback: aria-pressed
        const pressed = btn.getAttribute('aria-pressed');
        if (pressed === 'true') return false;
        if (pressed === 'false') return true;
      }
    }
  }
  return null;
}

function getMeetTitle() {
  return document.title.replace(/\s*\|\s*Microsoft Teams\s*$/i, '').trim() || null;
}

/**
 * Extrai participantes da call Teams via texto dos tiles do grid.
 * Teams v2 obfusca seletores, mas labels visíveis (CAIXA ALTA padrão Teams +
 * Title Case) ficam em text nodes. Filtra strings que parecem nome humano:
 * 2-4 palavras, cada palavra começando por letra maiúscula.
 */
function getParticipants() {
  const found = new Set();
  // Captura nodes folha (sem children) com texto que se parece com nome.
  const nodes = document.querySelectorAll('div, span');
  for (const el of nodes) {
    if (el.children.length > 0) continue;
    const text = el.textContent?.trim();
    if (!text || text.length < 4 || text.length > 80) continue;
    // Aceita 2 ou mais palavras separadas por espaço, cada uma com inicial
    // maiúscula. Cobre "WILHER LIMA TEIXEIRA" e "Guilherme Augusto Costa Correa".
    if (/^[A-ZÀ-Ü][A-Za-zÀ-ÿ]+(\s+[A-ZÀ-Ü][A-Za-zÀ-ÿ.'-]+){1,5}$/.test(text)) {
      found.add(text);
    }
  }
  // Remove falsos positivos comuns (nomes de menus/botões Teams).
  const blocklist = new Set([
    'Microsoft Teams', 'Teams Premium', 'Solid Path', 'War Room',
    'Plain Text', 'Last Read', 'Activity Feed', 'New Chat',
    'See All', 'See More', 'Show More'
  ]);
  return Array.from(found).filter(n => !blocklist.has(n)).sort();
}

async function sendMicMuteEvent(muted) {
  try {
    await fetch(TX_BRIDGE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ micMuted: muted })
    });
    console.log('[tx-teams] mic muted:', muted);
  } catch (err) {
    console.debug('[tx-teams] bridge indisponível:', err.message);
  }
}

async function sendUpdate() {
  const muted = getMicMuted();
  try {
    await fetch(TX_BRIDGE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        title: getMeetTitle(),
        micMuted: muted,
        participants: getParticipants()
      })
    });
  } catch (_) { /* ignore */ }
}

// Observa mudanças gerais para disparar snapshot de mute
const muteObserver = new MutationObserver(() => {
  const muted = getMicMuted();
  if (muted !== null && muted !== lastMicMuted) {
    lastMicMuted = muted;
    sendMicMuteEvent(muted);
  }
});

muteObserver.observe(document.body, {
  subtree: true,
  attributes: true,
  childList: true,
  attributeFilter: ['aria-label', 'aria-pressed', 'title', 'data-tid']
});

// Polling agressivo até detectar o botão de mic e capturar o estado inicial.
// Sem isso, se o user entra na call já mutado, o MutationObserver nunca dispara
// (atributo já presente no load) e o app captura áudio indevidamente.
function captureInitialMicState() {
  let attempts = 0;
  const maxAttempts = 60; // 60 × 500ms = 30s
  const interval = setInterval(() => {
    attempts++;
    const muted = getMicMuted();
    if (muted !== null) {
      clearInterval(interval);
      lastMicMuted = muted;
      sendMicMuteEvent(muted);
      sendUpdate();
      console.log('[tx-teams] estado inicial capturado: muted=', muted, 'attempts=', attempts);
    } else if (attempts >= maxAttempts) {
      clearInterval(interval);
      // Dump labels de TODOS os buttons visíveis pra eu identificar qual seletor usar.
      const labels = Array.from(document.querySelectorAll('button'))
        .map(b => b.getAttribute('aria-label') || b.getAttribute('title') || b.getAttribute('data-tid'))
        .filter(Boolean);
      const micRelated = labels.filter(l => /mic|mute|som|silenc|reativ/i.test(l));
      console.warn('[tx-teams] timeout aguardando botão de mic. Buttons mic-related:', micRelated);
      console.warn('[tx-teams] todos labels (primeiros 40):', labels.slice(0, 40));
    }
  }, 500);
}
captureInitialMicState();

// Refresh periódico como fallback (DOM do Teams muda frequentemente)
setInterval(sendUpdate, 5000);

console.log('[tx Teams Bridge] ativo em', location.href);
