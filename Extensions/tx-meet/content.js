/**
 * tx Meet Bridge — Content Script
 *
 * Observa o DOM do Google Meet para capturar:
 * - Lista de participantes
 * - Título da reunião
 * - ID da reunião (do URL)
 *
 * Envia para o app tx via POST http://127.0.0.1:49200/
 */

const TX_BRIDGE_URL = 'http://127.0.0.1:49200/';
const DEBOUNCE_MS = 2000;

let lastPayload = '';
let debounceTimer = null;
let lastMicMuted = null;

// Extrai o ID da reunião do URL (ex: meet.google.com/abc-defg-hij)
function getMeetId() {
  const match = location.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})$/);
  return match ? match[1] : null;
}

// Captura o título da aba/reunião
function getMeetTitle() {
  return document.title.replace(' - Google Meet', '').trim() || null;
}

/**
 * Captura participantes visíveis no painel lateral.
 * O Google Meet usa aria-label ou data-participant-id nos elementos.
 * Esta função tenta múltiplos seletores para robustez.
 */
/**
 * Fallback robusto: extrai nomes de qualquer node texto-folha que combine
 * com formato "Nome Sobrenome" (CAPS ou Title Case). Cobre Meet 2026 grid
 * view onde tiles renderizam labels via text nodes simples.
 */
function getParticipantsByText() {
  const found = new Set();
  const nodes = document.querySelectorAll('div, span');
  for (const el of nodes) {
    if (el.children.length > 0) continue;
    const text = el.textContent?.trim();
    if (!text || text.length < 4 || text.length > 80) continue;
    if (/^[A-ZÀ-Ü][A-Za-zÀ-ÿ]+(\s+[A-ZÀ-Ü][A-Za-zÀ-ÿ.'-]+){1,5}$/.test(text)) {
      found.add(text);
    }
  }
  const blocklist = new Set([
    'Google Meet', 'Meet', 'Join Now', 'Ask To Join',
    'Add People', 'Show Captions', 'Turn Off',
    'See All', 'See More'
  ]);
  return Array.from(found).filter(n => !blocklist.has(n));
}

function getParticipants() {
  const found = new Set();

  // Seletor principal: painel de participantes (aria-label com nome)
  const selectors = [
    '[data-participant-id] [data-self-name]',
    '[data-participant-id] .zWGUib',    // nome no painel
    '[jscontroller] [data-requested-participant-id] span[dir="auto"]',
    '.KF4T6b span[dir="auto"]',          // lista compacta
    '[data-participant-id]',             // fallback: aria-label do container
  ];

  for (const selector of selectors) {
    document.querySelectorAll(selector).forEach(el => {
      const name = el.textContent?.trim() ||
                   el.getAttribute('aria-label')?.trim() ||
                   el.getAttribute('data-self-name')?.trim();
      if (name && name.length > 1 && name.length < 100) {
        found.add(name);
      }
    });
    if (found.size > 0) break;
  }

  // Fallback: todos elementos com data-participant-id e aria-label
  if (found.size === 0) {
    document.querySelectorAll('[data-participant-id]').forEach(el => {
      const label = el.getAttribute('aria-label');
      if (label && label.length > 1 && label.length < 100) {
        found.add(label);
      }
    });
  }

  // Último fallback: regex em text nodes (cobre Meet 2026 grid quando seletores
  // específicos falham). Igual ao usado no Teams.
  if (found.size === 0) {
    for (const n of getParticipantsByText()) found.add(n);
  }

  return Array.from(found).sort();
}

/**
 * Detecta se o microfone local está mutado no Meet.
 * Lê apenas o controle do próprio microfone. Um seletor global de
 * data-is-muted pode encontrar o microfone de outro participante.
 * Retorna null se não conseguir identificar o controle local.
 */
function getMicMuted() {
  const controls = document.querySelectorAll('button[aria-label], [role="button"][aria-label]');
  for (const control of controls) {
    const label = (control.getAttribute('aria-label') || '').trim().toLowerCase();
    if (/^(ativar|ligar) (o )?microfone\b|^(turn on|unmute) (your )?microphone\b|^activar (el )?micrófono\b/.test(label)) {
      return true;
    }
    if (/^(desativar|desligar) (o )?microfone\b|^(turn off|mute) (your )?microphone\b|^desactivar (el )?micrófono\b/.test(label)) {
      return false;
    }
  }
  return null;
}

/**
 * Envia evento de mute isolado (sem debounce) para reação imediata no app.
 */
async function sendMicMuteEvent(muted) {
  const meetId = getMeetId();
  if (muted === null || !meetId) return;
  try {
    await fetch(TX_BRIDGE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ micMuted: muted, meetId })
    });
    console.log('[tx] mic muted:', muted);
  } catch (err) {
    console.debug('[tx] bridge indisponível (mic mute):', err.message);
  }
}

function buildPayload() {
  return {
    meetId: getMeetId(),
    title: getMeetTitle(),
    participants: getParticipants(),
    micMuted: getMicMuted()
  };
}

async function sendToTx(payload, force = false) {
  const serialized = JSON.stringify(payload);
  if (!force && serialized === lastPayload) return; // sem mudança

  try {
    const resp = await fetch(TX_BRIDGE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: serialized
    });
    if (!resp.ok) {
      console.warn('[tx] bridge respondeu', resp.status);
    } else {
      lastPayload = serialized;
      console.log('[tx] enviado:', payload.participants.length, 'participantes');
    }
  } catch (err) {
    // App pode não estar rodando — silencia
    console.debug('[tx] bridge indisponível:', err.message);
  }
}

function scheduleUpdate() {
  clearTimeout(debounceTimer);
  debounceTimer = setTimeout(() => {
    const payload = buildPayload();
    sendToTx(payload);
  }, DEBOUNCE_MS);
}

// Polling agressivo até detectar o botão de mic e capturar o estado inicial.
// Sem isso, se o user entra na call já mutado, o MutationObserver nunca dispara
// (atributo já presente no load) e o app captura áudio indevidamente até que
// o user faça toggle manual do mic.
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
      sendToTx(buildPayload());
      console.log('[tx] estado inicial capturado: muted=', muted, 'attempts=', attempts);
    } else if (attempts >= maxAttempts) {
      clearInterval(interval);
      console.warn('[tx] timeout aguardando botão de mic');
    }
  }, 500);
}
captureInitialMicState();

// Observa mudanças no DOM para detectar entrada/saída de participantes
const observer = new MutationObserver(scheduleUpdate);
observer.observe(document.body, {
  childList: true,
  subtree: true,
  attributes: true,
  attributeFilter: ['data-participant-id', 'aria-label', 'data-self-name', 'data-is-muted', 'aria-pressed']
});

// Observa mudanças de mute separadamente para reação imediata (sem debounce)
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
  attributeFilter: ['data-is-muted', 'aria-pressed']
});

// Reenvia o mute mesmo sem mudança: o tx pode iniciar uma gravação depois
// do primeiro evento, ou voltar a abrir depois de uma falha de rede.
setInterval(() => sendMicMuteEvent(getMicMuted()), 5000);
setInterval(() => sendToTx(buildPayload(), true), 15000);

console.log('[tx Meet Bridge] ativo em', location.href);
