'use strict';

/**
 * Tests the desktop client's same-origin proxy against a mock node.
 *
 * Runs in plain Node - the proxy is deliberately free of Electron dependencies so it
 * can be exercised without launching a GUI. Uses a mock upstream rather than the real
 * node so it needs no credentials and cannot disturb a running system.
 */

const http = require('http');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const { createServer } = require('../../electron/proxy');

let failures = 0;
function check(label, condition, detail) {
    const status = condition ? 'ok  ' : 'FAIL';
    if (!condition) failures++;
    console.log(`  [${status}] ${label}${detail ? '  (' + detail + ')' : ''}`);
}

function get(port, urlPath, headers = {}) {
    return new Promise((resolve, reject) => {
        const req = http.request({ host: '127.0.0.1', port, path: urlPath, headers }, (res) => {
            let body = '';
            res.on('data', (c) => (body += c));
            res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body }));
        });
        req.on('error', reject);
        req.end();
    });
}

async function main() {
    // --- static content the client will serve -------------------------------
    const staticRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'oscar-web-'));
    fs.writeFileSync(path.join(staticRoot, 'index.html'), '<html>viewer</html>');
    fs.writeFileSync(path.join(staticRoot, 'oscar-config.json'), '{"node":{"address":"x","port":1}}');
    fs.writeFileSync(path.join(staticRoot, '404.html'), 'not found');

    // --- mock node ----------------------------------------------------------
    const seen = [];
    const upstream = http.createServer((req, res) => {
        seen.push({ url: req.url, auth: req.headers.authorization || null });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: req.url }));
    });

    // Refuses every upgrade, so the "never splice a non-101" rule is exercised.
    upstream.on('upgrade', (req, socket) => {
        socket.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    });

    await new Promise((r) => upstream.listen(0, '127.0.0.1', r));
    const upstreamPort = upstream.address().port;

    // --- proxy under test ---------------------------------------------------
    const proxy = createServer({
        staticRoot,
        getUpstream: () => ({ host: '127.0.0.1', port: upstreamPort, auth: 'admin:secret' }),
    });
    await new Promise((r) => proxy.listen(0, '127.0.0.1', r));
    const proxyPort = proxy.address().port;

    console.log('Desktop client proxy');

    // 1. Static content is served from the same origin as the API.
    const index = await get(proxyPort, '/');
    check('serves the viewer at /', index.status === 200 && index.body.includes('viewer'),
        `status ${index.status}`);

    const cfg = await get(proxyPort, '/oscar-config.json');
    check('serves oscar-config.json', cfg.status === 200 && cfg.body.includes('"address"'),
        `status ${cfg.status}`);

    // 2. API traffic reaches the node through the same origin.
    const api = await get(proxyPort, '/sensorhub/api/systems');
    check('proxies /sensorhub to the node', api.status === 200 && api.body.includes('"ok":true'),
        `status ${api.status}`);
    check('forwards the full path', seen.some((r) => r.url === '/sensorhub/api/systems'),
        seen.map((r) => r.url).join(', '));

    // 3. Credentials are injected server-side, so the renderer never sees a challenge.
    const injected = seen.find((r) => r.url === '/sensorhub/api/systems');
    const expected = 'Basic ' + Buffer.from('admin:secret').toString('base64');
    check('injects Basic auth upstream', injected && injected.auth === expected,
        injected ? String(injected.auth) : 'no request seen');

    // 4. An Authorization the page already set must win over the injected one.
    await get(proxyPort, '/sensorhub/api/other', { authorization: 'Bearer page-token' });
    const passthrough = seen.find((r) => r.url === '/sensorhub/api/other');
    check('does not overwrite an existing Authorization',
        passthrough && passthrough.auth === 'Bearer page-token',
        passthrough ? String(passthrough.auth) : 'no request seen');

    // 5. Static serving must not escape its root.
    const escape = await get(proxyPort, '/../../../../etc/passwd');
    check('blocks path traversal', escape.status === 403 || escape.status === 404,
        `status ${escape.status}`);

    // 6. The rule that cost a long-standing flake: a refused upgrade must never be
    //    spliced, or the client pools the socket and later requests bypass the proxy.
    const wsResult = await new Promise((resolve) => {
        const socket = net.connect(proxyPort, '127.0.0.1', () => {
            socket.write(
                'GET /sensorhub/mqtt HTTP/1.1\r\n' +
                'Host: localhost\r\n' +
                'Upgrade: websocket\r\n' +
                'Connection: Upgrade\r\n' +
                'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n' +
                'Sec-WebSocket-Version: 13\r\n\r\n');
        });
        let data = '';
        socket.on('data', (c) => (data += c));
        socket.on('close', () => resolve(data));
        socket.on('error', () => resolve(data));
        setTimeout(() => { socket.destroy(); resolve(data); }, 3000);
    });
    check('refused upgrade answered with a closed 502, not spliced',
        /^HTTP\/1\.1 502 /.test(wsResult) && /Connection: close/i.test(wsResult),
        JSON.stringify(wsResult.split('\r\n')[0] || '(nothing)'));

    proxy.close();
    upstream.close();
    fs.rmSync(staticRoot, { recursive: true, force: true });

    console.log();
    if (failures === 0) {
        console.log('PASS: the client serves the viewer and the API from one origin, injects');
        console.log('      credentials the browser cannot attach itself, and refuses to splice');
        console.log('      a rejected WebSocket handshake.');
    } else {
        console.log(`FAIL: ${failures} check(s) failed.`);
        process.exit(1);
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
