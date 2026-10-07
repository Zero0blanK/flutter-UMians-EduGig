const expression = process.argv[2];
if (!expression) {
  throw new Error('Usage: node tools/evaluate_chrome_page.mjs <JavaScript-expression>');
}

const targets = await (await fetch('http://127.0.0.1:9222/json/list')).json();
const page = targets.find(
  (target) => target.type === 'page' && target.url.startsWith('http://localhost:'),
);

if (!page) {
  throw new Error('No localhost page is open in the debuggable Chrome instance.');
}

const result = await new Promise((resolve, reject) => {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.onopen = () => {
    socket.send(
      JSON.stringify({
        id: 1,
        method: 'Runtime.evaluate',
        params: { expression, returnByValue: true, awaitPromise: true },
      }),
    );
  };
  socket.onmessage = (event) => {
    const message = JSON.parse(String(event.data));
    if (message.id === 1) {
      socket.close();
      if (message.error || message.result.exceptionDetails) {
        reject(
          new Error(
            message.error?.message ??
              message.result.exceptionDetails.exception?.description ??
              message.result.exceptionDetails.text,
          ),
        );
        return;
      }
      resolve(message.result.result.value);
    }
  };
  socket.onerror = () => reject(new Error('Unable to communicate with Chrome DevTools.'));
});

console.log(JSON.stringify(result, null, 2));
