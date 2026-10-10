/**
 * tx Meet Bridge — Service Worker
 *
 * Responsável por detectar quando o usuário SAI de uma reunião Meet,
 * tanto por navegar para outra página quanto por fechar a aba.
 *
 * O content.js não consegue detectar a saída confiável porque é descarregado
 * junto com a página. O background.js vive além da navegação e tem acesso
 * à API chrome.tabs.onUpdated com a URL nova.
 */

const TX_BRIDGE_URL = 'http://127.0.0.1:49200/';

// Padrão de URL de sala Meet ativa: meet.google.com/abc-defg-hij
const MEET_ROOM_RE = /meet\.google\.com\/([a-z0-9]+-[a-z0-9]+-[a-z0-9]+)/;

// Map tabId -> meetId para rastrear quais abas estão em reuniões
// Usamos chrome.storage.session para sobreviver ao service worker ser suspenso
async function getActiveMeetTabs() {
  const result = await chrome.storage.session.get('activeMeetTabs');
  return result.activeMeetTabs || {};
}

async function setActiveMeetTabs(tabs) {
  await chrome.storage.session.set({ activeMeetTabs: tabs });
}

async function sendMeetEnded(meetId) {
  try {
    await fetch(TX_BRIDGE_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        meetId,
        meetStatus: 'ended',
        participants: []
      })
    });
    console.log('[tx] meetEnded enviado para meetId:', meetId);
  } catch (err) {
    console.debug('[tx] bridge indisponível ao enviar meetEnded:', err.message);
  }
}

// Detecta entrada e saída de reuniões ao navegar
chrome.tabs.onUpdated.addListener(async (tabId, changeInfo, tab) => {
  if (!changeInfo.url) return;

  const activeTabs = await getActiveMeetTabs();
  const previousMeetId = activeTabs[tabId];
  const newMeetMatch = changeInfo.url.match(MEET_ROOM_RE);

  if (newMeetMatch) {
    // Entrou em uma sala Meet — registra
    activeTabs[tabId] = newMeetMatch[1];
    await setActiveMeetTabs(activeTabs);
    console.log('[tx] entrou em reunião:', newMeetMatch[1], 'tab:', tabId);
  } else if (previousMeetId) {
    // Estava em Meet e navegou para outra URL — saiu da reunião
    delete activeTabs[tabId];
    await setActiveMeetTabs(activeTabs);
    console.log('[tx] saiu da reunião:', previousMeetId, 'nova URL:', changeInfo.url);
    await sendMeetEnded(previousMeetId);
  }
});

// Detecta fechamento de aba enquanto em reunião
chrome.tabs.onRemoved.addListener(async (tabId) => {
  const activeTabs = await getActiveMeetTabs();
  const meetId = activeTabs[tabId];
  if (meetId) {
    delete activeTabs[tabId];
    await setActiveMeetTabs(activeTabs);
    console.log('[tx] aba fechada durante reunião:', meetId);
    await sendMeetEnded(meetId);
  }
});

// Recebe mensagens de status do content script
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'TX_STATUS') {
    chrome.storage.local.set({
      lastStatus: message.status,
      lastUpdate: Date.now()
    });
    sendResponse({ ok: true });
  }
  return false;
});

chrome.runtime.onInstalled.addListener(() => {
  console.log('[tx Meet Bridge] instalado');
});
