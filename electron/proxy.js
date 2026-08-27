'use strict';

/**
 * Same-origin server for the OSCAR desktop client.
 *
 * Serves the exported viewer AND forwards /sensorhub to the node, so the renderer sees
 * a single origin. That matters for three reasons:
 *
 *  - The viewer derives its default node from window.location. Serving the app from a
 *    local static server while the API lives elsewhere made that derivation produce a
 *    node pointing at the static server's own port, which serves no API. First launch
 *    therefore always landed on a broken default that the user had to correct by hand.
 *
 *  - Cross-origin API calls previously required disabling Chromium's web security for
 *    the whole window. Proxying removes the cross-origin situation instead of
 *    suppressing the browser's objection to it.
 *
 *  - Browsers cannot attach an Authorization header to a WebSocket handshake, so the
 *    renderer's first MQTT attempt reaches the node bare. Injecting credentials here
 *    is the only place it can be done.
 *
 * Lifted from web/oscar-viewer/serve-proxy.js, which was written for the Cypress
 * harness and carries two hard-won rules; both are preserved below.
 *
 * The renderer's leg of the journey is always plain http over loopback. The second leg,
 * this server to the node, is whatever the node speaks - see the TLS section below.
 */

const http = require('http');
const https = require('https');
const net = require('net');
const tls = require('tls');
const fs = require('fs');
const path = require('path');

const MIME = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.mjs': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.gif': 'image/gif',
    '.ico': 'image/x-icon',
    '.woff': 'font/woff',
    '.woff2': 'font/woff2',
    '.ttf': 'font/ttf',
    '.wasm': 'application/wasm',
    '.m3u8': 'application/vnd.apple.mpegurl',
    '.ts': 'video/mp2t',
    '.mp4': 'video/mp4',
};

function contentType(file) {
    return MIME[path.extname(file).toLowerCase()] || 'application/octet-stream';
}

/**
 * Tells the page it is running inside the desktop client.
 *
 * The renderer needs this before its first line of application code: the node list is
 * rehydrated from localStorage while the Redux slice module is still being imported, and
 * each node builds its endpoint URLs in its constructor. An async fetch could not answer
 * in time, so the answer is inlined into the document instead.
 */
function injectDesktopMarker(html) {
    const tag = '<script>window.__OSCAR_DESKTOP__=true;</script>';
    if (html.includes('__OSCAR_DESKTOP__')) return html;
    const head = html.match(/<head[^>]*>/i);
    if (head) return html.replace(head[0], head[0] + tag);
    return tag + html;
}

/* --- TLS to the node ------------------------------------------------------------
 *
 * A node behind nginx (or any other terminator) speaks https, and until this existed the
 * client could not reach one at all: every REST call went out as cleartext to the https
 * port and came back "400 Bad Request: The plain HTTP request was sent to an HTTPS port",
 * while MQTT wrote a plaintext handshake into a TLS socket and never saw a 101. The
 * Servers page offered a "Secure" checkbox the whole time; nothing acted on it.
 *
 * Which nodes are secure is decided by the renderer and arrives with the registration -
 * see registerUpstreams. How their certificates are judged is decided here.
 *
 * CERTIFICATE VERIFICATION IS ON BY DEFAULT AND IS NEVER RELAXED SILENTLY. Self-signed
 * node certificates are common in this deployment, so there are two ways to accept one,
 * in order of preference:
 *
 *   caFile              trust this certificate (or CA bundle) in ADDITION to the system
 *   OSCAR_NODE_CA       roots. The node is still authenticated: a different certificate,
 *                       or the right certificate on the wrong host, is still refused.
 *                       This is the setting to reach for.
 *
 *   rejectUnauthorized  accept whatever certificate is presented, unverified. The traffic
 *     : false           is still encrypted but no longer authenticated, so anything on the
 *   OSCAR_TLS_INSECURE  path can impersonate the node and read the credentials this server
 *                       injects. Announced on stderr at every startup so that a machine
 *                       left in this state can be recognised as being in it.
 *
 * Both come from the same oscar-config.json this client already reads its node from, under
 * node.tls (see readTlsPolicy in main.js) - an Electron app started from a Start Menu
 * shortcut has no useful environment to read. The variables above exist for running the
 * client from a terminal and for the packaging tests, and win over the file.
 *
 * With neither set, an unverifiable certificate fails the request and says so: the reason
 * reaches the Servers page rather than a bare 502. See describeUpstreamError.
 */
const TLS_ENV_CA = 'OSCAR_NODE_CA';
const TLS_ENV_INSECURE = 'OSCAR_TLS_INSECURE';

/** The policy the environment asks for. Shape matches the node.tls config block. */
function tlsPolicyFromEnv(env = process.env) {
    return {
        rejectUnauthorized: !/^(1|true|yes|on)$/i.test(env[TLS_ENV_INSECURE] || ''),
        caFile: env[TLS_ENV_CA] || null,
    };
}

/**
 * Turns a policy into the options an https/tls connection takes.
 *
 * An extra certificate is added to the system roots rather than replacing them: Node's
 * `ca` option replaces the default store outright, so a bare `ca: [nodeCert]` would leave
 * the client unable to verify any publicly-issued certificate - a second node with an
 * ordinary certificate would stop working the moment the first one's was trusted.
 *
 * An unreadable caFile falls back to the system store rather than to no verification at
 * all. A typo in a path must not be a way to end up trusting everything.
 */
function tlsConnectOptions(policy) {
    const options = { rejectUnauthorized: policy.rejectUnauthorized !== false };
    if (policy.caFile) {
        try {
            options.ca = [...tls.rootCertificates, fs.readFileSync(policy.caFile, 'utf8')];
        } catch (err) {
            console.error(`[proxy] cannot read the node certificate at ${policy.caFile}: `
                + `${err.message}. Continuing with the system certificate store.`);
        }
    }
    return options;
}

// Certificate problems arrive as a connection error rather than a status, and the
// operator's next move is nothing like the one for "the node is down": the address was
// right and the node answered - this client is what refused to continue.
const CERT_ERRORS = new Set([
    'UNABLE_TO_VERIFY_LEAF_SIGNATURE',
    'DEPTH_ZERO_SELF_SIGNED_CERT',
    'SELF_SIGNED_CERT_IN_CHAIN',
    'UNABLE_TO_GET_ISSUER_CERT',
    'UNABLE_TO_GET_ISSUER_CERT_LOCALLY',
    'CERT_HAS_EXPIRED',
    'CERT_NOT_YET_VALID',
    'ERR_TLS_CERT_ALTNAME_INVALID',
]);

/**
 * Why the node could not be reached, in terms of what to do about it.
 *
 * This text is the whole of the user-visible diagnosis: it is returned as the body of the
 * 502 and the Servers page shows it verbatim. "502" on its own sent operators looking at
 * the node, which was running the entire time.
 */
function describeUpstreamError(err, { host, port, secure }) {
    if (CERT_ERRORS.has(err.code)) {
        return `The certificate presented by ${host}:${port} could not be verified (${err.code}). `
            + 'If this node uses a self-signed certificate, set node.tls.caFile in '
            + 'oscar-config.json to a copy of that certificate. Setting '
            + 'node.tls.rejectUnauthorized to false connects without verifying anything, '
            + 'which leaves the connection open to interception.';
    }
    if (secure && (err.code === 'ERR_SSL_WRONG_VERSION_NUMBER' || err.code === 'EPROTO')) {
        return `${host}:${port} answered without TLS. Clear "Secure" for this server, or `
            + 'point it at the port that terminates https.';
    }
    return `OSCAR node unreachable at ${host}:${port}: ${err.message}`;
}

/**
 * The Host header to present upstream.
 *
 * An explicit default port is redundant, and it is the one shape a reverse proxy is least
 * likely to expect, so leave it off - matching nodeTransport() in the viewer, which makes
 * the same choice for the browser case.
 */
function hostHeader(host, port, secure) {
    return port === (secure ? 443 : 80) ? host : `${host}:${port}`;
}

// Requests the renderer addresses to a specific node carry its id in the path, because
// there is no other way to say which node a WebSocket is for: the handshake cannot carry
// credentials, and the viewer federates several nodes into one lane map, so a single
// upstream is not enough. The renderer registers the table first, then addresses
// /__oscar/u/<id>/... and this server supplies the credentials the browser could not.
const NODE_PREFIX = '/__oscar/u/';
const REGISTER_PATH = '/__oscar/upstreams';

/**
 * Creates the local server.
 *
 * @param {object}   opts
 * @param {string}   opts.staticRoot  directory holding the exported viewer
 * @param {function} opts.getUpstream returns {host, port, secure, auth} for the configured
 *                                    node, read lazily so the target can change without a
 *                                    restart
 * @param {object}   [opts.tlsPolicy] {rejectUnauthorized, caFile} for https nodes; read
 *                                    once here because it decides how the agent is built,
 *                                    so changing it needs a restart
 */
function createServer({ staticRoot, getUpstream, tlsPolicy = tlsPolicyFromEnv() }) {
    // id -> {host, port, secure, auth}. Held in memory only: it mirrors what the renderer
    // has in localStorage, which is the authority, and is re-registered on every boot.
    const upstreams = new Map();

    const tlsOptions = tlsConnectOptions(tlsPolicy);
    if (!tlsOptions.rejectUnauthorized) {
        console.warn('[proxy] TLS certificate verification is DISABLED. Traffic to an https '
            + 'node is encrypted but not authenticated, and the credentials this client '
            + 'injects are exposed to anything that can intercept it. Unset '
            + `node.tls.rejectUnauthorized / ${TLS_ENV_INSECURE} once the node's `
            + `certificate can be trusted through node.tls.caFile / ${TLS_ENV_CA}.`);
    }
    // One agent, so the policy cannot vary per request and connections are reused.
    const httpsAgent = new https.Agent({ ...tlsOptions, keepAlive: true });

    /**
     * Which node a request is for, and the path to send upstream.
     * Returns null when the request is not proxied at all.
     */
    const resolveTarget = (url) => {
        if (url.startsWith(NODE_PREFIX)) {
            const rest = url.slice(NODE_PREFIX.length);
            const slash = rest.indexOf('/');
            const id = decodeURIComponent(slash === -1 ? rest : rest.slice(0, slash));
            const upstream = upstreams.get(id);
            if (!upstream) return { unknownNode: id };
            return { upstream, path: slash === -1 ? '/' : rest.slice(slash) };
        }
        // Retained so a node-served deployment, and anything written against the older
        // single-upstream behaviour, keeps working.
        if (url.startsWith('/sensorhub')) return { upstream: getUpstream(), path: url };
        return null;
    };

    const registerUpstreams = (req, res) => {
        let body = '';
        req.on('data', (c) => {
            body += c;
            if (body.length > 1e6) { res.writeHead(413).end(); req.destroy(); }
        });
        req.on('end', () => {
            let list;
            try {
                list = JSON.parse(body);
                if (!Array.isArray(list)) throw new Error('expected an array');
            } catch (err) {
                res.writeHead(400, { 'Content-Type': 'text/plain' });
                res.end(`Bad upstream registration: ${err.message}`);
                return;
            }
            upstreams.clear();
            for (const n of list) {
                if (!n || !n.id || !n.address) continue;
                // Only an explicit true. A registration from an older renderer omits the
                // field entirely, and the safe reading of a missing answer is the one the
                // client behaved as if it had all along.
                const secure = n.isSecure === true;
                upstreams.set(String(n.id), {
                    host: n.address,
                    port: Number(n.port) || (secure ? 443 : 8282),
                    secure,
                    auth: n.auth && n.auth.username
                        ? `${n.auth.username}:${n.auth.password || ''}`
                        : null,
                });
            }
            res.writeHead(204).end();
        });
    };

    const serveStatic = (req, res) => {
        const urlPath = decodeURIComponent(req.url.split('?')[0]);
        let filePath = path.join(staticRoot, urlPath);

        // Contain the resolved path: a request for ../../etc/passwd must not escape.
        if (!filePath.startsWith(staticRoot)) {
            res.writeHead(403).end();
            return;
        }

        if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
            filePath = path.join(filePath, 'index.html');
        }
        if (!fs.existsSync(filePath)) {
            // The export is a static Next.js site with trailingSlash, so a bare route
            // maps to <route>/index.html.
            const asDir = path.join(staticRoot, urlPath, 'index.html');
            filePath = fs.existsSync(asDir) ? asDir : path.join(staticRoot, '404.html');
            if (!fs.existsSync(filePath)) filePath = path.join(staticRoot, 'index.html');
        }

        fs.readFile(filePath, (err, body) => {
            if (err) {
                res.writeHead(404).end();
                return;
            }
            const type = contentType(filePath);
            if (type.startsWith('text/html')) {
                body = Buffer.from(injectDesktopMarker(body.toString('utf8')), 'utf8');
            }
            res.writeHead(200, { 'Content-Type': type, 'Cache-Control': 'no-store' });
            res.end(body);
        });
    };

    const proxyHttp = (req, res, target) => {
        const { host, port, auth, secure } = target.upstream;
        const headers = { ...req.headers, host: hostHeader(host, port, secure) };
        if (auth && !headers.authorization) {
            headers.authorization = 'Basic ' + Buffer.from(auth).toString('base64');
        }

        // The agent carries the certificate policy, so it cannot be forgotten on a call
        // site. https.request derives SNI from `host` and correctly omits it for an
        // address literal.
        const options = { host, port, method: req.method, path: target.path, headers };
        if (secure) options.agent = httpsAgent;

        const upstream = (secure ? https : http).request(options, (upRes) => {
            res.writeHead(upRes.statusCode, upRes.headers);
            upRes.pipe(res);
        });
        upstream.on('error', (err) => {
            const reason = describeUpstreamError(err, { host, port, secure });
            console.error(`[proxy] ${req.method} ${target.path} -> ${reason}`);
            if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end(reason);
        });
        req.pipe(upstream);
    };

    // Hands the renderer the node the client is configured for, credentials included.
    //
    // Serving the real address is safe here precisely because address is no longer a
    // transport target: nodeTransport() in the viewer sends every request to this server
    // under /__oscar/u/<id> whenever the desktop marker is present, and the address is
    // only ever used as identity and as what gets registered back as the upstream.
    //
    // The credentials go with it because this server listens on loopback inside the
    // user's own application, and the renderer needs them for the REST calls it makes
    // before any upstream is registered. They are the same credentials the operator would
    // otherwise have to type into the Servers page on first run.
    const serveRuntimeConfig = (req, res) => {
        const { host, port, auth, secure } = getUpstream();
        const [username, ...rest] = auth ? auth.split(':') : [];
        const body = JSON.stringify({
            node: {
                name: 'OSCAR Node',
                address: host,
                port,
                oshPathRoot: '/sensorhub',
                csAPIEndpoint: '/api',
                // The node's own scheme, not this server's. The renderer talks to this
                // server over loopback http either way; isSecure is what it registers back
                // as the upstream, and what decides the second leg.
                isSecure: secure === true,
                auth: username ? { username, password: rest.join(':') } : undefined,
            },
        });
        res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
        res.end(body);
    };

    const server = http.createServer((req, res) => {
        const bare = req.url.split('?')[0];
        if (bare === REGISTER_PATH && req.method === 'POST') {
            registerUpstreams(req, res);
            return;
        }
        if (bare === '/oscar-config.json') {
            serveRuntimeConfig(req, res);
            return;
        }
        const target = resolveTarget(req.url);
        if (!target) {
            serveStatic(req, res);
            return;
        }
        if (target.unknownNode) {
            // The renderer registers before it fetches, so this means the table was
            // cleared or the page raced a reload. Say so plainly instead of proxying
            // to whatever the default upstream happens to be.
            res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end(`No upstream registered for node ${target.unknownNode}`);
            return;
        }
        proxyHttp(req, res, target);
    });

    // WebSocket (MQTT et al.): replay the handshake upstream, then splice the sockets
    // into a raw tunnel - but only once the node commits with a 101.
    //
    // Never splice before seeing the status line. A spliced socket that carried a
    // non-101 (a 401, say) looks to the client's HTTP agent like a healthy keep-alive
    // connection to THIS server; it gets pooled, and every later request reusing it
    // flows raw into the node, which serves its own documents for them. That produced
    // a long-standing "stale document" flake before the rule was found.
    server.on('upgrade', (req, clientSocket, head) => {
        const target = resolveTarget(req.url);
        if (!target || target.unknownNode) {
            clientSocket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n');
            return;
        }
        const { host, port, auth, secure } = target.upstream;

        const sendHandshake = () => {
            let handshake = `${req.method} ${target.path} HTTP/1.1\r\n`;
            let sawAuth = false;
            for (let i = 0; i < req.rawHeaders.length; i += 2) {
                const name = req.rawHeaders[i];
                const value = /^host$/i.test(name)
                    ? hostHeader(host, port, secure)
                    : req.rawHeaders[i + 1];
                if (/^authorization$/i.test(name)) sawAuth = true;
                handshake += `${name}: ${value}\r\n`;
            }
            if (!sawAuth && auth) {
                handshake += `Authorization: Basic ${Buffer.from(auth).toString('base64')}\r\n`;
            }
            upSocket.write(handshake + '\r\n');
            if (head && head.length) upSocket.write(head);
        };

        // A secure node needs the handshake written into a TLS session, not onto the wire.
        // tls.connect's callback is its 'secureConnect' listener, so this still runs once
        // there is somewhere for the bytes to go - and not before the certificate has been
        // judged. SNI is suppressed for an address literal, which RFC 6066 does not allow
        // as a server name and which Node otherwise warns about once per process.
        const upSocket = secure
            ? tls.connect({
                host,
                port,
                ...tlsOptions,
                servername: net.isIP(host) ? undefined : host,
            }, sendHandshake)
            : net.connect(port, host, sendHandshake);

        const kill = () => { clientSocket.destroy(); upSocket.destroy(); };

        // Once the sockets are spliced the client is speaking WebSocket and an HTTP
        // response would be framing garbage, so a late failure can only be a disconnect.
        let spliced = false;
        let refused = false;
        const refuse = (reason) => {
            if (spliced) {
                kill();
                return;
            }
            // A refusal already on its way out must be allowed to leave: destroying the
            // socket to say the same thing twice would truncate the explanation.
            if (refused) return;
            refused = true;
            console.warn(`[ws-refused] ${req.url} -> ${reason}`);
            clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n'
                + 'Content-Type: text/plain\r\n'
                + `Content-Length: ${Buffer.byteLength(reason)}\r\n`
                + 'Connection: close\r\n\r\n'
                + reason);
            upSocket.destroy();
        };

        let preface = Buffer.alloc(0);
        const onUpstreamData = (chunk) => {
            preface = Buffer.concat([preface, chunk]);
            const headerEnd = preface.indexOf('\r\n\r\n');
            if (headerEnd === -1) {
                if (preface.length > 16384) kill();
                return;
            }
            upSocket.removeListener('data', onUpstreamData);
            const statusLine = preface.slice(0, preface.indexOf('\r\n')).toString();
            if (/^HTTP\/1\.\d 101 /.test(statusLine)) {
                spliced = true;
                clientSocket.write(preface);
                upSocket.pipe(clientSocket);
                clientSocket.pipe(upSocket);
                return;
            }
            refuse(`the node answered ${statusLine}`);
        };
        upSocket.on('data', onUpstreamData);
        // A rejected certificate lands here, and used to take the client socket down with
        // it - the renderer saw a reset with no reason, which is how live data could be
        // dead while REST was merely 400ing.
        upSocket.on('error', (err) => refuse(describeUpstreamError(err, { host, port, secure })));
        clientSocket.on('error', kill);
    });

    return server;
}

module.exports = { createServer, tlsPolicyFromEnv };
