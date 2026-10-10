/**
 * tx Meet Bridge — Popup
 * Exibe o estado atual da reunião e participantes.
 */

async function refreshUI() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const isMeet = tab?.url?.startsWith('https://meet.google.com/');

  const statusDot = document.getElementById('statusDot');
  const statusText = document.getElementById('statusText');
  const meetSection = document.getElementById('meetSection');
  const meetTitle = document.getElementById('meetTitle');
  const participantsList = document.getElementById('participantsList');
  const countEl = document.getElementById('count');

  if (!isMeet) {
    statusText.textContent = 'Abra uma reunião Google Meet';
    return;
  }

  // Injeta o content script e solicita estado
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => {
        // Reutiliza funções do content script se já carregado
        const getMeetId = () => {
          const m = location.pathname.match(/^\/([a-z]{3}-[a-z]{4}-[a-z]{3})$/);
          return m ? m[1] : null;
        };
        const getMeetTitle = () =>
          document.title.replace(' - Google Meet', '').trim() || null;
        const getParticipants = () => {
          const found = new Set();
          const selectors = [
            '[data-participant-id] .zWGUib',
            '.KF4T6b span[dir="auto"]',
          ];
          for (const sel of selectors) {
            document.querySelectorAll(sel).forEach(el => {
              const n = el.textContent?.trim();
              if (n && n.length > 1) found.add(n);
            });
            if (found.size > 0) break;
          }
          if (found.size === 0) {
            document.querySelectorAll('[data-participant-id]').forEach(el => {
              const label = el.getAttribute('aria-label');
              if (label && label.length > 1 && label.length < 100) found.add(label);
            });
          }
          return Array.from(found).sort();
        };
        return {
          meetId: getMeetId(),
          title: getMeetTitle(),
          participants: getParticipants()
        };
      }
    });

    const data = result?.result;
    if (!data) return;

    statusDot.classList.add('active');
    statusText.textContent = data.meetId ? `Meet: ${data.meetId}` : 'Reunião ativa';

    if (data.title) {
      meetSection.style.display = 'block';
      meetTitle.textContent = data.title;
    }

    const participants = data.participants || [];
    countEl.textContent = participants.length;

    if (participants.length === 0) {
      participantsList.innerHTML = '<li style="color:#5a6880">Painel de participantes fechado</li>';
    } else {
      participantsList.innerHTML = participants
        .map(p => `<li><span class="dot"></span>${escapeHtml(p)}</li>`)
        .join('');
    }
  } catch (err) {
    statusText.textContent = 'Erro ao ler a aba';
    console.error(err);
  }
}

function escapeHtml(str) {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

document.addEventListener('DOMContentLoaded', refreshUI);
