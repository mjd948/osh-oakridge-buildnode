'use strict';

/**
 * Tests the desktop client's same-origin proxy against a mock node.
 *
 * Runs in plain Node - the proxy is deliberately free of Electron dependencies so it
 * can be exercised without launching a GUI. Uses a mock upstream rather than the real
 * node so it needs no credentials and cannot disturb a running system.
 */

const http = require('http');
const https = require('https');
const net = require('net');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const { createServer, tlsPolicyFromEnv } = require('../../electron/proxy');

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

/**
 * Opens a WebSocket handshake against the proxy and returns whatever comes back.
 *
 * Always plaintext to the proxy - the client half of the journey is loopback http even
 * when the node is behind https, which is the whole point of the arrangement.
 *
 * Resolves early once `until` appears, so a handshake the node accepts (and therefore a
 * socket nobody closes) does not cost the full timeout.
 */
function upgradeProbe(port, urlPath, { until = null, timeout = 3000 } = {}) {
    return new Promise((resolve) => {
        let data = '';
        let timer = null;
        const finish = () => {
            if (timer) clearTimeout(timer);
            socket.destroy();
            resolve(data);
        };
        const socket = net.connect(port, '127.0.0.1', () => {
            socket.write(
                `GET ${urlPath} HTTP/1.1\r\n` +
                'Host: localhost\r\n' +
                'Upgrade: websocket\r\n' +
                'Connection: Upgrade\r\n' +
                'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n' +
                'Sec-WebSocket-Version: 13\r\n\r\n');
        });
        socket.on('data', (c) => {
            data += c;
            if (until && data.includes(until)) finish();
        });
        socket.on('close', () => resolve(data));
        socket.on('error', () => resolve(data));
        timer = setTimeout(finish, timeout);
    });
}

/**
 * A throwaway self-signed certificate, so the TLS path is exercised against a real
 * handshake rather than a stub. Generated per run rather than committed: a private key in
 * the tree is a private key someone eventually reuses, and a committed certificate expires
 * on a date nobody is watching.
 *
 * The SAN is the address literal the mock listens on, so hostname verification has
 * something real to check and no name resolution enters the test.
 */
function makeSelfSignedCert(dir, name) {
    const keyFile = path.join(dir, `${name}-key.pem`);
    const certFile = path.join(dir, `${name}-cert.pem`);
    execFileSync('openssl', [
        'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', keyFile, '-out', certFile,
        '-days', '2', '-subj', '/CN=oscar-test-node',
        '-addext', 'subjectAltName=IP:127.0.0.1',
    ], { stdio: 'pipe' });
    return {
        keyFile,
        certFile,
        key: fs.readFileSync(keyFile),
        cert: fs.readFileSync(certFile),
    };
}

function post(port, urlPath, body) {
    return new Promise((resolve, reject) => {
        const payload = JSON.stringify(body);
        const req = http.request({
            host: '127.0.0.1', port, path: urlPath, method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
        }, (res) => {
            let out = '';
            res.on('data', (c) => (out += c));
            res.on('end', () => resolve({ status: res.statusCode, body: out }));
        });
        req.on('error', reject);
        req.end(payload);
    });
}

async function main() {
    // --- static content the client will serve -------------------------------
    const staticRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'oscar-web-'));
    fs.writeFileSync(path.join(staticRoot, 'index.html'), '<html><head></head>viewer</html>');
    // Stale endpoint on disk: the served config must come from the live upstream instead.
    fs.writeFileSync(path.join(staticRoot, 'oscar-config.json'),
        '{"node":{"address":"node.example.invalid","port":1}}');
    fs.writeFileSync(path.join(staticRoot, '404.html'), 'not found');

    // --- mock node ----------------------------------------------------------
    const seen = [];
    const upstream = http.createServer((req, res) => {
        seen.push({ url: req.url, auth: req.headers.authorization || null, range: req.headers.range || null });
        if (req.headers.range) {
            res.writeHead(206, {
                'Content-Type': 'video/mp4',
                'Content-Range': 'bytes 0-1/2048',
                'Accept-Ranges': 'bytes',
            });
            res.end('ab');
            return;
        }
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, path: req.url }));
    });

    // Refuses every upgrade, so the "never splice a non-101" rule is exercised.
    const seenUpgrades = [];
    upstream.on('upgrade', (req, socket) => {
        seenUpgrades.push({ url: req.url, auth: req.headers.authorization || null });
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

    check('marks served HTML as the desktop client', index.body.includes('__OSCAR_DESKTOP__'),
        index.body.slice(0, 60));

    // The served config describes the real node, not this server: the address is identity
    // only - nodeTransport() in the viewer sends the traffic here regardless - and the
    // stale copy on disk must not win over the live upstream.
    const cfg = await get(proxyPort, '/oscar-config.json');
    let cfgNode = {};
    try { cfgNode = JSON.parse(cfg.body).node || {}; } catch (_) { /* reported below */ }
    check('serves oscar-config.json from the live upstream',
        cfg.status === 200 && Number(cfgNode.port) === upstreamPort && cfgNode.address !== 'node.example.invalid',
        `${cfgNode.address}:${cfgNode.port}`);
    check('runtime config carries credentials for the renderer',
        cfgNode.auth && cfgNode.auth.username === 'admin' && cfgNode.auth.password === 'secret',
        JSON.stringify(cfgNode.auth));
    // Both endpoints are how the renderer builds every url it asks for. Dropping one is
    // invisible here and fatal there, so they are named rather than assumed.
    check('runtime config names the node\'s endpoints',
        cfgNode.oshPathRoot === '/sensorhub' && cfgNode.csAPIEndpoint === '/api',
        JSON.stringify({ oshPathRoot: cfgNode.oshPathRoot, csAPIEndpoint: cfgNode.csAPIEndpoint }));

    // --- per-node routing ---------------------------------------------------
    const unregistered = await get(proxyPort, '/__oscar/u/node-42/sensorhub/api/systems');
    check('refuses an unregistered node id', unregistered.status === 502,
        `status ${unregistered.status}`);

    const reg = await post(proxyPort, '/__oscar/upstreams', [{
        id: 'node-42', address: '127.0.0.1', port: upstreamPort,
        auth: { username: 'nodeuser', password: 'nodepass' },
    }]);
    check('accepts an upstream registration', reg.status === 204, `status ${reg.status}`);

    const routed = await get(proxyPort, '/__oscar/u/node-42/sensorhub/api/datastreams');
    check('routes a registered node to its upstream', routed.status === 200,
        `status ${routed.status}`);
    check('strips the routing prefix before forwarding',
        seen.some((r) => r.url === '/sensorhub/api/datastreams'),
        seen.map((r) => r.url).join(', '));

    const perNode = seen.find((r) => r.url === '/sensorhub/api/datastreams');
    const perNodeExpected = 'Basic ' + Buffer.from('nodeuser:nodepass').toString('base64');
    check('injects that node\'s own credentials', perNode && perNode.auth === perNodeExpected,
        perNode ? String(perNode.auth) : 'no request seen');

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
    const wsResult = await upgradeProbe(proxyPort, '/sensorhub/mqtt');
    check('refused upgrade answered with a closed 502, not spliced',
        /^HTTP\/1\.1 502 /.test(wsResult) && /Connection: close/i.test(wsResult),
        JSON.stringify(wsResult.split('\r\n')[0] || '(nothing)'));

    // 6b. A bucket fetch the way a <video> element makes it: byte range, no credentials
    //     of its own. Partial-content semantics must survive the hop or seeking breaks.
    const clip = await get(proxyPort, '/__oscar/u/node-42/sensorhub/buckets/clip.mp4',
        { Range: 'bytes=0-1' });
    const clipSeen = seen.find((r) => r.url === '/sensorhub/buckets/clip.mp4');
    check('routes a bucket/video fetch to the node', !!clipSeen,
        seen.map((r) => r.url).join(', '));
    check('attaches credentials the media element could not',
        clipSeen && clipSeen.auth === 'Basic ' + Buffer.from('nodeuser:nodepass').toString('base64'),
        clipSeen ? String(clipSeen.auth) : 'no request seen');
    check('preserves range request and 206 response',
        clip.status === 206 && clip.headers['content-range'] === 'bytes 0-1/2048' && clipSeen.range === 'bytes=0-1',
        `status ${clip.status}, range ${clipSeen ? clipSeen.range : 'none'}`);

    // 7. The upgrade path the viewer actually uses: routed by node id, prefix stripped,
    //    and carrying that node's credentials - none of which a browser could do itself.
    const wsNode = await upgradeProbe(proxyPort, '/__oscar/u/node-42/sensorhub/ws');
    const wsSeen = seenUpgrades.find((u) => u.url === '/sensorhub/ws');
    check('routes a node-scoped upgrade with its prefix stripped', !!wsSeen,
        seenUpgrades.map((u) => u.url).join(', ') || '(no upgrade reached the node)');
    check('injects credentials on the node-scoped handshake',
        wsSeen && wsSeen.auth === 'Basic ' + Buffer.from('nodeuser:nodepass').toString('base64'),
        wsSeen ? String(wsSeen.auth) : 'no upgrade seen');
    check('node-scoped refusal is also answered with a closed 502',
        /^HTTP\/1\.1 502 /.test(wsNode), JSON.stringify(wsNode.split('\r\n')[0] || '(nothing)'));

    // 8. The exact url shape getMqttEndpoint() produces: node prefix, then the node's
    //    path root and nothing else. Reconstructing this by splitting the REST endpoint
    //    used to yield "/__oscar" - routable by nothing, and silent when it broke.
    const wsBare = await upgradeProbe(proxyPort, '/__oscar/u/node-42/sensorhub');
    const bareSeen = seenUpgrades.find((u) => u.url === '/sensorhub');
    check('routes the mqtt endpoint shape to the node path root', !!bareSeen,
        seenUpgrades.map((u) => u.url).join(', '));
    check('mqtt handshake carries that node\'s credentials',
        bareSeen && bareSeen.auth === 'Basic ' + Buffer.from('nodeuser:nodepass').toString('base64'),
        bareSeen ? String(bareSeen.auth) : 'no upgrade seen');

    // --- 9. A node behind https --------------------------------------------
    //
    // The client used to have no TLS path at all: REST went out as cleartext to the https
    // port and came back 400 from nginx, MQTT wrote a plaintext handshake into a TLS
    // socket and never saw a 101, and the Servers page went on showing the node as
    // "Secure" throughout. These run against a real TLS handshake, because a stub would
    // not have caught any of that.
    const certDir = fs.mkdtempSync(path.join(os.tmpdir(), 'oscar-tls-'));
    const nodeCert = makeSelfSignedCert(certDir, 'node');
    const otherCert = makeSelfSignedCert(certDir, 'other');

    const tlsSeen = [];
    const tlsUpgrades = [];
    const tlsUpstream = https.createServer({ key: nodeCert.key, cert: nodeCert.cert }, (req, res) => {
        tlsSeen.push({ url: req.url, auth: req.headers.authorization || null, host: req.headers.host });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ ok: true, overTls: true }));
    });
    // Accepts the upgrade, unlike the plaintext mock: the tunnel has to be proved to
    // splice through TLS, not merely to refuse cleanly.
    tlsUpstream.on('upgrade', (req, socket) => {
        tlsUpgrades.push({ url: req.url, auth: req.headers.authorization || null });
        socket.write('HTTP/1.1 101 Switching Protocols\r\n'
            + 'Upgrade: websocket\r\nConnection: Upgrade\r\n\r\nLIVE');
    });
    await new Promise((r) => tlsUpstream.listen(0, '127.0.0.1', r));
    const tlsPort = tlsUpstream.address().port;

    const started = [];
    const startTlsProxy = async (tlsPolicy, extra = []) => {
        const server = createServer({
            staticRoot,
            getUpstream: () => ({ host: '127.0.0.1', port: tlsPort, secure: true, auth: 'admin:secret' }),
            tlsPolicy,
        });
        await new Promise((r) => server.listen(0, '127.0.0.1', r));
        started.push(server);
        const port = server.address().port;
        await post(port, '/__oscar/upstreams', [{
            id: 'node-tls', address: '127.0.0.1', port: tlsPort, isSecure: true,
            auth: { username: 'nodeuser', password: 'nodepass' },
        }, ...extra]);
        return port;
    };

    // 9a. Nothing configured: a certificate that cannot be verified is refused, and the
    //     refusal explains itself. This is the one that must never quietly become "off".
    const strictPort = await startTlsProxy({ rejectUnauthorized: true, caFile: null });
    const strictRest = await get(strictPort, '/__oscar/u/node-tls/sensorhub/api/systems');
    check('refuses an unverifiable certificate by default', strictRest.status === 502,
        `status ${strictRest.status}`);
    check('says the certificate was the problem, and what would accept it',
        /certificate/i.test(strictRest.body) && /caFile/.test(strictRest.body),
        JSON.stringify(strictRest.body.slice(0, 120)));

    const strictWs = await upgradeProbe(strictPort, '/__oscar/u/node-tls/sensorhub');
    check('refuses the upgrade too, rather than dropping the socket silently',
        /^HTTP\/1\.1 502 /.test(strictWs) && /certificate/i.test(strictWs),
        JSON.stringify(strictWs.split('\r\n')[0] || '(nothing)'));

    // 9b. Trusting one certificate is not trusting any certificate.
    const wrongCaPort = await startTlsProxy({ rejectUnauthorized: true, caFile: otherCert.certFile });
    const wrongCaRest = await get(wrongCaPort, '/__oscar/u/node-tls/sensorhub/api/systems');
    check('a trusted certificate does not vouch for a different one',
        wrongCaRest.status === 502 && /certificate/i.test(wrongCaRest.body),
        `status ${wrongCaRest.status}`);

    // 9c. The supported way to accept a self-signed node certificate.
    const caPort = await startTlsProxy({ rejectUnauthorized: true, caFile: nodeCert.certFile }, [{
        // The same node, registered the way an older renderer would have: no isSecure at
        // all. It must stay cleartext - and therefore fail against a TLS port - or the
        // flag is not what selects the transport.
        id: 'node-unmarked', address: '127.0.0.1', port: tlsPort,
        auth: { username: 'nodeuser', password: 'nodepass' },
    }]);
    const caRest = await get(caPort, '/__oscar/u/node-tls/sensorhub/api/systems');
    check('reaches an https node once its certificate is trusted',
        caRest.status === 200 && caRest.body.includes('"overTls":true'), `status ${caRest.status}`);

    const tlsRest = tlsSeen.find((r) => r.url === '/sensorhub/api/systems');
    check('injects that node\'s credentials over TLS',
        tlsRest && tlsRest.auth === 'Basic ' + Buffer.from('nodeuser:nodepass').toString('base64'),
        tlsRest ? String(tlsRest.auth) : 'no request reached the tls node');
    check('presents the node\'s own Host, not this server\'s',
        tlsRest && tlsRest.host === `127.0.0.1:${tlsPort}`,
        tlsRest ? String(tlsRest.host) : 'no request reached the tls node');

    const tlsWs = await upgradeProbe(caPort, '/__oscar/u/node-tls/sensorhub', { until: 'LIVE' });
    check('tunnels the mqtt handshake through TLS and splices on 101',
        /^HTTP\/1\.1 101 /.test(tlsWs) && tlsWs.includes('LIVE'),
        JSON.stringify(tlsWs.split('\r\n')[0] || '(nothing)'));
    check('the TLS handshake carries the credentials a browser could not attach',
        tlsUpgrades.length === 1
            && tlsUpgrades[0].auth === 'Basic ' + Buffer.from('nodeuser:nodepass').toString('base64'),
        tlsUpgrades.length ? String(tlsUpgrades[0].auth) : 'no upgrade reached the tls node');

    const unmarked = await get(caPort, '/__oscar/u/node-unmarked/sensorhub/api/systems');
    check('a node registered without isSecure is still spoken to in the clear',
        unmarked.status === 502, `status ${unmarked.status}`);

    const tlsCfg = await get(caPort, '/oscar-config.json');
    check('the runtime config reports the node\'s scheme, not this server\'s',
        JSON.parse(tlsCfg.body).node.isSecure === true, tlsCfg.body);

    // 9d. The escape hatch, for a certificate that cannot be produced as a file.
    const insecurePort = await startTlsProxy({ rejectUnauthorized: false, caFile: null });
    const insecureRest = await get(insecurePort, '/__oscar/u/node-tls/sensorhub/api/datastreams');
    check('connects without verification when verification is explicitly off',
        insecureRest.status === 200, `status ${insecureRest.status}`);

    // 9e. The switches themselves. Only an explicit value relaxes anything: a policy that
    //     could be turned off by a typo is one that is off on some machine already.
    const envDefault = tlsPolicyFromEnv({});
    check('verification is on when the environment says nothing',
        envDefault.rejectUnauthorized === true && envDefault.caFile === null,
        JSON.stringify(envDefault));
    check('OSCAR_TLS_INSECURE=1 turns verification off',
        tlsPolicyFromEnv({ OSCAR_TLS_INSECURE: '1' }).rejectUnauthorized === false);
    check('an unrelated OSCAR_TLS_INSECURE value leaves it on',
        tlsPolicyFromEnv({ OSCAR_TLS_INSECURE: 'later' }).rejectUnauthorized === true);
    check('OSCAR_NODE_CA names the certificate to trust',
        tlsPolicyFromEnv({ OSCAR_NODE_CA: '/etc/oscar/node.pem' }).caFile === '/etc/oscar/node.pem');

    proxy.close();
    upstream.close();
    tlsUpstream.close();
    started.forEach((s) => s.close());
    fs.rmSync(staticRoot, { recursive: true, force: true });
    fs.rmSync(certDir, { recursive: true, force: true });

    console.log();
    if (failures === 0) {
        console.log('PASS: the client serves the viewer and the API from one origin, injects');
        console.log('      credentials the browser cannot attach itself, refuses to splice a');
        console.log('      rejected WebSocket handshake, reaches an https node over TLS, and');
        console.log('      will not accept a certificate it cannot verify unless told to.');
    } else {
        console.log(`FAIL: ${failures} check(s) failed.`);
        process.exit(1);
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
