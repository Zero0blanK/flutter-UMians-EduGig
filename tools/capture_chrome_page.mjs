import { mkdir, writeFile } from 'node:fs/promises';
import { dirname } from 'node:path';

const outputPath = process.argv[2];
if (!outputPath) {
  throw new Error('Usage: node tools/capture_chrome_page.mjs <output.png>');
}

const targets = await (await fetch('http://127.0.0.1:9222/json/list')).json();
const page = targets.find(
  (target) => target.type === 'page' && target.url.startsWith('http://localhost:'),
);

if (!page) {
  throw new Error('No localhost page is open in the debuggable Chrome instance.');
}

const response = await new Promise((resolve, reject) => {
  const socket = new WebSocket(page.webSocketDebuggerUrl);
  socket.onopen = () => {
    socket.send(
      JSON.stringify({
        id: 1,
        method: 'Page.captureScreenshot',
        params: { format: 'png', captureBeyondViewport: false },
      }),
    );
  };
  socket.onmessage = (event) => {
    const message = JSON.parse(String(event.data));
    if (message.id === 1) {
      socket.close();
      resolve(message.result.data);
    }
  };
  socket.onerror = () => reject(new Error('Unable to communicate with Chrome DevTools.'));
});

await mkdir(dirname(outputPath), { recursive: true });
await writeFile(outputPath, Buffer.from(response, 'base64'));
console.log(`Captured ${page.url} to ${outputPath}`);
