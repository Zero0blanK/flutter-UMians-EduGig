const [method, paramsJson = '{}'] = process.argv.slice(2);
if (!method) {
  throw new Error('Usage: node tools/control_chrome_page.mjs <CDP-method> [JSON-params]');
}

const params = JSON.parse(
  paramsJson.startsWith('base64:')
    ? Buffer.from(paramsJson.slice('base64:'.length), 'base64').toString('utf8')
    : paramsJson,
);
const targets = await (await fetch('http://127.0.0.1:9222/json/list')).json();
const page = targets.find(
  (target) => target.type === 'page' && target.url.startsWith('http://localhost:'),
);

if (!page) {
  throw new Error('No localhost page is open in the debuggable Chrome instance.');
}

const result = await new Promise((resolve, reject) => {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.onopen = () => socket.send(JSON.stringify({ id: 1, method, params }));
  socket.onmessage = (event) => {
    const message = JSON.parse(String(event.data));
    if (message.id === 1) {
      socket.close();
      if (message.error) {
        reject(new Error(message.error.message));
        return;
      }
      resolve(message.result);
    }
  };
  socket.onerror = () => reject(new Error('Unable to communicate with Chrome DevTools.'));
});

console.log(JSON.stringify(result, null, 2));
