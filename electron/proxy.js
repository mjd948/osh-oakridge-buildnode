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
 */

const http = require('http');
const net = require('net');
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
 * Creates the local server.
 *
 * @param {object}   opts
 * @param {string}   opts.staticRoot  directory holding the exported viewer
 * @param {function} opts.getUpstream returns {host, port, auth} for the configured node,
 *                                    read lazily so the target can change without a restart
 */
function createServer({ staticRoot, getUpstream }) {
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
            res.writeHead(200, { 'Content-Type': contentType(filePath), 'Cache-Control': 'no-store' });
            res.end(body);
        });
    };

    const proxyHttp = (req, res) => {
        const { host, port, auth } = getUpstream();
        const headers = { ...req.headers, host: `${host}:${port}` };
        if (auth && !headers.authorization) {
            headers.authorization = 'Basic ' + Buffer.from(auth).toString('base64');
        }

        const upstream = http.request({ host, port, method: req.method, path: req.url, headers }, (upRes) => {
            res.writeHead(upRes.statusCode, upRes.headers);
            upRes.pipe(res);
        });
        upstream.on('error', (err) => {
            console.error(`[proxy] ${req.method} ${req.url} -> ${err.message}`);
            if (!res.headersSent) res.writeHead(502, { 'Content-Type': 'text/plain' });
            res.end(`OSCAR node unreachable at ${host}:${port}: ${err.message}`);
        });
        req.pipe(upstream);
    };

    const server = http.createServer((req, res) => {
        if (req.url.startsWith('/sensorhub')) proxyHttp(req, res);
        else serveStatic(req, res);
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
        const { host, port, auth } = getUpstream();
        const upSocket = net.connect(port, host, () => {
            let handshake = `${req.method} ${req.url} HTTP/1.1\r\n`;
            let sawAuth = false;
            for (let i = 0; i < req.rawHeaders.length; i += 2) {
                const name = req.rawHeaders[i];
                const value = /^host$/i.test(name) ? `${host}:${port}` : req.rawHeaders[i + 1];
                if (/^authorization$/i.test(name)) sawAuth = true;
                handshake += `${name}: ${value}\r\n`;
            }
            if (!sawAuth && auth) {
                handshake += `Authorization: Basic ${Buffer.from(auth).toString('base64')}\r\n`;
            }
            upSocket.write(handshake + '\r\n');
            if (head && head.length) upSocket.write(head);
        });

        const kill = () => { clientSocket.destroy(); upSocket.destroy(); };

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
                clientSocket.write(preface);
                upSocket.pipe(clientSocket);
                clientSocket.pipe(upSocket);
                return;
            }
            console.warn(`[ws-refused] ${req.url} -> ${statusLine}`);
            clientSocket.end('HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n');
            upSocket.destroy();
        };
        upSocket.on('data', onUpstreamData);
        upSocket.on('error', kill);
        clientSocket.on('error', kill);
    });

    return server;
}

module.exports = { createServer };
