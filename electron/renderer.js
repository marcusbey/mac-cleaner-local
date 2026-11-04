const button = document.getElementById('open');
const status = document.getElementById('status');
button.addEventListener('click', async () => {
  button.disabled = true;
  status.textContent = 'Opening native tools…';
  try {
    const result = await window.cleaner.open();
    status.textContent = result.ok ? 'App Cleaner opened. Its memory-chip icon is in your menu bar.' : result.message;
  } catch { status.textContent = 'Unable to open App Cleaner. Restart the desktop launcher and try again.'; }
  finally {button.disabled = false;}
});
