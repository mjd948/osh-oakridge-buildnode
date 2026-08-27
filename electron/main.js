const { app, BrowserWindow, dialog, Menu, Tray } = require('electron');
const path = require('path');
const fs = require('fs');
const { createServer, tlsPolicyFromEnv } = require('./proxy');

// Disable all background throttling before app is ready
app.commandLine.appendSwitch('disable-background-timer-throttling');
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');

// Fixed port: the origin must not change between runs or every localStorage key the
// app has written becomes unreachable. If it is taken we say so rather than silently
// moving, which would look like the app losing all its settings.
const SERVE_PORT = 38282;

let mainWindow = null;
let tray = null;

function getWebPath() {
    return app.isPackaged
        ? path.join(process.resourcesPath, 'web')
        : path.join(__dirname, '../web/oscar-viewer/web');
}

/**
 * Where this client should point.
 *
 * Read from oscar-config.json - written by the installer, or edited by the operator in
 * the app's own data directory, which takes precedence so an update to the bundled copy
 * cannot override a local choice.
 *
 * The machine-wide copy sits in ProgramData rather than next to the bundled web assets
 * because that directory is this app's own static root: anything in it is fetched by the
 * interface as well, which would point the interface straight at the node and undo the
 * single origin this proxy exists to provide. ProgramData is not served, so only the
 * main process sees it - and it survives per-user profiles, which an elevated installer
 * cannot write to anyway.
 */
function readConfiguredNode() {
    const machineWide = process.platform === 'win32' && process.env.ProgramData
        ? [path.join(process.env.ProgramData, 'OSCAR', 'config', 'oscar-config.json')]
        : [];

    const candidates = [
        path.join(app.getPath('userData'), 'oscar-config.json'),
        ...machineWide,
        path.join(getWebPath(), 'oscar-config.json'),
    ];

    for (const file of candidates) {
        try {
            if (!fs.existsSync(file)) continue;
            const parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
            const node = parsed && parsed.node;
            if (!node || !node.address) continue;
            return node;
        } catch (err) {
            console.warn(`[config] ignoring ${file}: ${err.message}`);
        }
    }
    return null;
}

function readUpstream() {
    const node = readConfiguredNode();

    // Nothing configured yet: assume a node on this machine. The Servers page lets the
    // user change it, and the proxy re-reads this on every request.
    if (!node) return { host: 'localhost', port: 8282, secure: false, auth: null };

    const secure = node.isSecure === true;
    return {
        host: node.address,
        port: Number(node.port) || (secure ? 443 : 8282),
        secure,
        auth: node.auth && node.auth.username
            ? `${node.auth.username}:${node.auth.password || ''}`
            : null,
    };
}

/**
 * How this client judges an https node's certificate. See the TLS section of proxy.js for
 * what the two settings mean and which one to reach for.
 *
 * Read once at startup, unlike the node address: it decides how the TLS agent is built, so
 * a change to it takes a restart. It lives in oscar-config.json beside the node it applies
 * to, because an app launched from a shortcut inherits no useful environment; the
 * variables are for a terminal and for the packaging tests, and win over the file so a
 * machine can be tested without editing its configuration.
 *
 * Only an explicit `false` relaxes verification. A missing or malformed value leaves it on.
 */
function readTlsPolicy() {
    const node = readConfiguredNode();
    const configured = (node && node.tls) || {};
    const fromEnv = tlsPolicyFromEnv();

    return {
        rejectUnauthorized: configured.rejectUnauthorized !== false && fromEnv.rejectUnauthorized,
        caFile: fromEnv.caFile || configured.caFile || null,
    };
}

function startServer(callback) {
    const server = createServer({
        staticRoot: getWebPath(),
        // Read lazily so editing the config file takes effect without a restart.
        getUpstream: readUpstream,
        tlsPolicy: readTlsPolicy(),
    });

    server.on('error', (err) => {
        const message = err.code === 'EADDRINUSE'
            ? `Port ${SERVE_PORT} is already in use.\n\n`
              + 'OSCAR needs this exact port: its saved servers and settings are tied to it. '
              + 'Another copy of OSCAR may already be running.'
            : `Could not start the local server: ${err.message}`;
        dialog.showErrorBox('OSCAR cannot start', message);
        app.exit(1);
    });

    server.listen(SERVE_PORT, '127.0.0.1', callback);
}

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 1920,
        height: 1080,
        minWidth: 1280,
        minHeight: 720,
        title: 'OSCAR',
        icon: path.join(__dirname, 'assets', 'icon.ico'),
        show: false,
        autoHideMenuBar: true,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            nodeIntegration: false,
            contextIsolation: true,
            // webSecurity stays on. The API is reached through this app's own origin
            // via the proxy, so there is no cross-origin request left to permit.
        },
    });

    Menu.setApplicationMenu(null);
    mainWindow.loadURL(`http://localhost:${SERVE_PORT}/`);
    mainWindow.once('ready-to-show', () => {
        mainWindow.show();
        mainWindow.maximize();
    });

    // Ctrl+R / F5 — reload after changing the configured node.
    //
    // F12 / Ctrl+Shift+I — devtools. Registered explicitly because setApplicationMenu(null)
    // removes the default menu, and with it the accelerators Chromium would otherwise
    // provide: without this there is no way to see a failing request from inside a
    // packaged build, which is the only place several of these problems appear.
    mainWindow.webContents.on('before-input-event', (_event, input) => {
        if (input.type !== 'keyDown') return;
        const key = input.key.toLowerCase();

        if (input.key === 'F5' || (input.control && key === 'r')) {
            mainWindow.webContents.reload();
        }
        if (input.key === 'F12' || (input.control && input.shift && key === 'i')) {
            mainWindow.webContents.toggleDevTools();
        }
    });

    mainWindow.on('close', event => {
        event.preventDefault();
        const choice = dialog.showMessageBoxSync(mainWindow, {
            type: 'warning',
            buttons: ['Cancel', 'Exit OSCAR'],
            defaultId: 0,
            cancelId: 0,
            title: 'Exit OSCAR?',
            message: 'Active radiation monitoring will stop.',
            detail: 'Are you sure you want to exit OSCAR?',
        });
        if (choice === 1) {
            mainWindow = null;
            app.exit(0);
        }
    });
}

function createTray() {
    tray = new Tray(path.join(__dirname, 'assets', 'tray-icon.png'));
    tray.setToolTip('OSCAR — Radiation Detection');
    tray.setContextMenu(Menu.buildFromTemplate([
        {
            label: 'Show OSCAR',
            click: () => { mainWindow?.show(); mainWindow?.focus(); },
        },
        {
            label: 'Reload',
            click: () => mainWindow?.webContents.reload(),
        },
        { type: 'separator' },
        {
            label: 'Exit OSCAR',
            click: () => {
                const choice = dialog.showMessageBoxSync({
                    type: 'warning',
                    buttons: ['Cancel', 'Exit OSCAR'],
                    defaultId: 0,
                    cancelId: 0,
                    title: 'Exit OSCAR?',
                    message: 'Active radiation monitoring will stop.',
                    detail: 'Are you sure you want to exit OSCAR?',
                });
                if (choice === 1) app.exit(0);
            },
        },
    ]));
    tray.on('double-click', () => { mainWindow?.show(); mainWindow?.focus(); });
}

app.whenReady().then(() => {
    // Register autostart on Windows login (packaged builds only)
    if (app.isPackaged && process.platform === 'win32') {
        app.setLoginItemSettings({ openAtLogin: true, path: app.getPath('exe') });
    }

    // No app.on('login') handler any more. It used to intercept the node's 401
    // challenges and answer them by reaching into the renderer to read
    // localStorage.osh_nodes. The proxy now injects credentials server-side, so the
    // renderer never sees a challenge and the main process never has to scrape it.

    startServer(() => {
        createWindow();
        createTray();
    });
});

// Keep the process alive via tray — do not quit when the window is closed
app.on('window-all-closed', () => {});
