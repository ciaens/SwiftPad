
(function () {
    'use strict';

    const worker = globalThis['cryptpad-worker-min'];
    if (!worker || !worker.store) {
        throw new Error('SwiftPad: worker bundle not loaded');
    }
    const store = worker.store;

    (function probeBundleExports() {
        const g = globalThis;
        const required = [
            ['CryptPad_Hash.getBlobPathFromHex', g.CryptPad_Hash && g.CryptPad_Hash.getBlobPathFromHex],
            ['CryptPad_Hash.parsePadUrl',        g.CryptPad_Hash && g.CryptPad_Hash.parsePadUrl],
            ['CryptPad_Hash.getSecrets',         g.CryptPad_Hash && g.CryptPad_Hash.getSecrets],
            ['CryptPad_Hash.createRandomHash',   g.CryptPad_Hash && g.CryptPad_Hash.createRandomHash],
            ['CryptPad_Hash.parseTypeHash',      g.CryptPad_Hash && g.CryptPad_Hash.parseTypeHash],
            ['nacl.hash',                        g.nacl && g.nacl.hash],
            ['nacl.secretbox',                   g.nacl && g.nacl.secretbox],
            ['nacl.secretbox.open',              g.nacl && g.nacl.secretbox && g.nacl.secretbox.open],
            ['nacl.sign',                        g.nacl && g.nacl.sign],
            ['nacl.sign.detached',               g.nacl && g.nacl.sign && g.nacl.sign.detached],
            ['nacl.randomBytes',                 g.nacl && g.nacl.randomBytes],
            ['nacl.sign.keyPair',                g.nacl && g.nacl.sign && g.nacl.sign.keyPair],
            ['nacl.box.keyPair',                 g.nacl && g.nacl.box && g.nacl.box.keyPair],
            ['CryptPad_Util.uint8ArrayToHex',    g.CryptPad_Util && g.CryptPad_Util.uint8ArrayToHex],
            ['ChainPad.create',                  g.ChainPad && g.ChainPad.create],
            ['ChainPad.Message.toStr',           g.ChainPad && g.ChainPad.Message && g.ChainPad.Message.toStr],
            ['CryptPad_Util.encodeUTF8',         g.CryptPad_Util && g.CryptPad_Util.encodeUTF8],
            ['CryptPad_Util.decodeUTF8',         g.CryptPad_Util && g.CryptPad_Util.decodeUTF8],
            ['CryptPad_Util.decodeBase64',       g.CryptPad_Util && g.CryptPad_Util.decodeBase64],
            ['CryptPad_Util.encodeBase64',       g.CryptPad_Util && g.CryptPad_Util.encodeBase64]
        ];
        for (let i = 0; i < required.length; i++) {
            if (typeof required[i][1] !== 'function') {
                throw new Error('SwiftPad: pinned bundle missing required export: ' + required[i][0]);
            }
        }
    })();

    const mkTxid = () =>
        Math.random().toString(16).slice(2) +
        Math.random().toString(16).slice(2);

    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

    const mkSessionId = () =>
        'sess-' + Math.random().toString(16).slice(2) +
        Math.random().toString(16).slice(2);

    const queries = Object.create(null);
    const acks = Object.create(null);
    let chanReady = false;
    const chanReadyQueue = [];
    const pendingBeforeStore = [];
    const pendingBeforeChan = [];

    const redactKeyed = (s, key) => s.replace(
        new RegExp('(\\\\?"' + key + '\\\\?"\\s*:\\s*")(?:[^"\\\\]|\\\\.)*?"', 'g'),
        '$1<redacted>"');
    const redactPreview = (s) => {
        let out = s
            .replace(/\/2\/[A-Za-z0-9]+\/(?:edit|view)\/[^"'\s\\]{8,}/g, '/2/<redacted>')
            .replace(/#[A-Za-z0-9+\/\-_=]{16,}/g, '#<redacted>')
            .replace(/(\\?"seeds\\?"\s*:\s*)\{[^}]*\}/g, '$1{<redacted>}')
            .replace(/(\\?"cryptKey\\?"\s*:\s*)\{[^}]*\}/g, '$1{<redacted>}')
            .replace(/(\\?"loginToken\\?"\s*:\s*\\?")(?:[^"\\]|\\.)*?(\\?")/g, '$1<redacted>$2')
            .replace(/(\\?"loginToken\\?"\s*:\s*)\d+/g, '$1<redacted>');
        const skipContentRule = out.indexOf('"q":"EV_REGISTER_HANDLER"') !== -1;
        ['password', 'bytes64', 'edPrivate', 'curvePrivate',
         'supportPrivateKey', 'edit', 'view', 'signKey', 'validateKey',
         'cryptKey', 'content', 'text',
         'editHash', 'viewHash', 'body', 'location'].forEach((k) => {
            if (k === 'content' && skipContentRule) { return; }
            out = redactKeyed(out, k);
        });
        if (out.indexOf('"type":"calendar"') !== -1) {
            out = redactKeyed(out, 'title');
        }
        if (out.indexOf('"q":"MAILBOX_EVENT"') !== -1
            || out.indexOf('"q":"ANSWER_FRIEND_REQUEST"') !== -1) {
            const msgIdx = out.indexOf('"msg":');
            const messageIdx = out.indexOf('"message":');
            const candidates = [msgIdx, messageIdx].filter((i) => i !== -1);
            if (candidates.length) {
                const cut = Math.min.apply(null, candidates);
                out = out.slice(0, cut) + '<redacted mailbox envelope>';
            }
        }
        return out;
    };

    const sendRaw = (payload) => {
        if (typeof __sp_trace === 'function') {
            const str = typeof payload === 'string' ? payload : JSON.stringify(payload);
            __sp_trace('bootstrap', 'debug', '-> ' + redactPreview(str).slice(0, 140));
        }
        setTimeout(() => store.query(payload), 0);
    };

    const whenChanReady = (fn) => {
        if (chanReady) fn();
        else chanReadyQueue.push(fn);
    };

    const flushChanReady = () => {
        chanReady = true;
        while (chanReadyQueue.length) chanReadyQueue.shift()();
        while (pendingBeforeChan.length) dispatchFramed(pendingBeforeChan.shift());
    };

    const dispatchFramed = (raw) => {
        let parsed = raw;
        if (typeof raw === 'string') {
            try { parsed = JSON.parse(raw); } catch (e) { return; }
        }
        if (!parsed || typeof parsed !== 'object') return;
        if (typeof parsed.ack !== 'undefined') {
            const a = acks[parsed.txid];
            if (a) { delete acks[parsed.txid]; a(!parsed.ack); }
            return;
        }
        if (typeof parsed.q === 'string') {
            if (parsed.txid) {
                sendRaw(JSON.stringify({ txid: parsed.txid, ack: true }));
            }
            if (parsed.q === 'UNIVERSAL_EVENT') {
                try { interceptCalendarFrame(parsed.content); } catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn', 'calendar frame interception threw: ' + e.message);
                    }
                }
            }
            if (parsed.q === 'MAILBOX_EVENT') {
                try { interceptMailboxFrame(parsed.content); } catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn', 'mailbox frame interception threw: ' + e.message);
                    }
                }
            }
            if (typeof __sp_event === 'function') {
                const payloadStr = JSON.stringify(parsed.content === undefined ? null : parsed.content);
                try { __sp_event(parsed.q, payloadStr); } catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn', '__sp_event threw for ' + parsed.q + ': ' + e.message);
                    }
                }
            }
            return;
        }
        if (typeof parsed.q === 'undefined' && queries[parsed.txid]) {
            const cb = queries[parsed.txid];
            delete queries[parsed.txid];
            cb(parsed);
        }
    };

    let storeReady = false;
    const storeReadyQueue = [];

    store.onMessage((data) => {
        if (typeof __sp_trace === 'function') {
            const str = typeof data === 'string' ? data : JSON.stringify(data);
            __sp_trace('bootstrap', 'debug', '<- ' + redactPreview(str).slice(0, 140));
        }
        if (data === 'STORE_READY') {
            storeReady = true;
            sendRaw('_READY');
            while (storeReadyQueue.length) storeReadyQueue.shift()();
            while (pendingBeforeStore.length) {
                const d = pendingBeforeStore.shift();
                onWorkerMessage(d);
            }
            return;
        }
        if (!storeReady) {
            pendingBeforeStore.push(data);
            return;
        }
        onWorkerMessage(data);
    });

    function onWorkerMessage(data) {
        if (!chanReady) {
            if (data === '_READY') {
                sendRaw('_READY');
                flushChanReady();
                return;
            }
            pendingBeforeChan.push(data);
            return;
        }
        dispatchFramed(data);
    }

    function decryptHistoryMsg(wireMsg, cryptKey, validateKeyBytes) {
        try {
            let m = wireMsg;
            if (/^cp\|/.test(m)) m = m.replace(/^cp\|[^|]+\|/, '');
            m = m.replace(/^\d+:/, '');
            const signedBytes = CryptPad_Util.decodeBase64(m);
            const innerBytes = nacl.sign.open(signedBytes, validateKeyBytes);
            if (!innerBytes) return null;
            const inner = CryptPad_Util.encodeUTF8(innerBytes);
            const parts = inner.split('|');
            if (parts.length !== 2) return null;
            const nonce = CryptPad_Util.decodeBase64(parts[0]);
            const packed = CryptPad_Util.decodeBase64(parts[1]);
            const plain = nacl.secretbox.open(packed, nonce, cryptKey);
            return plain ? CryptPad_Util.encodeUTF8(plain) : null;
        } catch (_) { return null; }
    }

    function setupReplay(opts) {
        const { network, hk, channel, cp, ourTxid,
                cryptKey, validateKeyB64, validateKeyBytes,
                lastKnownHash } = opts;
        let resolveReady, rejectReady;
        const readyPromise = new Promise((res, rej) => {
            resolveReady = res;
            rejectReady = rej;
        });
        const counters = {
            seen: 0,
            applied: 0,
            dropped: 0,
            firstAppliedWireHash: null,
            lastAppliedWireHash: null,
            lastAppliedCheckpointWireHash: null
        };
        const listener = function (content, sender) {
            if (sender !== hk) return;
            let frame; try { frame = JSON.parse(content); } catch (_) { return; }
            if (Array.isArray(frame) && frame.length >= 5 && frame[3] === channel) {
                counters.seen++;
                if (!cp) return;
                const wireHash = (typeof frame[4] === 'string') ? frame[4].slice(0, 64) : null;
                const plain = decryptHistoryMsg(frame[4], cryptKey, validateKeyBytes);
                if (plain) {
                    try {
                        cp.message(plain);
                        counters.applied++;
                        if (counters.firstAppliedWireHash === null) counters.firstAppliedWireHash = wireHash;
                        counters.lastAppliedWireHash = wireHash;
                        if (typeof plain === 'string' && plain.startsWith('[4,')) {
                            counters.lastAppliedCheckpointWireHash = wireHash;
                        }
                    } catch (_) { counters.dropped++; }
                } else {
                    counters.dropped++;
                }
                return;
            }
            if (frame && frame.txid === ourTxid) {
                if (frame.state === 1) return resolveReady();
                if (frame.error) return rejectReady(new Error(frame.error));
            }
        };
        return {
            listener,
            readyPromise,
            counters,
            sendGetHistory() {
                const effectiveLkh = (lastKnownHash != null) ? lastKnownHash : 0;
                network.sendto(hk, JSON.stringify(['GET_HISTORY', channel, {
                    validateKey: validateKeyB64,
                    lastKnownHash: effectiveLkh,
                    txid: ourTxid
                }]));
            }
        };
    }

    const padSessions = new Map();

    const pendingPadSessions = new Map();

    const chatSessions = new Map();
    const chatOpensInFlight = new Set();

    const dmSessions = new Map();
    const dmOpensInFlight = new Set();
    let initFriendsPromise = null;
    const ensureInitFriends = () => {
        if (!initFriendsPromise) {
            initFriendsPromise = messengerCmd('INIT_FRIENDS', {}, 'CHAT_OPEN_TIMEOUT')
                .then((res) => {
                    if (res && res.error) { initFriendsPromise = null; }
                    return res;
                }, (e) => {
                    initFriendsPromise = null;
                    throw e;
                });
        }
        return initFriendsPromise;
    };

    function loadPadCryptoContext(channel) {
        const found = findFileInProxy(channel);
        if (!found) return { error: 'ENOENT' };
        const entry = found.entry;
        const href = entry.href || entry.roHref || '';
        if (!href) return { error: 'NO_HREF' };

        const password = (typeof entry.password === 'string' && entry.password.length > 0) ? entry.password : undefined;
        const parsed = CryptPad_Hash.parsePadUrl(href);
        if (!parsed || !parsed.hash) return { error: 'PARSE_URL_FAILED' };

        const secret = CryptPad_Hash.getSecrets(parsed.type, parsed.hash, password);
        if (!secret || secret.channel !== channel) return { error: 'CHANNEL_MISMATCH' };

        const isViewMode = (parsed.hashData && parsed.hashData.mode === 'view');
        if (isViewMode) return { error: 'EREADONLY', errorType: 'view-mode opens deferred to phase-2' };
        if (!secret.keys || !secret.keys.signKey) return { error: 'EREADONLY', errorType: 'no signKey — view-only secret' };

        const cryptKey = (secret.keys.cryptKey instanceof Uint8Array)
            ? secret.keys.cryptKey
            : CryptPad_Util.decodeBase64(secret.keys.cryptKey);
        const validateKeyB64 = (typeof secret.keys.validateKey === 'string')
            ? secret.keys.validateKey
            : CryptPad_Util.encodeBase64(secret.keys.validateKey);
        const validateKeyBytes = CryptPad_Util.decodeBase64(validateKeyB64);
        const signKey = (secret.keys.signKey instanceof Uint8Array)
            ? secret.keys.signKey
            : CryptPad_Util.decodeBase64(secret.keys.signKey);
        const signKeyB64 = (typeof secret.keys.signKey === 'string')
            ? secret.keys.signKey
            : CryptPad_Util.encodeBase64(secret.keys.signKey);

        const readOnly = false;

        const encrypt = (msg) => {
            const nonce = nacl.randomBytes(24);
            const packed = nacl.secretbox(CryptPad_Util.decodeUTF8(msg), nonce, cryptKey);
            const inner = CryptPad_Util.encodeBase64(nonce) + '|' + CryptPad_Util.encodeBase64(packed);
            return CryptPad_Util.encodeBase64(nacl.sign(CryptPad_Util.decodeUTF8(inner), signKey));
        };

        return {
            ok: true,
            type: parsed.type,
            readOnly,
            cryptKey,
            validateKeyB64,
            validateKeyBytes,
            encrypt,
            workerSecret: {
                channel: channel,
                keys: {
                    cryptKey: cryptKey,
                    signKey: signKeyB64,
                    validateKey: validateKeyB64
                }
            }
        };
    }

    function mkLiveListeners(handle) {
        const networkListener = (content, sender) => {
            if (handle.closed) return;
            if (sender !== handle.hk) return;
            let frame; try { frame = JSON.parse(content); } catch (_) { return; }
            if (frame && !Array.isArray(frame) && frame.channel === handle.channel && frame.error) {
                emitPadSessionError(handle, frame.error);
            }
        };
        const wcListener = (msg, sender) => {
            if (handle.closed) return;
            if (typeof msg !== 'string' || msg.length < 64) return;
            const hash = msg.slice(0, 64);
            if (handle.lastSent.has(hash)) {
                handle.lastSent.delete(hash);
                return;
            }
            const plain = decryptHistoryMsg(msg, handle.cryptKey, handle.validateKeyBytes);
            if (plain) {
                try { handle.cp.message(plain); }
                catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn',
                            'PadSession ' + handle.channel + ': cp.message threw: ' + (e && e.message));
                    }
                }
            } else if (typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'debug',
                    'PadSession ' + handle.channel + ': decrypt failed for incoming PATCH');
            }
        };
        return { networkListener, wcListener };
    }

    function emitPadSessionError(handle, code) {
        if (typeof __sp_event !== 'function') return;
        try {
            __sp_event('PAD_SESSION_ERROR', JSON.stringify({
                sessionId: handle.sessionId,
                code: code
            }));
        } catch (e) {
            if (typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn', 'PAD_SESSION_ERROR emit failed: ' + e.message);
            }
        }
    }

    function findFileInProxy(channel) {
        const proxy = CryptPad_AsyncStore.proxy;
        const filesData = (proxy && proxy.drive && proxy.drive.filesData)
            || (proxy && proxy.filesData)
            || null;
        if (!filesData) return null;
        for (const id of Object.keys(filesData)) {
            const f = filesData[id];
            if (f && typeof f === 'object' && f.channel === channel) {
                return { id: id, entry: f };
            }
        }
        return null;
    }

    const query = (q, content, opts) => new Promise((resolve, reject) => {
        const txid = mkTxid();
        const timeoutMs = (opts && opts.timeout) || 30000;
        let to = null;
        if (timeoutMs > 0) {
            to = setTimeout(() => {
                delete queries[txid];
                delete acks[txid];
                reject(new Error('SwiftPad: query timeout: ' + q));
            }, timeoutMs);
        }
        acks[txid] = (failed) => {
            if (failed) {
                if (to) clearTimeout(to);
                delete queries[txid];
                delete acks[txid];
                reject(new Error('SwiftPad: query not handled: ' + q));
            }
        };
        queries[txid] = (data) => {
            if (to) clearTimeout(to);
            delete acks[txid];
            resolve(data.content);
        };
        whenChanReady(() => {
            sendRaw(JSON.stringify({ txid: txid, content: content, q: q, raw: false }));
        });
    });

    const rawErrorEnvelope = (res, fallback) => ({
        error: typeof res.error === 'string' ? res.error : fallback,
        errorType: typeof res.error === 'string' ? undefined : String(res.error).slice(0, 200)
    });

    const teamCmd = (cmd, args) =>
        query('UNIVERSAL_COMMAND', { type: 'team', data: { cmd: cmd, data: args || {} } });

    const MESSENGER_CMD_TIMEOUT_MS = 15000;
    const DM_JOIN_POLL_MS = 10000;
    const DM_JOIN_POLL_STEP_MS = 500;
    const messengerCmd = (cmd, args, timeoutCode) => {
        let timedOut = false;
        let to;
        const timed = new Promise((resolve) => {
            to = setTimeout(() => {
                timedOut = true;
                resolve({
                    error: timeoutCode || 'CHAT_TIMEOUT',
                    errorType: 'messenger ' + cmd + ': no reply within '
                        + MESSENGER_CMD_TIMEOUT_MS + 'ms'
                });
            }, MESSENGER_CMD_TIMEOUT_MS);
        });
        const q = query('UNIVERSAL_COMMAND',
            { type: 'messenger', data: { cmd: cmd, data: args || {} } });
        q.then(() => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'messenger ' + cmd + ' settled AFTER its typed timeout — command landed worker-side');
            }
        }, () => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'messenger ' + cmd + ' rejected after its typed timeout');
            }
        });
        return Promise.race([q, timed]).then((res) => {
            clearTimeout(to);
            if (res && res.error === 'messenger is disabled') {
                return { error: 'MESSENGER_DISABLED' };
            }
            if (res && res.error !== undefined && typeof res.error !== 'string') {
                let detail;
                try { detail = JSON.stringify(res.error); } catch (e) { detail = String(res.error); }
                return { error: 'CHAT_FAILED', errorType: String(detail).slice(0, 200) };
            }
            return res;
        }, (e) => {
            clearTimeout(to);
            throw e;
        });
    };

    const PROFILE_CMD_TIMEOUT_MS = 15000;
    const profileCmd = (cmd, args, timeoutCode, timeoutMs) => {
        const budget = timeoutMs || PROFILE_CMD_TIMEOUT_MS;
        let timedOut = false;
        let to;
        const timed = new Promise((resolve) => {
            to = setTimeout(() => {
                timedOut = true;
                resolve({
                    error: timeoutCode || 'PROFILE_TIMEOUT',
                    errorType: 'profile ' + cmd + ': no reply within '
                        + budget + 'ms'
                });
            }, budget);
        });
        const q = query('UNIVERSAL_COMMAND',
            { type: 'profile', data: { cmd: cmd, data: args || {} } });
        q.then(() => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'profile ' + cmd + ' settled AFTER its typed timeout — command landed worker-side');
            }
        }, () => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'profile ' + cmd + ' rejected after its typed timeout');
            }
        });
        return Promise.race([q, timed]).then((res) => {
            clearTimeout(to);
            return res;
        }, (e) => {
            clearTimeout(to);
            throw e;
        });
    };

    const CALENDAR_CMD_TIMEOUT_MS = 15000;
    const calendarCmd = (cmd, args, timeoutCode, timeoutMs) => {
        const budget = timeoutMs || CALENDAR_CMD_TIMEOUT_MS;
        let timedOut = false;
        let to;
        const timed = new Promise((resolve) => {
            to = setTimeout(() => {
                timedOut = true;
                resolve({
                    error: timeoutCode || 'CALENDAR_TIMEOUT',
                    errorType: 'calendar ' + cmd + ': no reply within '
                        + budget + 'ms'
                });
            }, budget);
        });
        const q = query('UNIVERSAL_COMMAND',
            { type: 'calendar', data: { cmd: cmd, data: args || {} } });
        q.then(() => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'calendar ' + cmd + ' settled AFTER its typed timeout — command landed worker-side');
            }
        }, () => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'calendar ' + cmd + ' rejected after its typed timeout');
            }
        });
        return Promise.race([q, timed]).then((res) => {
            clearTimeout(to);
            if (res && res.error !== undefined && typeof res.error !== 'string') {
                let detail;
                try { detail = JSON.stringify(res.error); } catch (e) { detail = String(res.error); }
                return { error: 'CALENDAR_FAILED', errorType: String(detail).slice(0, 200) };
            }
            return res;
        }, (e) => {
            clearTimeout(to);
            throw e;
        });
    };

    const calendarSnapshots = new Map();
    const interceptCalendarFrame = (content) => {
        if (!content || content.type !== 'calendar') { return; }
        const inner = content.data;
        if (!inner || inner.ev !== 'UPDATE') { return; }
        const p = inner.data;
        if (!p || typeof p.id !== 'string') { return; }
        if (p.deleted) { calendarSnapshots.delete(p.id); return; }
        calendarSnapshots.set(p.id, p);
    };

    const CALENDAR_SUBSCRIBE_WAIT_MS = 5000;
    let calendarSubscribePromise = null;
    const ensureCalendarSubscribed = () => {
        if (calendarSubscribePromise) { return calendarSubscribePromise; }
        calendarSubscribePromise = (async () => {
            const res = await calendarCmd('SUBSCRIBE', {}, 'CALENDAR_TIMEOUT');
            if (res && res.error) {
                calendarSubscribePromise = null;
                return res;
            }
            const expected = (res && typeof res.length === 'number') ? res.length : 0;
            const deadline = Date.now() + CALENDAR_SUBSCRIBE_WAIT_MS;
            const settled = () => {
                if (calendarSnapshots.size < expected) { return false; }
                for (const p of calendarSnapshots.values()) {
                    if (p.loading) { return false; }
                }
                return true;
            };
            while (!settled() && Date.now() < deadline) {
                await sleep(50);
            }
        })().catch((e) => {
            calendarSubscribePromise = null;
            throw e;
        });
        return calendarSubscribePromise;
    };

    const MAILBOX_CMD_TIMEOUT_MS = 15000;
    const mailboxCmd = (cmd, args, timeoutCode, timeoutMs, expectNoReply) => {
        const lateLevel = expectNoReply ? 'debug' : 'warn';
        const budget = (typeof timeoutMs === 'number' && timeoutMs > 0)
            ? timeoutMs : MAILBOX_CMD_TIMEOUT_MS;
        let timedOut = false;
        let to;
        const timed = new Promise((resolve) => {
            to = setTimeout(() => {
                timedOut = true;
                resolve({
                    error: timeoutCode || 'MAILBOX_TIMEOUT',
                    errorType: 'mailbox ' + cmd + ': no reply within ' + budget + 'ms'
                });
            }, budget);
        });
        const q = query('MAILBOX_COMMAND', { cmd: cmd, data: args || {} });
        q.then(() => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', lateLevel,
                    'mailbox ' + cmd + ' settled AFTER its typed timeout — command landed worker-side');
            }
        }, () => {
            if (timedOut && typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', lateLevel,
                    'mailbox ' + cmd + ' rejected after its typed timeout');
            }
        });
        return Promise.race([q, timed]).then((res) => {
            clearTimeout(to);
            if (res && res.error === 'Mailbox is disabled') {
                return { error: 'MAILBOX_DISABLED' };
            }
            if (res && res.error !== undefined && typeof res.error !== 'string') {
                let detail;
                try { detail = JSON.stringify(res.error); } catch (e) { detail = String(res.error); }
                return { error: 'MAILBOX_FAILED', errorType: String(detail).slice(0, 200) };
            }
            return res;
        }, (e) => {
            clearTimeout(to);
            throw e;
        });
    };

    const mailboxBuffer = new Map();
    const mailboxKey = (type, hash) => type + '|' + hash;
    const mailboxEvict = (type, hash) => { mailboxBuffer.delete(mailboxKey(type, hash)); };
    const mailboxBoxAttestsAuthor = (box) =>
        box === 'notifications' || box === 'supportteam' || box.indexOf('team-') === 0;

    const projectMailboxRow = (box, hash, msg, timeMs) => ({
        box: box,
        hash: hash,
        type: (typeof msg.type === 'string') ? msg.type : '',
        author: (mailboxBoxAttestsAuthor(box)
                 && typeof msg.author === 'string' && msg.author) ? msg.author : null,
        time: (typeof timeMs === 'number' && timeMs > 0) ? timeMs : null,
        content: (msg.content === undefined) ? null : msg.content
    });
    const interceptMailboxFrame = (content) => {
        if (!content || typeof content !== 'object') { return; }
        if (content.ev === 'MESSAGE') {
            const d = content.data;
            if (!d || typeof d.type !== 'string') { return; }
            const inner = d.content;
            if (!inner || typeof inner.hash !== 'string') { return; }
            if (!inner.msg || typeof inner.msg !== 'object') { return; }
            mailboxBuffer.set(mailboxKey(d.type, inner.hash),
                { type: d.type, hash: inner.hash, msg: inner.msg });
            return;
        }
        if (content.ev === 'VIEWED') {
            const d = content.data;
            if (!d || typeof d.type !== 'string' || typeof d.hash !== 'string') { return; }
            mailboxEvict(d.type, d.hash);
            return;
        }
        if (content.ev === 'HISTORY') {
            historyCollect(content.data);
        }
    };

    const HISTORY_ROW_IDLE_MS = 15000;
    const MAX_HISTORY_COUNT = 100;
    let historyPending = null;
    let historyTxidCounter = 0;

    const historyArmTimer = () => {
        if (!historyPending) { return; }
        if (historyPending.timer) { clearTimeout(historyPending.timer); }
        historyPending.timer = setTimeout(() => {
            historySettle({
                error: 'HISTORY_TIMEOUT',
                errorType: 'no history row within ' + HISTORY_ROW_IDLE_MS
                    + 'ms — the history keeper answered with an error frame '
                    + '(which emits no HISTORY event) or the request never left'
            });
        }, HISTORY_ROW_IDLE_MS);
    };

    const historySettle = (result) => {
        if (!historyPending) { return; }
        const p = historyPending;
        historyPending = null;
        if (p.timer) { clearTimeout(p.timer); }
        p.settle(result);
    };

    const historyCollect = (d) => {
        if (!d || !historyPending || d.txid !== historyPending.txid) { return; }
        if (d.complete === true) {
            historySettle({ rows: historyPending.rows });
            return;
        }
        if (typeof d.hash !== 'string') { return; }
        if (historyPending.rows.length >= historyPending.limit) {
            historySettle({
                error: 'HISTORY_OVERRUN',
                errorType: 'history keeper sent more than the ' + historyPending.limit
                    + ' rows requested'
            });
            return;
        }
        historyPending.rows.push({
            hash: d.hash,
            time: (typeof d.time === 'number') ? d.time : null,
            message: (d.message && typeof d.message === 'object') ? d.message : null
        });
        historyArmTimer();
    };

    const contactSyncBarrier = async () => {
        const sync = await query('SET_ATTRIBUTE', { attr: ['swiftpadSyncBarrier'] });
        if (sync && typeof sync === 'object' && sync.error) {
            return String(sync.error).slice(0, 120);
        }
        return null;
    };

    let mailboxSubscribePromise = null;
    const ensureMailboxSubscribed = () => {
        if (mailboxSubscribePromise) { return mailboxSubscribePromise; }
        mailboxSubscribePromise = mailboxCmd('SUBSCRIBE', undefined, 'MAILBOX_TIMEOUT')
            .then((res) => {
                if (res && res.error) { mailboxSubscribePromise = null; }
                return res;
            }, (e) => {
                mailboxSubscribePromise = null;
                throw e;
            });
        return mailboxSubscribePromise;
    };

    const shapeProfileProxy = (res) => {
        let channel = null;
        const proxy = CryptPad_AsyncStore.proxy;
        const viewHash = proxy && proxy.profile && proxy.profile.view;
        if (typeof viewHash === 'string' && viewHash) {
            try {
                const secret = CryptPad_Hash.getSecrets('profile', viewHash);
                channel = (secret && typeof secret.channel === 'string')
                    ? secret.channel : null;
            } catch (e) { channel = null; }
        }
        const pick = (k) => (typeof res[k] === 'string') ? res[k] : null;
        return {
            name: pick('name'),
            description: pick('description'),
            url: pick('url'),
            avatar: pick('avatar'),
            edPublic: pick('edPublic'),
            curvePublic: pick('curvePublic'),
            proof: pick('proof'),
            channel: channel
        };
    };

    let profileReadyMemo = null;
    const profileBarrier = (timeoutMs) => {
        if (profileReadyMemo) return profileReadyMemo;
        const p = profileCmd('SUBSCRIBE', {}, 'PROFILE_TIMEOUT', timeoutMs)
            .then((res) => {
                if (res && res.error) {
                    if (profileReadyMemo === p) profileReadyMemo = null;
                }
                return res;
            }, (e) => {
                if (profileReadyMemo === p) profileReadyMemo = null;
                throw e;
            });
        profileReadyMemo = p;
        return p;
    };

    const shapedProfileReply = (res, what) => {
        if (res && typeof res === 'object' && typeof res.error === 'string') return res;
        if (!res || typeof res !== 'object') {
            return { error: 'PROFILE_TIMEOUT', errorType: what + ' returned a non-object reply' };
        }
        if (!profileReadyMemo) profileReadyMemo = Promise.resolve(res);
        return shapeProfileProxy(res);
    };

    const teamSlotsGate = async (list) => {
        const meta = await query('GET_METADATA', undefined);
        if (meta && typeof meta.error === 'string') return { error: meta.error };
        const plan = (meta && meta.priv && typeof meta.priv.plan === 'string') ? meta.priv.plan : '';
        const cfg = globalThis.__sp_AppConfig || {};
        const slotsCap = plan ? (Math.max(cfg.maxTeamsSlots || 0, cfg.maxPremiumTeamsSlots || 0) || 5)
                              : (cfg.maxTeamsSlots || 5);
        const teams = Object.values(list).filter((t) => t && t.error !== true);
        if (teams.length >= slotsCap) {
            return { error: 'TEAM_MAX_REACHED', errorType: 'slots=' + slotsCap };
        }
        return { plan: plan, cfg: cfg, teams: teams };
    };

    const driveEntriesReply = async (teamId) => {
        const res = await query('GET_DRIVE', { teamId: teamId });
        if (res && typeof res === 'object' && typeof res.error === 'string') return res;
        const proxy = (res && res.drive) || {};
        const filesData = proxy.filesData || {};
        const entries = [];
        for (const id of Object.keys(filesData)) {
            const f = filesData[id];
            if (!f || typeof f !== 'object') continue;
            const owners = Array.isArray(f.owners)
                ? f.owners.filter(function (o) { return typeof o === 'string'; })
                : null;
            entries.push({
                id: id,
                title: f.filename || f.title || '',
                href: f.href || f.roHref || '',
                channel: f.channel || '',
                owners: owners,
                atime: f.atime || 0,
                ctime: f.ctime || 0,
                password: (typeof f.password === 'string' && f.password.length > 0) ? f.password : null
            });
        }
        return { entries: entries };
    };

    if (typeof globalThis.XMLHttpRequest === 'undefined') {
        globalThis.XMLHttpRequest = function () {
            this.readyState = 4;
            this.DONE = 4;
            this.status = 0;
            this.open = function () {};
            this.setRequestHeader = function () {};
            this.abort = function () {};
            this.send = function () {
                if (typeof __sp_trace === 'function') {
                    __sp_trace('bootstrap', 'warn',
                        'inert XMLHttpRequest.send (headless stub) — telemetry-class XHR expected; investigate if a real consumer appears');
                }
                const self = this;
                setTimeout(function () {
                    if (typeof self.onreadystatechange === 'function') {
                        self.onreadystatechange.call(self);
                    }
                    if (typeof self.onerror === 'function') {
                        self.onerror.call(self, new Error('SwiftPad headless XHR stub: no networking'));
                    }
                }, 0);
            };
        };
    }

    if (typeof globalThis.fetch === 'undefined') {
        globalThis.fetch = function () {
            if (typeof __sp_trace === 'function') {
                __sp_trace('bootstrap', 'warn',
                    'inert fetch (headless stub) — broadcast/telemetry-class use expected; investigate if a load-bearing consumer appears');
            }
            return Promise.reject(new Error('SwiftPad headless fetch stub: no networking'));
        };
    }

    const defaultMessagesType = {
        pad:        'Pad',
        code:       'Code',
        sheet:      'Sheet',
        slide:      'Slide',
        form:       'Form',
        kanban:     'Kanban',
        whiteboard: 'Whiteboard',
        poll:       'Poll',
        diagram:    'Diagram',
        doc:        'Document',
        presentation: 'Presentation',
        file:       'File',
        drive:      'Drive'
    };

    const newPerfTracker = (opName) => {
        const t0 = Date.now();
        const stages = [];
        let cur = null;
        let curStart = 0;
        return {
            mark: function (name) {
                const now = Date.now();
                if (cur !== null) {
                    stages.push({ name: cur, ms: now - curStart });
                }
                cur = name;
                curStart = now;
            },
            flush: function () {
                if (cur !== null) {
                    stages.push({ name: cur, ms: Date.now() - curStart });
                    cur = null;
                }
                if (typeof __sp_trace !== 'function') return;
                try {
                    __sp_trace('bootstrap', 'debug',
                        'perf:' + JSON.stringify({
                            op: opName,
                            totalMs: Date.now() - t0,
                            stages: stages
                        }));
                } catch (e) {  }
            }
        };
    };

    let initialized = false;
    const initialize = (apiConfig, broadcast) => {
        if (initialized) return;
        initialized = true;
        const userMessages = globalThis.__sp_Messages || {};
        if (!userMessages.type) { userMessages.type = defaultMessagesType; }
        globalThis.__sp_apiConfig = apiConfig || {};
        store.init({
            AppConfig: globalThis.__sp_AppConfig || {},
            ApiConfig: apiConfig || {},
            Messages: userMessages,
            Broadcast: broadcast || {}
        });
    };

    const b64urlFromBytes = (bytes) => {
        let s = '';
        for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s).replace(/\//g, '-');
    };

    const bytesFromB64 = (b64) => {
        const s = atob(b64);
        const out = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
        return out;
    };

    const decomposeScryptBytes = (bytes) => {
        if (!nacl || !nacl.sign || !nacl.secretbox) {
            throw new Error('SwiftPad: tweetnacl not loaded');
        }
        if (bytes.length !== 192) {
            throw new Error('SwiftPad: scrypt output must be 192 bytes; got ' + bytes.length);
        }
        const legacyChannelHex = CryptPad_Util.uint8ArrayToHex(bytes.subarray(18, 34));
        let used = 18 + 16;
        const curveSeed = bytes.subarray(used, used + 32); used += 32;
        const edSeed    = bytes.subarray(used, used + 32); used += 32;
        const blockSeed = bytes.subarray(used, used + 64);
        const signKeys  = nacl.sign.keyPair.fromSeed(blockSeed.subarray(0, 32));
        const symmetric = blockSeed.subarray(32, 64);
        return {
            signKeys: signKeys,
            symmetric: symmetric,
            curveSeed: curveSeed,
            edSeed: edSeed,
            legacyChannelHex: legacyChannelHex
        };
    };


    const inviteDeriveSeeds = (safeSeed) => {
        const seed = String(safeSeed).replace(/-/g, '/');
        const u8 = nacl.hash(CryptPad_Util.decodeBase64(seed));
        return {
            scrypt: CryptPad_Util.encodeBase64(nacl.hash(u8.subarray(0, 32))),
            preview: CryptPad_Util.encodeBase64(nacl.hash(u8.subarray(32)))
        };
    };

    const inviteDeriveSalt = (password, instanceSalt) =>
        (password || '') + (instanceSalt || '');

    const inviteInstanceSalt = () =>
        (globalThis.__sp_AppConfig && globalThis.__sp_AppConfig.loginSalt) || '';

    const inviteDeriveBytes = (scryptSeed, salt) => {
        if (typeof __sp_scrypt !== 'function') {
            return Promise.reject(new Error('SwiftPad: __sp_scrypt shim not installed'));
        }
        return __sp_scrypt(scryptSeed, salt);
    };

    const parseInviteFragment = (fragment) => {
        const parsed = CryptPad_Hash.parseTypeHash('invite', fragment);
        if (!parsed || parsed.version !== 2 || parsed.app !== 'invite' ||
            parsed.mode !== 'edit' || typeof parsed.key !== 'string' || !parsed.key) {
            return null;
        }
        if (!/^[A-Za-z0-9+-]{24}$/.test(parsed.key)) {
            return null;
        }
        return parsed;
    };

    let inviteDeriveQueue = Promise.resolve();
    const inviteDeriveBytesSerial = (scryptSeed, salt) => {
        const run = inviteDeriveQueue.then(() => inviteDeriveBytes(scryptSeed, salt));
        inviteDeriveQueue = run.then(() => undefined, () => undefined);
        return run;
    };

    const stdB64FromBytes = (bytes) => {
        let s = '';
        for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
        return btoa(s);
    };

    const authError = (code, extra) => {
        const payload = { code: code };
        if (extra) Object.assign(payload, extra);
        return new Error(JSON.stringify(payload));
    };

    const BEARER_SHAPE = /^[A-Za-z0-9+-]{32}$/;
    const isWellFormedBearer = (b) => typeof b === 'string' && BEARER_SHAPE.test(b);

    const resolveTotp401 = async (resp, blockUrl, authOrigin, derived, _p, options, bearerSent) => {
        let body401 = null;
        try {
            body401 = JSON.parse(CryptPad_Util.encodeUTF8(bytesFromB64(resp.bodyBase64)));
        } catch (_) {
        }
        if (!body401 || typeof body401 !== 'object') {
            throw authError('BLOCK_FETCH_FAILED', { httpStatus: resp.status });
        }
        if (body401.sso === true) {
            throw authError('SSO_UNSUPPORTED');
        }
        if (body401.method !== 'TOTP') {
            throw authError('BLOCK_FETCH_FAILED', { httpStatus: resp.status });
        }
        if (!options || !options.totpCode) {
            const sentinel = { totpRequired: true };
            if (bearerSent === true) { sentinel.bearerRejected = true; }
            return { sentinel: sentinel };
        }
        _p.mark('totp-validate');
        let r2;
        for (let attempt = 0; attempt < 2 && r2 === undefined; attempt++) {
            try {
                r2 = await _serverCommand(authOrigin, {
                    publicKey: stdB64FromBytes(derived.signKeys.publicKey),
                    secretKey: derived.signKeys.secretKey
                }, {
                    command: 'TOTP_VALIDATE',
                    code: options.totpCode,
                    session: ''
                });
            } catch (e) {
                const errBody = (e && e.spBody && typeof e.spBody === 'object') ? e.spBody : null;
                const errCode = errBody ? errBody.error : null;
                if (errCode === 'INVALID_OTP' || errCode === 'E_INVALID') {
                    throw authError('TOTP_INVALID');
                }
                let detail = String((e && e.message) ? e.message : e).slice(0, 200);
                if (errBody) {
                    if (errBody.error !== undefined) {
                        detail += ' error=' + String(errBody.error).slice(0, 200);
                    }
                    if (errBody.errorCode !== undefined) {
                        detail += ' errorCode=' + String(errBody.errorCode).slice(0, 200);
                    }
                }
                if (attempt >= 1) {
                    throw authError('TOTP_VALIDATE_FAILED', { detail: detail });
                }
                __sp_trace('bootstrap', 'debug', 'TOTP_VALIDATE attempt 0 failed, retrying: ' + detail);
            }
        }
        if (r2 === undefined) {
            throw authError('TOTP_VALIDATE_FAILED', { detail: 'validate loop exit without result' });
        }
        const bearer = r2.bearer;
        if (!isWellFormedBearer(bearer)) {
            throw authError('TOTP_VALIDATE_FAILED', { detail: 'step2 bearer malformed' });
        }
        _p.mark('block-refetch');
        resp = await __sp_http.get(blockUrl, { Authorization: 'Bearer ' + bearer });
        if (resp.status !== 200) {
            throw authError('TOTP_VALIDATE_FAILED', { detail: 'block re-fetch status ' + resp.status });
        }
        return { resp: resp, bearer: bearer };
    };

    const blockUrlFor = (apiConfig, blockPub) => {
        const origin = String(apiConfig.fileHost || apiConfig.httpUnsafeOrigin || '').replace(/\/$/, '');
        return origin + '/block/' + blockPub.slice(0, 2) + '/' + blockPub;
    };

    const performSignInWithDerived = async (derived, apiConfig, _p, options) => {
        _p.mark('block-fetch');
        const blockPub = b64urlFromBytes(derived.signKeys.publicKey);
        const blockUrl = blockUrlFor(apiConfig, blockPub);
        let cachedBearer = (options && options.bearer !== undefined && options.bearer !== null) ? options.bearer : null;
        if (cachedBearer !== null && !isWellFormedBearer(cachedBearer)) {
            const len = (typeof cachedBearer === 'string') ? cachedBearer.length : -1;
            __sp_trace('bootstrap', 'warn', 'cached bearer malformed (length ' + len + ') — fetching without it');
            cachedBearer = null;
        }
        let resp = cachedBearer !== null
            ? await __sp_http.get(blockUrl, { Authorization: 'Bearer ' + cachedBearer })
            : await __sp_http.get(blockUrl);
        if (resp.status === 404) {
            throw authError('BLOCK_NOT_FOUND');
        }
        let mintedBearer = null;
        if (resp.status === 401) {
            const gate = await resolveTotp401(resp, blockUrl, _authApiOrigin(apiConfig), derived, _p, options, cachedBearer !== null);
            if (gate.sentinel) { return gate.sentinel; }
            resp = gate.resp;
            mintedBearer = gate.bearer || null;
        }
        if (resp.status !== 200) {
            throw authError('BLOCK_FETCH_FAILED', { httpStatus: resp.status });
        }
        _p.mark('secretbox-open');
        const encrypted = bytesFromB64(resp.bodyBase64);
        const nonceLen = nacl.secretbox.nonceLength;
        const nonce = encrypted.subarray(1, 1 + nonceLen);
        const box = encrypted.subarray(1 + nonceLen);
        const plain = nacl.secretbox.open(box, nonce, derived.symmetric);
        if (!plain) throw authError('BLOCK_DECRYPT_FAILED');
        const blockInfo = JSON.parse(CryptPad_Util.encodeUTF8(plain));

        const cfg = {
            init: true,
            userHash: blockInfo.User_hash,
            blockHash: blockUrl + '#' + b64urlFromBytes(derived.symmetric),
            blockId: blockPub,
            driveEvents: true
        };
        _p.mark('connect-query');
        const result = await query('CONNECT', cfg, { timeout: 120000 });
        const out = {
            loggedIn: !!(result && result.loggedIn),
            edPublic: result && result.edPublic
        };
        if (mintedBearer !== null) { out.bearer = mintedBearer; }
        return out;
    };

    const signInWithCachedKeys = async (scryptBytesB64, apiConfig, broadcast, options) => {
        const _p = newPerfTracker('signInWithCachedKeys');
        try {
            _p.mark('initialize');
            initialize(apiConfig, broadcast);
            _p.mark('decompose-cached');
            const bytes = bytesFromB64(scryptBytesB64);
            const derived = decomposeScryptBytes(bytes);
            return await performSignInWithDerived(derived, apiConfig, _p, options);
        } finally {
            _p.flush();
        }
    };


    const channelKeysFromSecret = (secret) => {
        const k = secret.keys;
        return {
            cryptKey: (k.cryptKey instanceof Uint8Array) ? k.cryptKey : CryptPad_Util.decodeBase64(k.cryptKey),
            signKey: (k.signKey instanceof Uint8Array) ? k.signKey : CryptPad_Util.decodeBase64(k.signKey),
            validateKeyB64: (typeof k.validateKey === 'string') ? k.validateKey : CryptPad_Util.encodeBase64(k.validateKey)
        };
    };

    const makeChannelEncryptor = (keys) => (msg) => {
        const nonce = nacl.randomBytes(24);
        const packed = nacl.secretbox(CryptPad_Util.decodeUTF8(msg), nonce, keys.cryptKey);
        const inner = CryptPad_Util.encodeBase64(nonce) + '|' + CryptPad_Util.encodeBase64(packed);
        return CryptPad_Util.encodeBase64(nacl.sign(CryptPad_Util.decodeUTF8(inner), keys.signKey));
    };

    const chainpadInitialPatch = (initialState) => {
        const cp = ChainPad.create({
            initialState: initialState,
            userName: 'swiftpad-init'
        });
        const initMsg = cp._ && cp._.setContentPatch;
        if (!initMsg) {
            throw new Error('SwiftPad: ChainPad.create produced no setContentPatch');
        }
        return ChainPad.Message.toStr(initMsg);
    };

    const chainpadFollowUpPatch = (initialState, initialPatch, nextState) => {
        const cp = ChainPad.create({
            initialState: initialState,
            userName: 'swiftpad-init'
        });
        let emitted = null;
        cp.onMessage(function (msg) {
            if (emitted === null) emitted = msg;
        });
        cp.message(initialPatch);
        cp.contentUpdate(nextState);
        cp.sync();
        if (typeof emitted !== 'string') {
            throw new Error('SwiftPad: ChainPad emitted no follow-up patch');
        }
        return emitted;
    };

    const SEED_STATE_TIMEOUT_MS = 5000;

    const seedChannel = async ({ network, channel, keys, metadata, patches, strict, _p, label }) => {
        const encrypt = makeChannelEncryptor(keys);
        const hk = network && network.historyKeeper;
        if (!network || !hk) {
            throw new Error('SwiftPad: ' + label + ': no network or historyKeeper');
        }
        if (_p) _p.mark(label + '/network.join');
        const wc = await network.join(channel);
        try {
            const ourTxid = mkTxid();
            const getHistoryMsg = ['GET_HISTORY', wc.id, {
                metadata: metadata,
                txid: ourTxid,
                lastKnownHash: 0
            }];
            let stateMsgHandler = null;
            const stateReady = new Promise(function (resolve) {
                stateMsgHandler = function (content, sender) {
                    if (sender !== hk) return;
                    let parsed;
                    try { parsed = JSON.parse(content); } catch (e) { return; }
                    if (parsed && parsed.state === 1 &&
                        parsed.channel === wc.id &&
                        parsed.txid === ourTxid) {
                        resolve(true);
                    }
                };
                network.on('message', stateMsgHandler);
            });
            try {
                if (_p) _p.mark(label + '/network.sendto');
                network.sendto(hk, JSON.stringify(getHistoryMsg));
                if (_p) _p.mark(label + '/wait-state1');
                let stateReadyOk = false;
                await Promise.race([
                    stateReady.then(function () { stateReadyOk = true; }),
                    sleep(SEED_STATE_TIMEOUT_MS)
                ]);
                if (!stateReadyOk) {
                    if (strict) {
                        throw new Error('SwiftPad: ' + label + ': no state:1 within ' + SEED_STATE_TIMEOUT_MS + ' ms');
                    }
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn', label + ': state:1 fallback fired (' + SEED_STATE_TIMEOUT_MS + ' ms timeout)');
                    }
                }
            } finally {
                if (stateMsgHandler && typeof network.off === 'function') {
                    try { network.off('message', stateMsgHandler); } catch (e) {  }
                }
            }
            for (let i = 0; i < patches.length; i++) {
                if (_p) _p.mark(label + '/wc.bcast');
                try {
                    await wc.bcast(encrypt(patches[i]));
                } catch (bcastErr) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn',
                            label + ': wc.bcast rejected: ' + (bcastErr && bcastErr.type || JSON.stringify(bcastErr)));
                    }
                    throw new Error('SwiftPad: chainpad-init bcast failed: ' + (bcastErr && bcastErr.type || 'unknown'));
                }
            }
        } finally {
            if (_p) _p.mark(label + '/wc.leave');
            try { wc.leave(); } catch (e) {  }
        }
    };

    const SIGNUP_HK_WAIT_MS = 10000;
    const SIGNUP_LEGACY_CHECK_MS = 10000;

    const waitForHistoryKeeper = async () => {
        const store = CryptPad_AsyncStore;
        if (!store.network && !store.networkPromise) {
            throw new Error('SwiftPad: signUp: noDrive CONNECT left no network');
        }
        const network = store.network || await store.networkPromise;
        const deadline = Date.now() + SIGNUP_HK_WAIT_MS;
        while (!network.historyKeeper) {
            if (Date.now() > deadline) {
                throw new Error('SwiftPad: signUp: historyKeeper not known within ' + SIGNUP_HK_WAIT_MS + ' ms');
            }
            await sleep(20);
        }
        return network;
    };

    const legacyChannelHasHistory = async (network, channelHex) => {
        const hk = network.historyKeeper;
        const ourTxid = mkTxid();
        const replay = setupReplay({
            network, hk, channel: channelHex, cp: null, ourTxid,
            cryptKey: null, validateKeyB64: undefined, validateKeyBytes: null,
            lastKnownHash: 0
        });
        let timeoutId = null;
        const timeout = new Promise((_, rej) => {
            timeoutId = setTimeout(() => rej(new Error('timeout (' + SIGNUP_LEGACY_CHECK_MS + ' ms)')), SIGNUP_LEGACY_CHECK_MS);
        });
        network.on('message', replay.listener);
        try {
            replay.sendGetHistory();
            await Promise.race([replay.readyPromise, timeout]);
        } catch (e) {
            throw authError('LEGACY_CHECK_FAILED', { detail: String((e && e.message) ? e.message : e).slice(0, 200) });
        } finally {
            if (timeoutId) clearTimeout(timeoutId);
            if (typeof network.off === 'function') {
                try { network.off('message', replay.listener); } catch (_) {  }
            }
        }
        return replay.counters.seen > 0;
    };

    const serializeLoginBlock = (contentJSON, derived) => {
        const nonce = nacl.randomBytes(nacl.secretbox.nonceLength);
        const box = nacl.secretbox(CryptPad_Util.decodeUTF8(contentJSON), nonce, derived.symmetric);
        const ciphertext = new Uint8Array(1 + nonce.length + box.length);
        ciphertext[0] = 0;
        ciphertext.set(nonce, 1);
        ciphertext.set(box, 1 + nonce.length);
        const signature = nacl.sign.detached(nacl.hash(ciphertext), derived.signKeys.secretKey);
        return {
            publicKey: CryptPad_Util.encodeBase64(derived.signKeys.publicKey),
            signature: CryptPad_Util.encodeBase64(signature),
            ciphertext: CryptPad_Util.encodeBase64(ciphertext)
        };
    };

    const sortedJSON = (obj) => {
        const out = {};
        Object.keys(obj).sort().forEach((k) => { out[k] = obj[k]; });
        return JSON.stringify(out);
    };

    const authErrorCode = (e) => {
        try {
            const parsed = JSON.parse(e && e.message);
            return (parsed && typeof parsed.code === 'string') ? parsed.code : null;
        } catch (_) { return null; }
    };

    const blockSignKeyPair = (derived) => ({
        publicKey: stdB64FromBytes(derived.signKeys.publicKey),
        secretKey: derived.signKeys.secretKey
    });

    const signUp = async (scryptBytesB64, apiConfig, broadcast, options) => {
        const username = options && options.username;
        if (typeof username !== 'string' || !username) {
            throw new Error('SwiftPad: signUp requires options.username');
        }
        const _p = newPerfTracker('signUp');
        try {
            _p.mark('initialize');
            initialize(apiConfig, broadcast);
            _p.mark('connect-nodrive');
            const connected = await query('CONNECT', { init: true, noDrive: true });
            if (connected && typeof connected === 'object' && typeof connected.error === 'string') {
                throw authError('DRIVE_SEED_FAILED', { detail: 'noDrive CONNECT: ' + connected.error.slice(0, 200) });
            }
            const network = await waitForHistoryKeeper();

            _p.mark('decompose');
            const derived = decomposeScryptBytes(bytesFromB64(scryptBytesB64));

            _p.mark('block-probe');
            const blockPub = b64urlFromBytes(derived.signKeys.publicKey);
            const probe = await __sp_http.get(blockUrlFor(apiConfig, blockPub));
            if (probe.status === 200 || probe.status === 401) {
                throw authError('ALREADY_REGISTERED');
            }
            if (probe.status !== 404) {
                throw authError('BLOCK_FETCH_FAILED', { httpStatus: probe.status });
            }
            let body404 = null;
            try {
                body404 = JSON.parse(CryptPad_Util.encodeUTF8(bytesFromB64(probe.bodyBase64)).slice(0, 4096));
            } catch (_) {
            }
            if (body404 && typeof body404 === 'object' && typeof body404.reason === 'string') {
                throw authError('DELETED_USER', { reason: body404.reason.slice(0, 200) });
            }

            _p.mark('legacy-check');
            if (await legacyChannelHasHistory(network, derived.legacyChannelHex)) {
                throw authError('ALREADY_REGISTERED');
            }

            _p.mark('mint');
            const edKp = nacl.sign.keyPair();
            const curveKp = nacl.box.keyPair();
            const edPublic = CryptPad_Util.encodeBase64(edKp.publicKey);
            const userHash = CryptPad_Hash.createRandomHash('drive');
            const secret = CryptPad_Hash.getSecrets('drive', userHash);
            const keys = channelKeysFromSecret(secret);
            const doc = sortedJSON({
                edPublic: edPublic,
                edPrivate: CryptPad_Util.encodeBase64(edKp.secretKey),
                curvePublic: CryptPad_Util.encodeBase64(curveKp.publicKey),
                curvePrivate: CryptPad_Util.encodeBase64(curveKp.secretKey),
                login_name: username,
                'cryptpad.username': username,
                version: 11
            });

            _p.mark('seed-drive');
            const patch1 = chainpadInitialPatch('{}');
            const patch2 = chainpadFollowUpPatch('{}', patch1, doc);
            try {
                await seedChannel({
                    network: network,
                    channel: secret.channel,
                    keys: keys,
                    metadata: { owners: [edPublic], validateKey: keys.validateKeyB64 },
                    patches: [patch1, patch2],
                    strict: true,
                    _p: _p,
                    label: 'signUp'
                });
            } catch (e) {
                throw authError('DRIVE_SEED_FAILED', { detail: String((e && e.message) ? e.message : e).slice(0, 200) });
            }

            _p.mark('write-block');
            const content = serializeLoginBlock(JSON.stringify({ User_hash: userHash, edPublic: edPublic }), derived);
            content.hasPassword = true;
            try {
                await _serverCommand(_authApiOrigin(apiConfig), blockSignKeyPair(derived), {
                    command: 'WRITE_BLOCK',
                    content: content
                });
            } catch (e) {
                const errBody = (e && e.spBody && typeof e.spBody === 'object') ? e.spBody : null;
                const code = errBody ? (errBody.errorCode !== undefined ? errBody.errorCode : errBody.error) : undefined;
                if (code === 'E_RESTRICTED') {
                    throw authError('REGISTRATION_CLOSED');
                }
                let detail = String((e && e.message) ? e.message : e).slice(0, 200);
                if (code !== undefined) detail += ' error=' + String(code).slice(0, 200);
                throw authError('BLOCK_WRITE_FAILED', { detail: detail });
            }

            let result;
            try {
                result = await performSignInWithDerived(derived, apiConfig, _p, {});
            } catch (e) {
                if (authErrorCode(e) === 'BLOCK_NOT_FOUND') {
                    throw authError('BLOCK_WRITE_FAILED', { detail: 'block missing after write' });
                }
                throw e;
            }
            return result;
        } finally {
            _p.flush();
        }
    };

    const channelToHref = async (channel) => {
        const res = await query('GET_DRIVE', { teamId: undefined });
        if (res && typeof res === 'object' && typeof res.error === 'string') return null;
        const proxy = (res && res.drive) || {};
        const filesData = proxy.filesData || {};
        for (const id of Object.keys(filesData)) {
            const f = filesData[id];
            if (f && typeof f === 'object' && f.channel === channel) {
                return f.href || f.roHref || null;
            }
        }
        return null;
    };

    const _streamHandles = Object.create(null);
    let _nextStreamHandleId = 1;
    const FILE_CIPHERTEXT_CHUNK_SIZE = 131088;
    const FILE_BATCH_CHUNKS_PER_NEXT = 8;
    const FILE_METADATA_MAX = 65535;

    const _fileCryptoIncrement = (n) => {
        if (n.length === 0) { throw new Error('E_EMPTY_NONCE'); }
        let l = n.length;
        while (l-- > 0) {
            if (n[l] !== 255) { n[l] = (n[l] + 1) | 0; return; }
            n[l] = 0;
        }
        throw new Error('E_NONCE_TOO_LARGE');
    };

    const _streamReadAtLeast = async (h, want) => {
        while (h.bufferedLen < want && !h.sourceEof) {
            const next = await h.httpStream.next();
            if (next === null) {
                h.sourceEof = true;
                break;
            }
            const bytes = CryptPad_Util.decodeBase64(next);
            h.buffered.push(bytes);
            h.bufferedLen += bytes.length;
        }
    };

    const _streamConsume = (h, n) => {
        const out = new Uint8Array(n);
        let got = 0;
        while (got < n) {
            const head = h.buffered[0];
            const need = n - got;
            if (head.length <= need) {
                out.set(head, got);
                got += head.length;
                h.buffered.shift();
            } else {
                out.set(head.subarray(0, need), got);
                h.buffered[0] = head.subarray(need);
                got += need;
            }
        }
        h.bufferedLen -= n;
        return out;
    };

    const _uploadHandles = Object.create(null);
    let _nextUploadHandleId = 1;
    const FILE_PLAIN_CHUNK_SIZE = 131072;
    const FILE_UPLOAD_BATCH_MAX = 4;

    const _fileCryptoEncryptChunk = (chunkBytes, nonce, key) => {
        return nacl.secretbox(chunkBytes, nonce, key);
    };

    const _fileCryptoEncodePrefix = (n) => {
        return new Uint8Array([(n >>> 8) & 0xff, n & 0xff]);
    };

    const _fileCryptoConcat2 = (a, b) => {
        const out = new Uint8Array(a.length + b.length);
        out.set(a, 0);
        out.set(b, a.length);
        return out;
    };

    const _authApiOrigin = (apiConfig) => {
        const fallback = String((apiConfig && apiConfig.httpUnsafeOrigin) || '').replace(/\/$/, '');
        const wsPath = apiConfig ? apiConfig.websocketPath : undefined;
        if (typeof wsPath !== 'string') { return fallback; }
        const m = /^(ws{1,2}):\/\/([^\/?#]+)/.exec(wsPath);
        if (!m) { return fallback; }
        if (m[2].indexOf('@') !== -1) {
            throw new Error('websocketPath authority contains userinfo — refused (Swift pre-check bypassed)');
        }
        return (m[1] === 'wss' ? 'https' : 'http') + '://' + m[2];
    };

    const _serverCommand = async (apiOrigin, signKeyPair, bodyObj) => {
        const cmd = bodyObj.command;
        const url = apiOrigin + '/api/auth/';
        const postStep = async (step, obj) => {
            const raw = await __sp_http.post(url, JSON.stringify(obj));
            let parsed = null;
            try {
                parsed = JSON.parse(CryptPad_Util.encodeUTF8(CryptPad_Util.decodeBase64(raw.bodyBase64)));
            } catch (_) {
            }
            if (raw.status < 200 || raw.status >= 300) {
                const err = new Error(cmd + ' ' + step + ' status ' + raw.status);
                err.spStatus = raw.status;
                err.spBody = parsed;
                throw err;
            }
            if (raw.bodyBase64 === '') {
                return {};
            }
            if (parsed === null || typeof parsed !== 'object') {
                throw new Error(cmd + ' ' + step + ' not JSON');
            }
            return parsed;
        };
        const baseObj = Object.assign({}, bodyObj, {
            publicKey: signKeyPair.publicKey,
            nonce: CryptPad_Util.encodeBase64(nacl.randomBytes(24))
        });
        const r1 = await postStep('step1', baseObj);
        if (!r1.txid || !r1.date) {
            throw new Error(cmd + ' step1 missing txid/date');
        }
        const signedObj = Object.assign({}, baseObj, { txid: r1.txid, date: r1.date });
        const toSign = CryptPad_Util.decodeUTF8(JSON.stringify(signedObj));
        const sig = nacl.sign.detached(toSign, signKeyPair.secretKey);
        return postStep('step2', {
            sig: CryptPad_Util.encodeBase64(sig),
            txid: r1.txid
        });
    };

    const _uploadChunkPost = async (fileHost, channel, ciphertext, currentCookie, edPublic, secretKey) => {
        const signedMsg = nacl.sign(CryptPad_Util.decodeUTF8(currentCookie), secretKey);
        const url = fileHost + '/upload-blob/' + channel.slice(0, 2) + '/' + channel;
        const body = JSON.stringify({
            chunk: CryptPad_Util.encodeBase64(ciphertext),
            sig: CryptPad_Util.encodeBase64(signedMsg),
            edPublic: edPublic
        });
        const respRaw = await __sp_http.post(url, body);
        if (respRaw.status < 200 || respRaw.status >= 300) {
            throw new Error('upload-blob status ' + respRaw.status);
        }
        let resp;
        try {
            const jsonText = CryptPad_Util.encodeUTF8(CryptPad_Util.decodeBase64(respRaw.bodyBase64));
            resp = JSON.parse(jsonText);
        } catch (_) {
            throw new Error('upload-blob response not JSON');
        }
        if (resp.error) {
            throw new Error('upload-blob error: ' + resp.error);
        }
        if (!resp.cookie) {
            throw new Error('upload-blob response missing cookie');
        }
        return resp.cookie;
    };

    globalThis.__swiftpad = {
        initialize: initialize,

        rpc: (command, payload) => {
            if (typeof command !== 'string' || !command.length) {
                return Promise.reject(new Error('SwiftPad: rpc requires a string command'));
            }
            if (payload === undefined || payload === null) {
                return Promise.reject(new Error('SwiftPad: rpc requires an explicit payload (pass {} for none)'));
            }
            return query(command, payload);
        },

        anonymous: async (apiConfig, broadcast) => {
            initialize(apiConfig, broadcast);
            return query('CONNECT', { init: true, driveEvents: true }, { timeout: 120000 });
        },

        signInWithCachedKeys: signInWithCachedKeys,

        signUp: signUp,

        getSignUpRules: () => {
            const cfg = globalThis.__sp_AppConfig || {};
            const minimum = (typeof cfg.minimumPasswordLength === 'number') ? cfg.minimumPasswordLength : 8;
            return { minimumPasswordLength: minimum };
        },

        getLoginSalt: () => {
            const salt = (globalThis.__sp_AppConfig && globalThis.__sp_AppConfig.loginSalt) || '';
            return { loginSalt: String(salt) };
        },

        getPadMetadata: async (channel) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: getPadMetadata requires a channel id');
            }
            const res = await query('GET_PAD_METADATA', { channel: channel });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { channel: channel, metadata: res };
        },

        createPad: async (title, type) => {
            const INITIAL_BY_TYPE = {
                pad: ["BODY", { "contenteditable": "true" }, [["P", {}, [["BR", {}, []]]]], { "metadata": { "type": "pad" } }],
                code: { content: "", highlightMode: "gfm", authormarks: [] },
                slide: { content: "" },
                whiteboard: { content: { version: "4.6.0", objects: [] } }
            };
            const _p = newPerfTracker('createPad');
            try {
                _p.mark('hash-prep');
                const padType = type || 'pad';
                if (!Object.prototype.hasOwnProperty.call(INITIAL_BY_TYPE, padType)) {
                    return { error: 'UNSEEDED_PAD_TYPE',
                             errorType: 'createPad has no initial document for type ' + String(padType).slice(0, 32)
                                        + ' (seeded: ' + Object.keys(INITIAL_BY_TYPE).join(', ') + ')' };
                }
                const seed = nacl.randomBytes(18);
                let keyStr = '';
                for (let i = 0; i < seed.length; i++) keyStr += String.fromCharCode(seed[i]);
                keyStr = btoa(keyStr).replace(/\//g, '-');
                const href = '/' + padType + '/#/2/' + padType + '/edit/' + keyStr + '/';
                const hashStr = '/2/' + padType + '/edit/' + keyStr + '/';
                _p.mark('ADD_PAD');
                const addRes = await query('ADD_PAD', {
                    href: href,
                    title: title || 'Untitled',
                    path: ['root']
                });
                if (addRes && typeof addRes === 'object' && typeof addRes.error === 'string') return addRes;

                let channel;
                try {
                    _p.mark('chainpad-init/prep');
                    const secret = CryptPad_Hash.getSecrets(padType, hashStr);
                    channel = secret.channel;
                    const keys = channelKeysFromSecret(secret);

                    const proxy = CryptPad_AsyncStore.proxy;
                    const edPublic = proxy.edPublic;
                    const mailboxToken = makeChannelEncryptor(keys)(JSON.stringify({
                        notifications: proxy.mailboxes && proxy.mailboxes.notifications && proxy.mailboxes.notifications.channel,
                        curvePublic: proxy.curvePublic
                    }));
                    const metadata = {
                        owners: [edPublic],
                        mailbox: {},
                        validateKey: keys.validateKeyB64
                    };
                    metadata.mailbox[edPublic] = mailboxToken;

                    await seedChannel({
                        network: CryptPad_AsyncStore.network,
                        channel: channel,
                        keys: keys,
                        metadata: metadata,
                        patches: [chainpadInitialPatch(JSON.stringify(INITIAL_BY_TYPE[padType]))],
                        strict: false,
                        _p: _p,
                        label: 'createPad'
                    });
                } catch (e) {
                    try { await query('MOVE_TO_TRASH', { href: href }); }
                    catch (rollbackErr) {  }
                    throw e;
                }
                return { href: href, title: title || 'Untitled', type: padType, channel: channel };
            } finally {
                _p.flush();
            }
        },

        deletePad: async (channel) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: deletePad requires a channel id');
            }
            const href = await channelToHref(channel);
            if (!href) { return { error: 'ENOENT' }; }
            const res = await query('MOVE_TO_TRASH', { href: href });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        destroyPad: async (channel) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: destroyPad requires a channel id');
            }
            const res = await query('REMOVE_OWNED_CHANNEL', channel);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        pinPads: async (channels) => {
            if (!Array.isArray(channels)) {
                throw new Error('SwiftPad: pinPads requires an array of channel ids');
            }
            const res = await query('PIN_PADS', channels);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        unpinPads: async (channels) => {
            if (!Array.isArray(channels)) {
                throw new Error('SwiftPad: unpinPads requires an array of channel ids');
            }
            const res = await query('UNPIN_PADS', channels);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        setPadTitle: async (channel, title) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: setPadTitle requires a channel id');
            }
            if (typeof title !== 'string') {
                throw new Error('SwiftPad: setPadTitle requires a title string');
            }
            const href = await channelToHref(channel);
            if (!href) { return { error: 'ENOENT' }; }
            const res = await query('SET_PAD_TITLE', {
                href: href,
                channel: channel,
                title: title
            });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            if (res && typeof res === 'object' && res.notStored) {
                return { error: 'NOT_STORED' };
            }
            return { ok: true };
        },

        getDriveTree: async () => {
            const res = await query('GET_DRIVE', { teamId: undefined });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            const proxy = (res && res.drive) || {};
            const filesData = proxy.filesData || {};

            const toEntry = (id, f) => {
                if (!f || typeof f !== 'object') return null;
                const owners = Array.isArray(f.owners)
                    ? f.owners.filter(function (o) { return typeof o === 'string'; })
                    : null;
                return {
                    id: String(id),
                    title: f.filename || f.title || '',
                    href: f.href || f.roHref || '',
                    channel: f.channel || '',
                    owners: owners,
                    atime: f.atime || 0,
                    ctime: f.ctime || 0,
                    password: (typeof f.password === 'string' && f.password.length > 0) ? f.password : null
                };
            };
            const entryById = (id) => {
                const f = filesData[id];
                return f ? toEntry(id, f) : null;
            };
            const isFolderData = (v) => v && typeof v === 'object' && v.metadata === true;
            const isFileId = (v) => typeof v === 'number';

            const NODE_CAP = 50000;
            const counter = { n: 0 };
            const expandFolder = (name, obj, depth) => {
                if (depth > 64) {
                    throw new Error('SwiftPad: drive tree depth > 64 (DRIVE_DECODE_DEPTH)');
                }
                const entries = [];
                const folders = [];
                for (const key of Object.keys(obj || {})) {
                    if (++counter.n > NODE_CAP) {
                        throw new Error('SwiftPad: drive tree node count > ' + NODE_CAP + ' (DRIVE_DECODE_TOO_LARGE)');
                    }
                    const v = obj[key];
                    if (isFolderData(v)) continue;
                    if (isFileId(v)) {
                        const e = entryById(v);
                        if (e) entries.push(e);
                        continue;
                    }
                    if (v && typeof v === 'object' && !v.channel) {
                        folders.push(expandFolder(key, v, depth + 1));
                        continue;
                    }
                }
                return { name: name, entries: entries, folders: folders };
            };

            const expandTrash = (trashObj) => {
                const out = [];
                for (const name of Object.keys(trashObj || {})) {
                    const arr = trashObj[name];
                    if (!Array.isArray(arr)) continue;
                    const entries = [];
                    for (const item of arr) {
                        if (!item || typeof item !== 'object') continue;
                        const el = item.element;
                        if (isFileId(el)) {
                            const e = entryById(el);
                            if (e) entries.push(e);
                        }
                    }
                    out.push({ name: name, entries: entries });
                }
                return out;
            };

            try {
                const root = expandFolder('', proxy.root || {}, 0);
                const trash = expandTrash(proxy.trash || {});
                const templates = (Array.isArray(proxy.template) ? proxy.template : [])
                    .map(entryById)
                    .filter(function (e) { return !!e; });
                const filesDataArr = Object.keys(filesData)
                    .map(function (id) { return toEntry(id, filesData[id]); })
                    .filter(function (e) { return !!e; });
                return {
                    root: root,
                    trash: trash,
                    template: templates,
                    filesData: filesDataArr
                };
            } catch (e) {
                if (e && typeof e.message === 'string') {
                    if (e.message.indexOf('DRIVE_DECODE_DEPTH') !== -1) {
                        return { error: 'DRIVE_DECODE_DEPTH' };
                    }
                    if (e.message.indexOf('DRIVE_DECODE_TOO_LARGE') !== -1) {
                        return { error: 'DRIVE_DECODE_TOO_LARGE' };
                    }
                }
                throw e;
            }
        },

        movePad: async (channel, toPath) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: movePad requires a channel id');
            }
            if (!Array.isArray(toPath)) {
                throw new Error('SwiftPad: movePad requires toPath as a string array');
            }
            const driveRes = await query('GET_DRIVE', { teamId: undefined });
            if (driveRes && typeof driveRes === 'object' && typeof driveRes.error === 'string') return driveRes;
            const proxy = (driveRes && driveRes.drive) || {};
            const filesData = proxy.filesData || {};

            let targetId = null;
            for (const id of Object.keys(filesData)) {
                const f = filesData[id];
                if (f && f.channel === channel) {
                    targetId = Number(id);
                    break;
                }
            }
            if (targetId === null || isNaN(targetId)) {
                return { error: 'ENOENT' };
            }
            const RESERVED_KEYS = {
                root: 1, trash: 1, template: 1,
                sharedFolders: 1, sharedFoldersTemp: 1,
                filesData: 1, CryptPad_RECENTPADS: 1,
                metadata: 1
            };
            const findPathToId = (folderObj, target, depth) => {
                if (depth > 64) return null;
                for (const key of Object.keys(folderObj || {})) {
                    if (RESERVED_KEYS[key]) continue;
                    const v = folderObj[key];
                    if (typeof v === 'number' && v === target) {
                        return [key];
                    }
                    if (v && typeof v === 'object' && !v.channel && v.metadata !== true) {
                        const sub = findPathToId(v, target, depth + 1);
                        if (sub) return [key].concat(sub);
                    }
                }
                return null;
            };
            const subPath = findPathToId(proxy.root || {}, targetId, 0);
            if (!subPath) {
                return { error: 'ENOENT' };
            }
            const fromPath = ['root'].concat(subPath);
            const res = await query('DRIVE_USEROBJECT', {
                cmd: 'move',
                data: {
                    paths: [fromPath],
                    newPath: toPath,
                    copy: false
                }
            });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        getPadAttribute: async (channel, attr) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: getPadAttribute requires a channel id');
            }
            if (typeof attr !== 'string' || !attr.length) {
                return { error: 'E_INVAL_ATTR' };
            }
            const href = await channelToHref(channel);
            if (!href) { return { error: 'ENOENT' }; }
            const res = await query('GET_PAD_ATTRIBUTE', { href: href, attr: attr });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            let value = (res === undefined || res === null) ? null : res;
            if (value !== null && typeof value !== 'string') {
                value = String(value);
            }
            return { value: value };
        },

        setPadAttribute: async (channel, attr, value) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: setPadAttribute requires a channel id');
            }
            if (typeof attr !== 'string' || !attr.length) {
                return { error: 'E_INVAL_ATTR' };
            }
            const href = await channelToHref(channel);
            if (!href) { return { error: 'ENOENT' }; }
            const payload = { href: href, attr: attr };
            if (value !== null && value !== undefined) { payload.value = value; }
            const res = await query('SET_PAD_ATTRIBUTE', payload);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        getPadAttributeRaw: async (channel, attr) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: getPadAttributeRaw requires a channel id');
            }
            if (typeof attr !== 'string' || !attr.length) {
                return { error: 'E_INVAL_ATTR' };
            }
            const href = await channelToHref(channel);
            if (!href) { return { error: 'ENOENT' }; }
            const res = await query('GET_PAD_ATTRIBUTE', { href: href, attr: attr });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            const value = (res === undefined || res === null) ? null : res;
            return { value: value };
        },

        getAttribute: async (path) => {
            if (!Array.isArray(path) || path.length === 0) {
                return { error: 'E_INVAL_ATTR' };
            }
            const res = await query('GET_ATTRIBUTE', { attr: path });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            let value = (res === undefined || res === null) ? null : res;
            if (value !== null && typeof value !== 'string') {
                value = String(value);
            }
            return { value: value };
        },

        setAttribute: async (path, value) => {
            if (!Array.isArray(path) || path.length === 0) {
                return { error: 'E_INVAL_ATTR' };
            }
            const payload = { attr: path };
            if (value !== null && value !== undefined) { payload.value = value; }
            const res = await query('SET_ATTRIBUTE', payload);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        getAttributeRaw: async (path) => {
            if (!Array.isArray(path) || path.length === 0) {
                return { error: 'E_INVAL_ATTR' };
            }
            const res = await query('GET_ATTRIBUTE', { attr: path });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            const value = (res === undefined || res === null) ? null : res;
            return { value: value };
        },

        setDisplayName: async (name) => {
            if (typeof name !== 'string') {
                throw new Error('SwiftPad: setDisplayName requires a string');
            }
            await profileBarrier(10000).catch(() => null);
            const res = await query('SET_DISPLAY_NAME', name, { timeout: 20000 });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        getProfile: async () => {
            const res = await profileCmd('SUBSCRIBE', {}, 'PROFILE_TIMEOUT');
            return shapedProfileReply(res, 'SUBSCRIBE');
        },

        setProfileDescription: async (value) => {
            if (typeof value !== 'string') {
                throw new Error('SwiftPad: setProfileDescription requires a string');
            }
            const res = await profileCmd('SET',
                { key: 'description', value: value }, 'PROFILE_TIMEOUT');
            return shapedProfileReply(res, 'SET description');
        },

        setProfileUrl: async (value) => {
            if (typeof value !== 'string') {
                throw new Error('SwiftPad: setProfileUrl requires a string');
            }
            const res = await profileCmd('SET',
                { key: 'url', value: value }, 'PROFILE_TIMEOUT');
            return shapedProfileReply(res, 'SET url');
        },

        setProfileAvatar: async (value) => {
            if (typeof value !== 'string') {
                throw new Error('SwiftPad: setProfileAvatar requires a string');
            }
            if (value !== '' && !/^\/file\/#\/2\/file\//.test(value)) {
                throw new Error('SwiftPad: setProfileAvatar requires a /file/#/2/file/… href or empty string');
            }
            const res = await profileCmd('SET',
                { key: 'avatar', value: value }, 'PROFILE_TIMEOUT');
            return shapedProfileReply(res, 'SET avatar');
        },

        getPinnedUsage: async () => {
            const res = await query('GET_PINNED_USAGE', { teamId: undefined });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return res;
        },

        getPinLimit: async () => {
            const res = await query('GET_PIN_LIMIT', { teamId: undefined });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return res;
        },

        listTeams: async () => {
            const res = await teamCmd('LIST_TEAMS', {});
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { teams: res || {} };
        },

        getTeamMetadata: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: getTeamMetadata requires a teamId string');
            }
            const res = await teamCmd('GET_TEAM_METADATA', { teamId: teamId });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return res || {};
        },

        getTeamRoster: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: getTeamRoster requires a teamId string');
            }
            const res = await teamCmd('GET_TEAM_ROSTER', { teamId: teamId });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { members: res || {} };
        },


        createTeam: async (name) => {
            if (typeof name !== 'string' || !name) {
                throw new Error('SwiftPad: createTeam requires a non-empty name string');
            }
            const preList = await teamCmd('LIST_TEAMS', {});
            if (!preList || typeof preList !== 'object') return { error: 'CREATE_TEAM_PRELIST_FAILED' };
            if (typeof preList.error === 'string') return preList;

            const gate = await teamSlotsGate(preList);
            if (typeof gate.error === 'string') return gate;
            const ownedCap = gate.plan ? (Math.max(gate.cfg.maxOwnedTeams || 0, gate.cfg.maxPremiumTeamsOwned || 0) || 5)
                                       : (gate.cfg.maxOwnedTeams || 5);
            if (gate.teams.filter((t) => t.owner).length >= ownedCap) {
                return { error: 'TEAM_MAX_OWNED_REACHED', errorType: 'owned=' + ownedCap };
            }

            const CREATE_TEAM_TIMEOUT_MS = 15000;
            const createP = teamCmd('CREATE_TEAM', { name: name });
            let timedOut = false;
            createP.then(
                () => { if (timedOut && typeof __sp_trace === 'function') __sp_trace('bootstrap', 'debug', 'createTeam: abandoned create settled OK after timeout'); },
                () => { if (timedOut && typeof __sp_trace === 'function') __sp_trace('bootstrap', 'debug', 'createTeam: abandoned create rejected after timeout'); }
            );
            let timeoutHandle = null;
            const res = await Promise.race([
                createP,
                new Promise((resolve) => {
                    timeoutHandle = setTimeout(() => {
                        timedOut = true;
                        resolve({
                            error: 'CREATE_TEAM_TIMEOUT',
                            errorType: 'a timed-out create may still have landed; re-run team list'
                        });
                    }, CREATE_TEAM_TIMEOUT_MS);
                })
            ]);
            if (timeoutHandle !== null) clearTimeout(timeoutHandle);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;

            const postList = await teamCmd('LIST_TEAMS', {});
            if (!postList || typeof postList !== 'object') return { error: 'CREATE_TEAM_LOST_ID' };
            if (typeof postList.error === 'string') return postList;
            const preIds = {};
            Object.keys(preList).forEach((id) => { preIds[id] = true; });
            const newIds = Object.keys(postList).filter((id) => !preIds[id]);
            if (newIds.length === 0) return { error: 'CREATE_TEAM_LOST_ID' };
            let chosenId = newIds[0];
            if (newIds.length > 1) {
                const matches = newIds.filter((id) => {
                    const e = postList[id];
                    return e && e.owner && e.error !== true && e.offline !== true
                        && e.metadata && e.metadata.name === name;
                });
                if (matches.length !== 1) return { error: 'CREATE_TEAM_AMBIGUOUS_RECOVERY' };
                chosenId = matches[0];
            }
            const entry = postList[chosenId];
            if (entry && entry.error === true) {
                return { error: 'TEAM_LOAD_FAILED', errorType: String(chosenId) };
            }
            if (!(entry && entry.metadata && entry.metadata.name === name)) {
                return { error: 'CREATE_TEAM_AMBIGUOUS_RECOVERY' };
            }
            return { id: chosenId, entry: entry };
        },

        leaveTeam: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: leaveTeam requires a teamId string');
            }
            const res = await teamCmd('LEAVE_TEAM', { teamId: teamId });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'LEAVE_TEAM_FAILED');
            }
            return { ok: true };
        },

        deleteTeam: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: deleteTeam requires a teamId string');
            }
            try { await query('GET_PINNED_USAGE', { teamId: teamId }); } catch (e) {}
            const DELETE_TEAM_TIMEOUT_MS = 15000;
            let timedOut = false;
            const deleteP = teamCmd('DELETE_TEAM', { teamId: teamId });
            deleteP.then(
                () => { if (timedOut && typeof __sp_trace === 'function') __sp_trace('bootstrap', 'debug', 'deleteTeam: abandoned delete settled OK after timeout'); },
                () => { if (timedOut && typeof __sp_trace === 'function') __sp_trace('bootstrap', 'debug', 'deleteTeam: abandoned delete rejected after timeout'); }
            );
            let timeoutHandle = null;
            const res = await Promise.race([
                deleteP,
                new Promise((resolve) => {
                    timeoutHandle = setTimeout(() => {
                        timedOut = true;
                        resolve({ __spDeleteTimedOut: true });
                    }, DELETE_TEAM_TIMEOUT_MS);
                })
            ]);
            if (timeoutHandle !== null) clearTimeout(timeoutHandle);
            if (res && res.__spDeleteTimedOut) {
                const list = await teamCmd('LIST_TEAMS', {});
                const stillThere = list && typeof list === 'object' &&
                    typeof list.error === 'undefined' &&
                    Object.prototype.hasOwnProperty.call(list, teamId);
                if (!stillThere) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn',
                            'deleteTeam: cleanup barrier stalled (known upstream race) but the team is gone from LIST_TEAMS — returning ok; residual team channels may linger server-side');
                    }
                    return { ok: true };
                }
                return { error: 'DELETE_TEAM_TIMEOUT', errorType: 'team still listed after ' + (DELETE_TEAM_TIMEOUT_MS / 1000) + 's; re-run team list' };
            }
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'DELETE_TEAM_FAILED');
            }
            return { ok: true };
        },


        setTeamMetadata: async (teamId, updates) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: setTeamMetadata requires a teamId string');
            }
            if (!updates || typeof updates !== 'object') {
                throw new Error('SwiftPad: setTeamMetadata requires an updates object');
            }
            const current = await teamCmd('GET_TEAM_METADATA', { teamId: teamId });
            if (current && typeof current === 'object' && typeof current.error === 'string') return current;
            const merged = {
                name: typeof updates.name === 'string' ? updates.name : ((current && current.name) || ''),
                topic: typeof updates.topic === 'string' ? updates.topic : ((current && current.topic) || ''),
                avatar: typeof updates.avatar === 'string' ? updates.avatar : ((current && current.avatar) || '')
            };
            const res = await teamCmd('SET_TEAM_METADATA', { teamId: teamId, metadata: merged });
            if (res && typeof res === 'object' && res.error) {
                if (res.error === 'NO_CHANGE') return { ok: true };
                return rawErrorEnvelope(res, 'SET_TEAM_METADATA_FAILED');
            }
            return { ok: true };
        },

        inviteToTeam: async (teamId, user) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: inviteToTeam requires a teamId string');
            }
            if (!user || typeof user !== 'object' || !user.curvePublic || !user.notifications) {
                throw new Error('SwiftPad: inviteToTeam requires a user object with curvePublic and notifications');
            }
            const res = await teamCmd('INVITE_TO_TEAM', { teamId: teamId, user: user });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'INVITE_TO_TEAM_FAILED');
            }
            return { ok: true };
        },

        removeUser: async (teamId, curvePublic) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: removeUser requires a teamId string');
            }
            if (typeof curvePublic !== 'string' || !curvePublic) {
                throw new Error('SwiftPad: removeUser requires a curvePublic string');
            }
            const res = await teamCmd('REMOVE_USER', { teamId: teamId, curvePublic: curvePublic });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'REMOVE_USER_FAILED');
            }
            return { ok: true };
        },

        listContacts: async () => {
            const res = await query('GET_METADATA', undefined);
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            const priv = (res && res.priv) || {};
            const friends = {};
            const source = priv.friends || {};
            Object.keys(source).forEach((k) => {
                if (k === 'me') return;
                friends[k] = source[k];
            });
            return { friends: friends, pending: priv.pendingFriends || {} };
        },

        listIncomingContactRequests: async () => {
            const sub = await ensureMailboxSubscribed();
            if (sub && typeof sub === 'object' && sub.error) {
                return rawErrorEnvelope(sub, 'MAILBOX_SUBSCRIBE_FAILED');
            }
            const requests = [];
            mailboxBuffer.forEach((v) => {
                if (v.type !== 'notifications') { return; }
                const m = v.msg;
                if (!m || m.type !== 'FRIEND_REQUEST') { return; }
                if (typeof m.author !== 'string' || !m.author) { return; }
                const c = (m.content && typeof m.content === 'object') ? m.content : {};
                const user = (c.user && typeof c.user === 'object') ? c.user : c;
                requests.push({ hash: v.hash, author: m.author, user: user });
            });
            return { requests: requests };
        },

        listNotifications: async () => {
            const sub = await ensureMailboxSubscribed();
            if (sub && typeof sub === 'object' && sub.error) {
                return rawErrorEnvelope(sub, 'MAILBOX_SUBSCRIBE_FAILED');
            }
            const notifications = [];
            mailboxBuffer.forEach((v) => {
                const m = v.msg;
                if (!m || typeof m !== 'object') { return; }
                notifications.push(projectMailboxRow(v.type, v.hash, m, m.ctime));
            });
            return { notifications: notifications };
        },

        markNotificationRead: async (box, hash) => {
            if (typeof box !== 'string' || !box) {
                throw new Error('SwiftPad: markNotificationRead requires a box string');
            }
            if (typeof hash !== 'string' || !hash) {
                throw new Error('SwiftPad: markNotificationRead requires a hash string');
            }
            if (box === 'reminders') {
                return { error: 'REMINDER_DISMISS_UNSUPPORTED',
                         errorType: 'the reminders box is virtual and locally generated — it has no channel history to advance, and dismissing into it wedges the worker' };
            }
            const sub = await ensureMailboxSubscribed();
            if (sub && typeof sub === 'object' && sub.error) {
                return rawErrorEnvelope(sub, 'MAILBOX_SUBSCRIBE_FAILED');
            }
            const entry = mailboxBuffer.get(mailboxKey(box, hash));
            if (!entry || entry.type !== box || entry.hash !== hash) {
                return { error: 'NOT_IN_BUFFER',
                         errorType: 'no live notification with that (box, hash) in this session — already dismissed, dismissed elsewhere, or never listed here; re-list before acking' };
            }
            const res = await mailboxCmd('DISMISS', { type: box, hash: hash });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'DISMISS_FAILED');
            }
            mailboxEvict(box, hash);
            return { ok: true };
        },

        notificationHistory: async (box, count, before) => {
            if (typeof box !== 'string' || !box) {
                throw new Error('SwiftPad: notificationHistory requires a box string');
            }
            if (typeof count !== 'number' || !isFinite(count) || count < 1 || count % 1 !== 0) {
                throw new Error('SwiftPad: notificationHistory requires a positive integer count');
            }
            if (count > MAX_HISTORY_COUNT) {
                return { error: 'INVALID_COUNT',
                         errorType: 'count must be at most ' + MAX_HISTORY_COUNT
                             + ' — page instead of asking for the whole channel' };
            }
            if (box === 'broadcast') {
                return { error: 'BROADCAST_HISTORY_UNSUPPORTED',
                         errorType: 'the broadcast box pages forward from a cursor with no count — a different protocol than this verb implements' };
            }
            if (box === 'reminders') {
                return { error: 'REMINDER_HISTORY_UNSUPPORTED',
                         errorType: 'the reminders box is locally generated and has no channel history' };
            }
            if (before !== undefined && before !== null) {
                if (typeof before !== 'string' || before.length !== 64) {
                    return { error: 'INVALID_CURSOR',
                             errorType: 'before must be a 64-character hash from a PREVIOUS HISTORY PAGE (a hash from the unread listing sits ahead of the cursor, not behind it)' };
                }
            }
            const sub = await ensureMailboxSubscribed();
            if (sub && typeof sub === 'object' && sub.error) {
                return rawErrorEnvelope(sub, 'MAILBOX_SUBSCRIBE_FAILED');
            }
            if (historyPending) {
                return { error: 'HISTORY_BUSY',
                         errorType: 'a history page is already in flight — upstream keeps ONE request slot, so pages must be serialised' };
            }
            const anchoredByCaller = (typeof before === 'string');
            let cursor = anchoredByCaller ? before : undefined;
            if (cursor === undefined) {
                const proxy = CryptPad_AsyncStore.proxy || {};
                let m;
                if (box.indexOf('team-') === 0) {
                    const team = proxy.teams && proxy.teams[box.slice('team-'.length)];
                    m = team && team.keys && team.keys.mailbox;
                } else {
                    m = proxy.mailboxes && proxy.mailboxes[box];
                }
                cursor = m && typeof m.lastKnownHash === 'string' ? m.lastKnownHash : undefined;
                if (!cursor) {
                    return { notifications: [], exhausted: true, unreadable: 0, oldestHash: null };
                }
            }
            const txid = 'sp-hist-' + (historyTxidCounter++);
            const requested = anchoredByCaller ? count + 1 : count;
            const done = new Promise((settle) => {
                historyPending = { txid: txid, rows: [], settle: settle, timer: null,
                                   limit: requested };
            });
            historyArmTimer();
            mailboxCmd('LOAD_HISTORY', {
                type: box,
                count: requested,
                txid: txid,
                lastKnownHash: cursor
            }, 'HISTORY_CMD_SILENT', 3000, true).then((res) => {
                if (res && res.error && res.error !== 'HISTORY_CMD_SILENT'
                    && historyPending && historyPending.txid === txid) {
                    historySettle(rawErrorEnvelope(res, 'HISTORY_FAILED'));
                }
            }, (e) => {
                if (historyPending && historyPending.txid === txid) {
                    historySettle({ error: 'HISTORY_FAILED',
                                    errorType: String(e && e.message ? e.message : e).slice(0, 200) });
                }
            });
            const out = await done;
            if (out.error) { return out; }
            const received = anchoredByCaller
                ? out.rows.filter((r) => r.hash !== cursor)
                : out.rows;
            const exhausted = received.length < count;
            const page = (received.length > count) ? received.slice(0, count) : received;
            const notifications = [];
            let unreadable = 0;
            page.forEach((r) => {
                if (!r.message) { unreadable++; return; }
                const m = r.message;
                notifications.push(projectMailboxRow(box, r.hash, m, r.time));
            });
            return {
                notifications: notifications,
                exhausted: exhausted,
                unreadable: unreadable,
                oldestHash: page.length ? page[0].hash : null
            };
        },


        sendContactRequest: async (curvePublic, notifications) => {
            if (typeof curvePublic !== 'string' || !curvePublic) {
                throw new Error('SwiftPad: sendContactRequest requires a curvePublic string');
            }
            if (typeof notifications !== 'string' || !notifications) {
                throw new Error('SwiftPad: sendContactRequest requires a notifications channel string');
            }
            const res = await query('SEND_FRIEND_REQUEST',
                { curvePublic: curvePublic, notifications: notifications });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'SEND_FRIEND_REQUEST_FAILED');
            }
            const sync = await contactSyncBarrier();
            if (sync) {
                return { error: 'SYNC_BARRIER_FAILED',
                         errorType: 'request sent, but friends_pending persistence unconfirmed: ' + sync };
            }
            return { ok: true };
        },

        cancelContactRequest: async (curvePublic) => {
            if (typeof curvePublic !== 'string' || !curvePublic) {
                throw new Error('SwiftPad: cancelContactRequest requires a curvePublic string');
            }
            const proxy = CryptPad_AsyncStore.proxy;
            const pending = (proxy && proxy.friends_pending) || {};
            const entry = pending[curvePublic];
            if (!entry || typeof entry.channel !== 'string' || !entry.channel) {
                return { error: 'NO_PENDING_REQUEST',
                         errorType: 'no outgoing friend request for that curvePublic' };
            }
            const res = await messengerCmd('CANCEL_FRIEND',
                { curvePublic: curvePublic, notifications: entry.channel },
                'CONTACT_TIMEOUT');
            if (res && typeof res === 'object' && res.error) {
                if (res.error === 'CHAT_FAILED') {
                    return { error: 'CONTACT_FAILED', errorType: res.errorType };
                }
                return res;
            }
            return { ok: true };
        },


        answerContactRequest: async (hash, accept) => {
            if (typeof hash !== 'string' || !hash) {
                throw new Error('SwiftPad: answerContactRequest requires a hash string');
            }
            if (typeof accept !== 'boolean') {
                throw new Error('SwiftPad: answerContactRequest requires a boolean accept');
            }
            const sub = await ensureMailboxSubscribed();
            if (sub && typeof sub === 'object' && sub.error) {
                return rawErrorEnvelope(sub, 'MAILBOX_SUBSCRIBE_FAILED');
            }
            const entry = mailboxBuffer.get(mailboxKey('notifications', hash));
            if (!entry || !entry.msg || entry.msg.type !== 'FRIEND_REQUEST') {
                return { error: 'STALE_REQUEST',
                         errorType: 'no live FRIEND_REQUEST with that hash in this session (dismissed, answered elsewhere, or never listed here — re-list before answering)' };
            }
            const m = entry.msg;
            const user = (m.content && typeof m.content === 'object'
                && m.content.user && typeof m.content.user === 'object')
                ? m.content.user : null;
            if (!user || typeof user.curvePublic !== 'string' || !user.curvePublic) {
                return { error: 'REQUEST_IDENTITY_MISSING',
                         errorType: 'request payload carries no user.curvePublic — unanswerable (and upstream would wedge on it)' };
            }
            if (user.curvePublic !== m.author) {
                return { error: 'REQUEST_IDENTITY_MISMATCH',
                         errorType: 'payload identity differs from the crypto-verified sender — refusing to answer a spoofed request' };
            }
            const res = await query('ANSWER_FRIEND_REQUEST', {
                value: accept,
                data: { type: 'notifications', content: { hash: entry.hash, msg: m } }
            });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'ANSWER_FRIEND_REQUEST_FAILED');
            }
            mailboxEvict('notifications', entry.hash);
            if (!accept) {
                const sync = await contactSyncBarrier();
                if (sync) {
                    return { error: 'SYNC_BARRIER_FAILED',
                             errorType: 'decline processed (sent + dismissed worker-side), but dismissal persistence unconfirmed: ' + sync };
                }
            }
            return { ok: true };
        },

        removeContact: async (curvePublic) => {
            if (typeof curvePublic !== 'string' || !curvePublic) {
                throw new Error('SwiftPad: removeContact requires a curvePublic string');
            }
            const res = await messengerCmd('REMOVE_FRIEND', curvePublic, 'CONTACT_TIMEOUT');
            if (res && typeof res === 'object' && res.error) {
                if (res.error === 'CHAT_FAILED') {
                    return { error: 'CONTACT_FAILED', errorType: res.errorType };
                }
                return res;
            }
            return { ok: true };
        },


        createInviteLink: async (teamId, name, role, password, message) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: createInviteLink requires a teamId string');
            }
            if (typeof name !== 'string' || !name.trim()) {
                throw new Error('SwiftPad: createInviteLink requires a non-blank name');
            }
            if (role !== 'VIEWER' && role !== 'MEMBER') {
                throw new Error('SwiftPad: createInviteLink role must be VIEWER or MEMBER');
            }
            const pw = typeof password === 'string' ? password : '';
            const msg = typeof message === 'string' ? message : '';
            const hash = CryptPad_Hash.createRandomHash('invite', pw);
            const parsed = parseInviteFragment(hash);
            if (!parsed) return { error: 'INVALID_INVITE_LINK' };
            const seeds = inviteDeriveSeeds(parsed.key);
            const bytes64 = await inviteDeriveBytesSerial(
                seeds.scrypt, inviteDeriveSalt(pw, inviteInstanceSalt()));
            const res = await teamCmd('CREATE_INVITE_LINK', {
                name: name,
                password: pw,
                message: msg,
                bytes64: bytes64,
                hash: hash,
                teamId: teamId,
                seeds: seeds,
                role: role,
                uses: 1
            });
            if (typeof res === 'string' && res) {
                return { error: res };
            }
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'CREATE_INVITE_LINK_FAILED');
            }
            return { hash: hash };
        },

        previewInviteLink: async (fragment) => {
            if (typeof fragment !== 'string' || !fragment) {
                throw new Error('SwiftPad: previewInviteLink requires a hash fragment string');
            }
            const parsed = parseInviteFragment(fragment);
            if (!parsed) return { error: 'INVALID_INVITE_LINK' };
            const seeds = inviteDeriveSeeds(parsed.key);
            const res = await query('ANON_GET_PREVIEW_CONTENT', { seeds: seeds });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'GET_PREVIEW_FAILED');
            }
            if (!res || typeof res !== 'object' || !Object.keys(res).length || !res.author) {
                return { error: 'INVALID_PREVIEW_CONTENT' };
            }
            return {
                teamName: typeof res.teamName === 'string' ? res.teamName : '',
                message: (typeof res.message === 'string' && res.message) ? res.message : null,
                authorDisplayName: (res.author && typeof res.author.displayName === 'string' && res.author.displayName) ? res.author.displayName : null,
                requiresPassword: !!parsed.password
            };
        },

        acceptInviteLink: async (fragment, password) => {
            if (typeof fragment !== 'string' || !fragment) {
                throw new Error('SwiftPad: acceptInviteLink requires a hash fragment string');
            }
            const parsed = parseInviteFragment(fragment);
            if (!parsed) return { error: 'INVALID_INVITE_LINK' };
            const list = await teamCmd('LIST_TEAMS', {});
            if (!list || typeof list !== 'object') return { error: 'ACCEPT_LINK_PRELIST_FAILED' };
            if (typeof list.error === 'string') return rawErrorEnvelope(list, 'ACCEPT_LINK_PRELIST_FAILED');
            const gate = await teamSlotsGate(list);
            if (typeof gate.error === 'string') return gate;
            const pw = typeof password === 'string' ? password : '';
            const seeds = inviteDeriveSeeds(parsed.key);
            const bytes64 = await inviteDeriveBytesSerial(
                seeds.scrypt, inviteDeriveSalt(pw, inviteInstanceSalt()));
            const res = await teamCmd('ACCEPT_LINK_INVITATION', {
                bytes64: bytes64,
                hash: fragment,
                password: pw
            });
            if (res && typeof res === 'object' && res.error) {
                return rawErrorEnvelope(res, 'ACCEPT_LINK_FAILED');
            }
            return { ok: true };
        },

        getDeletedPads: async (candidates) => {
            if (!Array.isArray(candidates)) {
                throw new Error('SwiftPad: getDeletedPads requires an array of channel ids');
            }
            const res = await query('GET_DELETED_PADS', { list: candidates });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { channels: Array.isArray(res) ? res : [] };
        },

        purgeTrash: async () => {
            const res = await query('DRIVE_USEROBJECT', {
                cmd: 'emptyTrash',
                data: {
                    deleteOwned: false
                }
            });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return { ok: true };
        },

        getShareLinks: async (channel) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: getShareLinks requires a channel id');
            }
            const found = findFileInProxy(channel);
            if (!found) {
                return { error: 'ENOENT' };
            }
            const entry = found.entry;
            const href = entry.href || entry.roHref || '';
            if (!href) {
                throw new Error('SwiftPad: getShareLinks: drive entry has no href');
            }
            const password = (typeof entry.password === 'string' && entry.password.length > 0) ? entry.password : undefined;
            const parsed = CryptPad_Hash.parsePadUrl(href);
            const secret = CryptPad_Hash.getSecrets(parsed.type, parsed.hash, password);
            const editHash = CryptPad_Hash.getEditHashFromKeys(secret) || null;
            const viewHash = CryptPad_Hash.getViewHashFromKeys(secret);
            if (!viewHash) {
                throw new Error('SwiftPad: getShareLinks: no view hash derivable from secret');
            }
            return {
                type: parsed.type,
                editHash: editHash,
                viewHash: viewHash
            };
        },

        getAccountInfo: () => {
            const proxy = CryptPad_AsyncStore.proxy;
            if (!proxy) {
                throw new Error('SwiftPad: getAccountInfo: no proxy (anonymous session?)');
            }
            return {
                edPublic: proxy.edPublic || null,
                curvePublic: proxy.curvePublic || null,
                profileViewHash: (proxy.profile && proxy.profile.view) || null,
                notifications: (proxy.mailboxes && proxy.mailboxes.notifications
                    && proxy.mailboxes.notifications.channel) || null
            };
        },

        getPadContent: async (channel, lastKnownHash) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: getPadContent requires a channel id');
            }
            if (typeof lastKnownHash !== 'undefined' &&
                lastKnownHash !== null &&
                lastKnownHash !== 0 &&
                typeof lastKnownHash !== 'string') {
                return { error: 'PAD_LOAD_FAILED', errorType: 'lastKnownHash must be a string, 0, null, or undefined' };
            }
            const found = findFileInProxy(channel);
            if (!found) return { error: 'ENOENT' };
            const entry = found.entry;

            const href = entry.href || entry.roHref || '';
            if (!href) {
                return { error: 'PAD_LOAD_FAILED', errorType: 'drive entry has no href' };
            }
            const password = (typeof entry.password === 'string' && entry.password.length > 0) ? entry.password : undefined;
            const parsed = CryptPad_Hash.parsePadUrl(href);
            if (!parsed || !parsed.hash) {
                return { error: 'PAD_LOAD_FAILED', errorType: 'parsePadUrl failed' };
            }
            const secret = CryptPad_Hash.getSecrets(parsed.type, parsed.hash, password);
            if (!secret || secret.channel !== channel) {
                return { error: 'PAD_LOAD_FAILED', errorType: 'derived channel mismatch' };
            }

            const cryptKey = (secret.keys.cryptKey instanceof Uint8Array)
                ? secret.keys.cryptKey
                : CryptPad_Util.decodeBase64(secret.keys.cryptKey);
            const validateKeyB64 = (typeof secret.keys.validateKey === 'string')
                ? secret.keys.validateKey
                : CryptPad_Util.encodeBase64(secret.keys.validateKey);
            const validateKeyBytes = CryptPad_Util.decodeBase64(validateKeyB64);

            const network = CryptPad_AsyncStore.network;
            const hk = network && network.historyKeeper;
            if (!network || !hk) {
                return { error: 'PAD_LOAD_FAILED', errorType: 'no network or historyKeeper' };
            }

            const cp = ChainPad.create({ initialState: '', userName: 'sp-read' });
            const ourTxid = mkTxid();
            const replay = setupReplay({
                network, hk, channel, cp, ourTxid,
                cryptKey, validateKeyB64, validateKeyBytes,
                lastKnownHash
            });
            const wrappedReadyPromise = replay.readyPromise.catch(e => {
                throw new Error('PAD_LOAD_FAILED:' + e.message);
            });

            let timeoutId = null;
            const timeoutPromise = new Promise((_, rej) => {
                timeoutId = setTimeout(() => rej(new Error('PAD_LOAD_FAILED:timeout (10s)')), 10000);
            });

            network.on('message', replay.listener);
            try {
                replay.sendGetHistory();
                await Promise.race([wrappedReadyPromise, timeoutPromise]);

                const userDoc = cp.getUserDoc();
                if (replay.counters.applied === 0 && replay.counters.dropped > 0) {
                    return { error: 'PAD_LOAD_FAILED', errorType: 'all ' + replay.counters.dropped + ' messages dropped (signature/decrypt failure)' };
                }
                if (replay.counters.dropped > 0 && typeof __sp_trace === 'function') {
                    __sp_trace('bootstrap', 'warn', 'getPadContent: dropped ' + replay.counters.dropped + ' of ' + (replay.counters.applied + replay.counters.dropped) + ' messages');
                }

                return {
                    type: parsed.type,
                    raw: userDoc,
                    applied: replay.counters.applied,
                    firstAppliedWireHash: replay.counters.firstAppliedWireHash,
                    lastAppliedCheckpointWireHash: replay.counters.lastAppliedCheckpointWireHash
                };
            } finally {
                if (timeoutId) clearTimeout(timeoutId);
                try { network.off('message', replay.listener); } catch (_) {}
                try { cp.abort(); } catch (_) {}
            }
        },

        setPadContent: async (channel, newRawJSON) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: setPadContent requires a channel id');
            }
            if (typeof newRawJSON !== 'string') {
                throw new Error('SwiftPad: setPadContent requires a string `raw`');
            }

            const ctx = loadPadCryptoContext(channel);
            if (ctx.error) {
                if (ctx.error === 'ENOENT' || ctx.error === 'EREADONLY') {
                    return { error: ctx.error, errorType: ctx.errorType };
                }
                return { error: 'PAD_WRITE_FAILED', errorType: ctx.error };
            }
            if (ctx.readOnly || !ctx.encrypt) {
                return { error: 'EREADONLY', errorType: 'view-only secret' };
            }
            const cryptKey = ctx.cryptKey;
            const validateKeyB64 = ctx.validateKeyB64;
            const validateKeyBytes = ctx.validateKeyBytes;
            const encrypt = ctx.encrypt;

            const network = CryptPad_AsyncStore.network;
            const hk = network && network.historyKeeper;
            if (!network || !hk) return { error: 'PAD_WRITE_FAILED', errorType: 'no network or historyKeeper' };

            let wc;
            try {
                wc = await network.join(channel);
            } catch (joinErr) {
                const code = (joinErr && joinErr.type) ? joinErr.type : null;
                if (code === 'EDELETED' || code === 'EEXPIRED') return { error: code };
                if (code === 'ERESTRICTED') return { error: 'EREADONLY', errorType: 'restricted channel' };
                return { error: 'PAD_WRITE_FAILED', errorType: 'join failed: ' + (code || (joinErr && joinErr.message) || 'unknown') };
            }
            const ourTxid = mkTxid();

            let resolveBcast, rejectBcast;
            const bcastPromise = new Promise((res, rej) => { resolveBcast = res; rejectBcast = rej; });

            const cp = ChainPad.create({ initialState: '', userName: 'sp-write' });
            cp.onMessage(function (strMsg, ackCb) {
                wc.bcast(encrypt(strMsg)).then(
                    function () { ackCb(); resolveBcast(); },
                    function (err) {
                        const reason = (err && err.type) ? err.type : ((err && err.message) || 'bcast-failed');
                        ackCb(reason);
                        rejectBcast(new Error('PAD_WRITE_FAILED:bcast-' + reason));
                    }
                );
            });

            const replay = setupReplay({
                network, hk, channel, cp, ourTxid,
                cryptKey, validateKeyB64, validateKeyBytes
            });
            const wrappedReadyPromise = replay.readyPromise.catch(e => {
                throw new Error('PAD_WRITE_FAILED:' + e.message);
            });

            let readyTimeoutId, bcastTimeoutId;
            network.on('message', replay.listener);
            try {
                replay.sendGetHistory();
                const readyTimeout = new Promise((_, rej) => {
                    readyTimeoutId = setTimeout(() => rej(new Error('PAD_WRITE_FAILED:replay-timeout (10s)')), 10000);
                });
                await Promise.race([wrappedReadyPromise, readyTimeout]);

                if (replay.counters.applied === 0 && replay.counters.dropped > 0) {
                    return { error: 'PAD_WRITE_FAILED', errorType: 'all ' + replay.counters.dropped + ' replay messages dropped (signature/decrypt failure)' };
                }

                cp.start();
                cp.contentUpdate(newRawJSON);

                const uncommittedOps = (cp._ && cp._.uncommitted && cp._.uncommitted.operations) || null;
                if (uncommittedOps && uncommittedOps.length === 0) {
                    if (replay.counters.dropped > 0 && typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn',
                            'setPadContent: replay dropped ' + replay.counters.dropped + ' of ' +
                            (replay.counters.applied + replay.counters.dropped) + ' messages (no-op write)');
                    }
                    return { ok: true, msgsApplied: replay.counters.applied, noop: true };
                }

                cp.sync();
                const bcastTimeout = new Promise((_, rej) => {
                    bcastTimeoutId = setTimeout(() => rej(new Error('PAD_WRITE_FAILED:bcast-timeout (10s)')), 10000);
                });
                await Promise.race([bcastPromise, bcastTimeout]);

                if (replay.counters.dropped > 0 && typeof __sp_trace === 'function') {
                    __sp_trace('bootstrap', 'warn',
                        'setPadContent: replay dropped ' + replay.counters.dropped + ' of ' +
                        (replay.counters.applied + replay.counters.dropped) + ' messages');
                }
                return { ok: true, msgsApplied: replay.counters.applied };
            } finally {
                if (readyTimeoutId) clearTimeout(readyTimeoutId);
                if (bcastTimeoutId) clearTimeout(bcastTimeoutId);
                try { network.off('message', replay.listener); } catch (_) {}
                try { cp.abort(); } catch (_) {}
                try { wc.leave(); } catch (_) {}
            }
        },

        openPadSession: async (channel) => {
            if (!channel || typeof channel !== 'string') {
                throw new Error('SwiftPad: openPadSession requires a channel id');
            }
            const ctx = loadPadCryptoContext(channel);
            if (ctx.error) {
                if (ctx.error === 'ENOENT' || ctx.error === 'EREADONLY') {
                    return { error: ctx.error, errorType: ctx.errorType };
                }
                return { error: 'PAD_SESSION_FAILED', errorType: ctx.error };
            }

            const network = CryptPad_AsyncStore.network;
            const hk = network && network.historyKeeper;
            if (!network || !hk) return { error: 'PAD_SESSION_FAILED', errorType: 'no network or historyKeeper' };

            let wc;
            try {
                wc = await network.join(channel);
            } catch (joinErr) {
                const code = (joinErr && joinErr.type) ? joinErr.type : null;
                if (code === 'EDELETED' || code === 'EEXPIRED') return { error: code };
                if (code === 'ERESTRICTED') return { error: 'EREADONLY', errorType: 'restricted channel' };
                return { error: 'PAD_SESSION_FAILED', errorType: 'join failed: ' + (code || (joinErr && joinErr.message) || 'unknown') };
            }

            const cp = ChainPad.create({ initialState: '', userName: 'sp-session' });
            const ourTxid = mkTxid();

            const replay = setupReplay({
                network, hk, channel, cp, ourTxid,
                cryptKey: ctx.cryptKey,
                validateKeyB64: ctx.validateKeyB64,
                validateKeyBytes: ctx.validateKeyBytes
            });
            const wrappedReadyPromise = replay.readyPromise.catch(e => {
                throw new Error('PAD_SESSION_FAILED:' + e.message);
            });

            let readyTimeoutId = null;
            network.on('message', replay.listener);
            try {
                replay.sendGetHistory();
                const readyTimeout = new Promise((_, rej) => {
                    readyTimeoutId = setTimeout(
                        () => rej(new Error('PAD_SESSION_FAILED:replay-timeout (10s)')), 10000
                    );
                });
                try {
                    await Promise.race([wrappedReadyPromise, readyTimeout]);
                } catch (e) {
                    try { network.off('message', replay.listener); } catch (_) {}
                    try { cp.abort(); } catch (_) {}
                    try { wc.leave(); } catch (_) {}
                    return { error: 'PAD_SESSION_FAILED', errorType: e.message.replace(/^PAD_SESSION_FAILED:/, '') };
                }

                if (replay.counters.applied === 0 && replay.counters.dropped > 0) {
                    try { network.off('message', replay.listener); } catch (_) {}
                    try { cp.abort(); } catch (_) {}
                    try { wc.leave(); } catch (_) {}
                    return { error: 'PAD_SESSION_FAILED',
                             errorType: 'all ' + replay.counters.dropped + ' replay messages dropped (signature/decrypt failure)' };
                }
                if (replay.counters.dropped > 0 && typeof __sp_trace === 'function') {
                    __sp_trace('bootstrap', 'warn',
                        'openPadSession: replay dropped ' + replay.counters.dropped + ' of ' +
                        (replay.counters.applied + replay.counters.dropped) + ' messages');
                }
            } finally {
                if (readyTimeoutId) clearTimeout(readyTimeoutId);
            }

            const initialRaw = cp.getUserDoc();
            try { network.off('message', replay.listener); } catch (_) {}

            const sessionId = mkSessionId();
            const handle = {
                sessionId,
                channel,
                cp,
                wc,
                hk,
                ourTxid,
                encrypt: ctx.encrypt,
                cryptKey: ctx.cryptKey,
                validateKeyBytes: ctx.validateKeyBytes,
                lastSent: new Map(),
                readOnly: ctx.readOnly,
                closed: false,
                _pushInFlight: false,
                networkListener: null,
                wcListener: null
            };

            const listeners = mkLiveListeners(handle);
            handle.networkListener = listeners.networkListener;
            handle.wcListener = listeners.wcListener;

            cp.onMessage(function (strMsg, ackCb) {
                if (handle.closed) { ackCb('SESSION_CLOSED'); return; }
                if (handle.readOnly || !handle.encrypt) { ackCb('READ_ONLY'); return; }
                let enc;
                try { enc = handle.encrypt(strMsg); }
                catch (e) { ackCb('ENCRYPT_FAILED:' + (e && e.message)); return; }
                const hash = enc.slice(0, 64);
                if (handle.lastSent.size >= 256) {
                    const firstKey = handle.lastSent.keys().next().value;
                    handle.lastSent.delete(firstKey);
                }
                handle.lastSent.set(hash, Date.now());
                handle.wc.bcast(enc).then(
                    function () { ackCb(); },
                    function (err) {
                        handle.lastSent.delete(hash);
                        const reason = (err && err.type) ? err.type : ((err && err.message) || 'bcast-failed');
                        ackCb(reason);
                    }
                );
            });

            cp.onPatch(function () {
                if (handle.closed) return;
                if (typeof __sp_event !== 'function') return;
                let raw;
                try { raw = handle.cp.getUserDoc(); }
                catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn',
                            'PadSession ' + handle.channel + ': getUserDoc threw: ' + (e && e.message));
                    }
                    return;
                }
                try {
                    __sp_event('PAD_PATCH', JSON.stringify({ sessionId: handle.sessionId, raw }));
                } catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn', 'PAD_PATCH emit failed: ' + (e && e.message));
                    }
                }
            });

            handle.preConfirmFrames = [];
            handle.preConfirmListener = function (msg, sender) {
                if (handle.closed) return;
                handle.preConfirmFrames.push([msg, sender]);
            };
            try { wc.on('message', handle.preConfirmListener); } catch (_) {}

            pendingPadSessions.set(sessionId, handle);
            return {
                ok: true,
                sessionId,
                initialRaw,
                readOnly: ctx.readOnly,
                type: ctx.type
            };
        },

        confirmPadSession: async (sessionId) => {
            if (!sessionId || typeof sessionId !== 'string') {
                throw new Error('SwiftPad: confirmPadSession requires a sessionId');
            }
            const handle = pendingPadSessions.get(sessionId);
            if (!handle) {
                return { error: 'EUNKNOWN', errorType: 'unknown sessionId (already confirmed, closed, or never opened)' };
            }
            try { if (handle.wc && handle.preConfirmListener) handle.wc.off('message', handle.preConfirmListener); } catch (_) {}
            const buffered = handle.preConfirmFrames || [];
            handle.preConfirmFrames = [];
            handle.preConfirmListener = null;
            for (let i = 0; i < buffered.length; i++) {
                try { handle.wcListener(buffered[i][0], buffered[i][1]); } catch (_) {}
            }
            const network = CryptPad_AsyncStore.network;
            try { if (network && handle.networkListener) network.on('message', handle.networkListener); } catch (_) {}
            try { if (handle.wc && handle.wcListener) handle.wc.on('message', handle.wcListener); } catch (_) {}
            try { handle.cp.start(); } catch (_) {}
            pendingPadSessions.delete(sessionId);
            padSessions.set(sessionId, handle);
            return { ok: true };
        },

        pushPadSession: async (sessionId, newRaw) => {
            if (!sessionId || typeof sessionId !== 'string') {
                throw new Error('SwiftPad: pushPadSession requires a sessionId');
            }
            if (typeof newRaw !== 'string') {
                throw new Error('SwiftPad: pushPadSession requires a string `raw`');
            }
            const handle = padSessions.get(sessionId);
            if (!handle) return { error: 'PAD_SESSION_FAILED', errorType: 'no such session' };
            if (handle.closed) return { error: 'PAD_SESSION_FAILED', errorType: 'session closed' };
            if (handle.readOnly) return { error: 'EREADONLY', errorType: 'view-mode session' };
            if (handle._pushInFlight) {
                return { error: 'PAD_SESSION_FAILED', errorType: 'push already in flight' };
            }

            handle._pushInFlight = true;
            let bcastTimeoutId = null;
            try {
                handle.cp.contentUpdate(newRaw);

                const ops = (handle.cp._ && handle.cp._.uncommitted && handle.cp._.uncommitted.operations) || null;
                if (ops && ops.length === 0) {
                    return { ok: true, noop: true };
                }

                let resolve;
                const done = new Promise(res => { resolve = res; });
                let resolved = false;
                handle.cp.onSettle(function () {
                    if (!resolved) { resolved = true; resolve(); }
                });

                handle.cp.sync();
                const bcastTimeout = new Promise((_, rej) => {
                    bcastTimeoutId = setTimeout(
                        () => rej(new Error('PAD_SESSION_FAILED:bcast-timeout (10s)')),
                        10000
                    );
                });
                try {
                    await Promise.race([done, bcastTimeout]);
                } catch (e) {
                    return {
                        error: 'PAD_SESSION_FAILED',
                        errorType: e.message.replace(/^PAD_SESSION_FAILED:/, '')
                    };
                }

                return { ok: true };
            } finally {
                if (bcastTimeoutId) clearTimeout(bcastTimeoutId);
                handle._pushInFlight = false;
            }
        },

        closePadSession: async (sessionId) => {
            if (!sessionId || typeof sessionId !== 'string') {
                throw new Error('SwiftPad: closePadSession requires a sessionId');
            }
            const isPending = pendingPadSessions.has(sessionId);
            const handle = isPending ? pendingPadSessions.get(sessionId) : padSessions.get(sessionId);
            if (!handle || handle.closed) return { ok: true };
            handle.closed = true;
            const network = CryptPad_AsyncStore.network;
            try { if (network && handle.networkListener) network.off('message', handle.networkListener); } catch (_) {}
            try { if (handle.wc && handle.wcListener) handle.wc.off('message', handle.wcListener); } catch (_) {}
            try { if (handle.wc && handle.preConfirmListener) handle.wc.off('message', handle.preConfirmListener); } catch (_) {}
            try { handle.cp.abort(); } catch (_) {}
            try { handle.wc.leave(); } catch (_) {}
            if (isPending) {
                pendingPadSessions.delete(sessionId);
            } else {
                padSessions.delete(sessionId);
            }
            return { ok: true };
        },


        listCalendars: async () => {
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const out = [];
            for (const p of calendarSnapshots.values()) {
                const md = (p.content && p.content.metadata) || {};
                out.push({
                    id: p.id,
                    title: typeof md.title === 'string' ? md.title : '',
                    color: typeof md.color === 'string' ? md.color : '',
                    readOnly: !!p.readOnly,
                    loading: !!p.loading,
                    owned: !!p.owned,
                    restricted: !!p.restricted,
                    offline: !!p.offline,
                    teams: Array.isArray(p.teams) ? p.teams.map(String) : []
                });
            }
            out.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
            return { calendars: out };
        },

        listCalendarEvents: async (calendarId) => {
            if (typeof calendarId !== 'string' || !/^[0-9a-f]{32}$/.test(calendarId)) {
                throw new Error('SwiftPad: listCalendarEvents requires a 32-hex calendar channel id');
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const p = calendarSnapshots.get(calendarId);
            if (!p) { return { error: 'CALENDAR_NOT_FOUND' }; }
            if (p.loading) { return { error: 'CALENDAR_NOT_READY' }; }
            const content = (p.content && p.content.content) || {};
            const out = [];
            for (const key of Object.keys(content)) {
                const ev = content[key];
                if (!ev || typeof ev !== 'object') { continue; }
                const rec = ev.recUpdate || {};
                const hasOverrides = (rec.one && Object.keys(rec.one).length > 0)
                    || (rec.from && Object.keys(rec.from).length > 0);
                let raw;
                try { raw = JSON.stringify(ev); } catch (e) {
                    if (typeof __sp_trace === 'function') {
                        __sp_trace('bootstrap', 'warn',
                            'listCalendarEvents: unserializable event ' + key + ' skipped: ' + e.message);
                    }
                    continue;
                }
                out.push({
                    id: key,
                    title: typeof ev.title === 'string' ? ev.title : '',
                    location: typeof ev.location === 'string' ? ev.location : '',
                    body: typeof ev.body === 'string' ? ev.body : '',
                    startMs: typeof ev.start === 'number' ? ev.start : null,
                    endMs: typeof ev.end === 'number' ? ev.end : null,
                    startDay: typeof ev.startDay === 'string' ? ev.startDay : null,
                    endDay: typeof ev.endDay === 'string' ? ev.endDay : null,
                    isAllDay: !!ev.isAllDay,
                    reminders: Array.isArray(ev.reminders)
                        ? ev.reminders.filter((r) => typeof r === 'number') : [],
                    isRecurring: !!ev.recurrenceRule || !!hasOverrides,
                    raw: raw
                });
            }
            out.sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
            return { events: out };
        },



        createCalendar: async (title, color) => {
            if (typeof title !== 'string' || !title.trim()) {
                throw new Error('SwiftPad: createCalendar requires a non-blank title string');
            }
            if (typeof color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(color)) {
                throw new Error('SwiftPad: createCalendar requires a #rrggbb color string');
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const before = new Set(calendarSnapshots.keys());
            const res = await calendarCmd('CREATE',
                { title: title, color: color }, 'CALENDAR_TIMEOUT');
            if (res && res.error) { return res; }
            const deadline = Date.now() + 5000;
            for (;;) {
                const matches = [];
                for (const [id, p] of calendarSnapshots) {
                    if (before.has(id)) { continue; }
                    const md = (p.content && p.content.metadata) || {};
                    if (md.title === title) { matches.push(id); }
                }
                if (matches.length === 1) { return { id: matches[0] }; }
                if (matches.length > 1) { break; }
                if (Date.now() >= deadline) { break; }
                await sleep(50);
            }
            return { error: 'CALENDAR_CREATE_UNCONFIRMED' };
        },

        updateCalendarMeta: async (calendarId, title, color) => {
            if (typeof calendarId !== 'string' || !/^[0-9a-f]{32}$/.test(calendarId)) {
                throw new Error('SwiftPad: updateCalendarMeta requires a 32-hex calendar channel id');
            }
            if (title === null && color === null) {
                throw new Error('SwiftPad: updateCalendarMeta requires a title or a color');
            }
            if (title !== null && (typeof title !== 'string' || !title.trim())) {
                throw new Error('SwiftPad: updateCalendarMeta title must be a non-blank string');
            }
            if (color !== null && (typeof color !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(color))) {
                throw new Error('SwiftPad: updateCalendarMeta color must be #rrggbb');
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const p = calendarSnapshots.get(calendarId);
            if (!p) { return { error: 'CALENDAR_NOT_FOUND' }; }
            if (p.loading) { return { error: 'CALENDAR_NOT_READY' }; }
            if (p.readOnly) { return { error: 'CALENDAR_READ_ONLY' }; }
            const md = (p.content && p.content.metadata) || {};
            const res = await calendarCmd('UPDATE', {
                id: calendarId,
                title: title !== null ? title : (typeof md.title === 'string' ? md.title : ''),
                color: color !== null ? color : (typeof md.color === 'string' ? md.color : '')
            }, 'CALENDAR_TIMEOUT');
            if (res && res.error) { return res; }
            return { ok: true };
        },

        deleteCalendar: async (calendarId) => {
            if (typeof calendarId !== 'string' || !/^[0-9a-f]{32}$/.test(calendarId)) {
                throw new Error('SwiftPad: deleteCalendar requires a 32-hex calendar channel id');
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const p = calendarSnapshots.get(calendarId);
            if (!p) { return { error: 'CALENDAR_NOT_FOUND' }; }
            const teams = Array.isArray(p.teams) ? p.teams.map(String) : [];
            if (teams.indexOf('1') === -1) {
                return { error: 'CALENDAR_TEAM_WRITE_UNSUPPORTED' };
            }
            const res = await calendarCmd('DELETE', { id: calendarId }, 'CALENDAR_TIMEOUT');
            if (res && res.error) { return res; }
            return { ok: true };
        },

        createCalendarEvent: async (calendarId, fields) => {
            if (typeof calendarId !== 'string' || !/^[0-9a-f]{32}$/.test(calendarId)) {
                throw new Error('SwiftPad: createCalendarEvent requires a 32-hex calendar channel id');
            }
            if (!fields || typeof fields !== 'object') {
                throw new Error('SwiftPad: createCalendarEvent requires a fields object');
            }
            if (typeof fields.title !== 'string') {
                throw new Error('SwiftPad: createCalendarEvent requires a title string');
            }
            if (typeof fields.start !== 'number' || typeof fields.end !== 'number') {
                throw new Error('SwiftPad: createCalendarEvent requires numeric start/end ms');
            }
            if (!Array.isArray(fields.reminders)
                || fields.reminders.some((r) => typeof r !== 'number')) {
                throw new Error('SwiftPad: createCalendarEvent requires reminders as an array of numbers (pass [] for none)');
            }
            if (typeof fields.timeZone !== 'string' || !fields.timeZone) {
                throw new Error('SwiftPad: createCalendarEvent requires a timeZone string');
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const p = calendarSnapshots.get(calendarId);
            if (!p) { return { error: 'CALENDAR_NOT_FOUND' }; }
            if (p.loading) { return { error: 'CALENDAR_NOT_READY' }; }
            if (p.readOnly) { return { error: 'CALENDAR_READ_ONLY' }; }
            const id = Number(Math.floor(Math.random() * Number.MAX_SAFE_INTEGER))
                .toString(32).replace(/\./g, '');
            const res = await calendarCmd('CREATE_EVENT', {
                id: id,
                calendarId: calendarId,
                title: fields.title,
                category: 'time',
                location: typeof fields.location === 'string' ? fields.location : '',
                body: typeof fields.body === 'string' ? fields.body : '',
                start: fields.start,
                end: fields.end,
                isAllDay: !!fields.isAllDay,
                reminders: fields.reminders,
                timeZone: fields.timeZone,
                recurrenceRule: ''
            }, 'CALENDAR_TIMEOUT');
            if (res && res.error) { return res; }
            return { id: id };
        },

        updateCalendarEvent: async (calendarId, eventId, changes) => {
            if (typeof calendarId !== 'string' || !/^[0-9a-f]{32}$/.test(calendarId)) {
                throw new Error('SwiftPad: updateCalendarEvent requires a 32-hex calendar channel id');
            }
            if (typeof eventId !== 'string' || !eventId || eventId.indexOf('|') !== -1) {
                throw new Error('SwiftPad: updateCalendarEvent requires a base event id (no occurrence ids)');
            }
            if (!changes || typeof changes !== 'object' || Object.keys(changes).length === 0) {
                throw new Error('SwiftPad: updateCalendarEvent requires a non-empty changes object');
            }
            const wire = {};
            for (const k of Object.keys(changes)) {
                const v = changes[k];
                if (k === 'title' || k === 'location' || k === 'body') {
                    if (typeof v !== 'string') { throw new Error('SwiftPad: updateCalendarEvent ' + k + ' must be a string'); }
                    wire[k] = v;
                } else if (k === 'startMs' || k === 'endMs') {
                    if (typeof v !== 'number') { throw new Error('SwiftPad: updateCalendarEvent ' + k + ' must be a number'); }
                    wire[k === 'startMs' ? 'start' : 'end'] = v;
                } else if (k === 'isAllDay') {
                    if (typeof v !== 'boolean') { throw new Error('SwiftPad: updateCalendarEvent isAllDay must be a boolean'); }
                    wire.isAllDay = v;
                } else if (k === 'reminders') {
                    if (!Array.isArray(v) || v.some((r) => typeof r !== 'number')) {
                        throw new Error('SwiftPad: updateCalendarEvent reminders must be an array of numbers');
                    }
                    wire.reminders = v;
                } else {
                    throw new Error('SwiftPad: updateCalendarEvent does not accept "' + k + '" (v1 fields: title, location, body, startMs, endMs, isAllDay, reminders)');
                }
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const p = calendarSnapshots.get(calendarId);
            if (!p) { return { error: 'CALENDAR_NOT_FOUND' }; }
            if (p.loading) { return { error: 'CALENDAR_NOT_READY' }; }
            if (p.readOnly) { return { error: 'CALENDAR_READ_ONLY' }; }
            const content = (p.content && p.content.content) || {};
            const ev = content[eventId];
            if (!ev || typeof ev !== 'object') { return { error: 'EVENT_NOT_FOUND' }; }
            const rec = ev.recUpdate || {};
            if (ev.recurrenceRule
                || (rec.one && Object.keys(rec.one).length > 0)
                || (rec.from && Object.keys(rec.from).length > 0)) {
                return { error: 'RECURRING_EDIT_UNSUPPORTED' };
            }
            const res = await calendarCmd('UPDATE_EVENT', {
                ev: { id: eventId, calendarId: calendarId },
                changes: wire
            }, 'CALENDAR_TIMEOUT');
            if (res && res.error) { return res; }
            return { ok: true };
        },

        deleteCalendarEvent: async (calendarId, eventId) => {
            if (typeof calendarId !== 'string' || !/^[0-9a-f]{32}$/.test(calendarId)) {
                throw new Error('SwiftPad: deleteCalendarEvent requires a 32-hex calendar channel id');
            }
            if (typeof eventId !== 'string' || !eventId || eventId.indexOf('|') !== -1) {
                throw new Error('SwiftPad: deleteCalendarEvent requires a base event id (no occurrence ids)');
            }
            const sub = await ensureCalendarSubscribed();
            if (sub && sub.error) { return sub; }
            const p = calendarSnapshots.get(calendarId);
            if (!p) { return { error: 'CALENDAR_NOT_FOUND' }; }
            if (p.loading) { return { error: 'CALENDAR_NOT_READY' }; }
            if (p.readOnly) { return { error: 'CALENDAR_READ_ONLY' }; }
            const content = (p.content && p.content.content) || {};
            if (!content[eventId]) { return { error: 'EVENT_NOT_FOUND' }; }
            const res = await calendarCmd('DELETE_EVENT',
                { calendarId: calendarId, id: eventId }, 'CALENDAR_TIMEOUT');
            if (res && res.error) { return res; }
            return { ok: true };
        },


        openPadChat: async (padChannel) => {
            if (!padChannel || typeof padChannel !== 'string') {
                throw new Error('SwiftPad: openPadChat requires a pad channel id');
            }
            const liveFor = (pc) => {
                for (const s of chatSessions.values()) {
                    if (s.padChannel === pc) return true;
                }
                return false;
            };
            if (chatOpensInFlight.has(padChannel) || liveFor(padChannel)) {
                return { error: 'CHAT_ALREADY_OPEN' };
            }
            chatOpensInFlight.add(padChannel);
            const mapReadError = (res) => {
                if (res.error === 'ENOENT') return { error: 'PAD_NOT_FOUND' };
                return {
                    error: 'CHAT_FAILED',
                    errorType: (String(res.error)
                        + (res.errorType ? (': ' + res.errorType) : '')).slice(0, 200)
                };
            };
            try {
                const ctx = loadPadCryptoContext(padChannel);
                if (ctx.error) return mapReadError(ctx);
                let content;
                try {
                    content = await globalThis.__swiftpad.getPadContent(padChannel);
                } catch (e) {
                    return {
                        error: 'CHAT_FAILED',
                        errorType: String(e && e.message || e).slice(0, 200)
                    };
                }
                if (content && content.error) return mapReadError(content);
                let doc;
                try { doc = JSON.parse(content.raw); } catch (e) {
                    return { error: 'CHAT_FAILED', errorType: 'pad content is not JSON' };
                }
                const md = Array.isArray(doc) ? (doc[3] && doc[3].metadata) : (doc && doc.metadata);
                const chat2 = md ? md.chat2 : undefined;
                if (chat2 === undefined || chat2 === null) {
                    return { error: 'CHAT_NOT_INITIALIZED' };
                }
                if (typeof chat2 !== 'string' || !/^[0-9a-f]{32}$/.test(chat2)) {
                    return { error: 'CHAT_FAILED', errorType: 'chat2 malformed (expected 32 lowercase hex)' };
                }
                const res = await messengerCmd('OPEN_PAD_CHAT',
                    { channel: chat2, secret: ctx.workerSecret }, 'CHAT_OPEN_TIMEOUT');
                if (res && res.error) {
                    try {
                        const m = CryptPad_AsyncStore.messenger;
                        if (m && m.leavePad) { m.leavePad(padChannel); }
                    } catch (e) {
                        if (typeof __sp_trace === 'function') {
                            __sp_trace('bootstrap', 'warn', 'openPadChat cleanup: leavePad threw: ' + (e && e.message));
                        }
                    }
                    return res;
                }
                const chatSessionId = mkTxid();
                chatSessions.set(chatSessionId, { padChannel: padChannel, chatChannel: chat2 });
                return { chatSessionId: chatSessionId, chatChannel: chat2 };
            } finally {
                chatOpensInFlight.delete(padChannel);
            }
        },

        chatRooms: async (chatSessionId) => {
            const entry = chatSessions.get(chatSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            const res = await messengerCmd('GET_ROOMS',
                { padChat: entry.chatChannel }, 'CHAT_OPEN_TIMEOUT');
            if (res && res.error) return res;
            if (!Array.isArray(res) || !res[0] || !Array.isArray(res[0].messages)) {
                return { error: 'CHAT_FAILED', errorType: 'GET_ROOMS reply shape unexpected' };
            }
            return { messages: res[0].messages };
        },

        chatMoreHistory: async (chatSessionId, sig, count) => {
            const entry = chatSessions.get(chatSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            if (typeof sig !== 'string' || !sig.length) {
                throw new Error('SwiftPad: chatMoreHistory requires a sig string');
            }
            const n = (typeof count === 'number' && count > 0)
                ? Math.min(Math.floor(count), 100) : 10;
            const res = await messengerCmd('GET_MORE_HISTORY',
                { id: entry.chatChannel, sig: sig, count: n }, 'CHAT_HISTORY_TIMEOUT');
            if (res && res.error) return res;
            if (!Array.isArray(res)) {
                return { error: 'CHAT_FAILED', errorType: 'GET_MORE_HISTORY reply not an array' };
            }
            return { messages: res };
        },

        sendChatMessage: async (chatSessionId, text) => {
            const entry = chatSessions.get(chatSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            if (typeof text !== 'string') {
                throw new Error('SwiftPad: sendChatMessage requires a text string');
            }
            const res = await messengerCmd('SEND_MESSAGE',
                { id: entry.chatChannel, content: text });
            if (res && res.error) return res;
            return { ok: true };
        },

        closePadChat: async (chatSessionId) => {
            if (!chatSessionId || typeof chatSessionId !== 'string') {
                throw new Error('SwiftPad: closePadChat requires a chatSessionId');
            }
            const entry = chatSessions.get(chatSessionId);
            if (!entry) return { ok: true };
            chatSessions.delete(chatSessionId);
            try {
                const m = CryptPad_AsyncStore.messenger;
                if (m && m.leavePad) { m.leavePad(entry.padChannel); }
            } catch (e) {
                if (typeof __sp_trace === 'function') {
                    __sp_trace('bootstrap', 'warn', 'closePadChat: leavePad threw: ' + (e && e.message));
                }
            }
            return { ok: true };
        },


        openDMChannel: async (curvePublic) => {
            if (!curvePublic || typeof curvePublic !== 'string') {
                throw new Error('SwiftPad: openDMChannel requires a contact curvePublic');
            }
            const liveFor = (cp) => {
                for (const s of dmSessions.values()) {
                    if (s.curvePublic === cp) return true;
                }
                return false;
            };
            if (dmOpensInFlight.has(curvePublic) || liveFor(curvePublic)) {
                return { error: 'CHAT_ALREADY_OPEN' };
            }
            dmOpensInFlight.add(curvePublic);
            try {
                const proxy = CryptPad_AsyncStore.proxy;
                if (proxy && proxy.curvePublic === curvePublic) {
                    return { error: 'NO_SUCH_FRIEND' };
                }
                const init = await ensureInitFriends();
                if (init && init.error) return init;
                let res = await messengerCmd('GET_ROOMS',
                    { curvePublic: curvePublic }, 'CHAT_OPEN_TIMEOUT');
                if (res && res.error === 'NO_SUCH_CHANNEL') {
                    const pollDeadline = Date.now() + DM_JOIN_POLL_MS;
                    while (res && res.error === 'NO_SUCH_CHANNEL' &&
                           Date.now() < pollDeadline) {
                        await sleep(DM_JOIN_POLL_STEP_MS);
                        res = await messengerCmd('GET_ROOMS',
                            { curvePublic: curvePublic }, 'CHAT_OPEN_TIMEOUT');
                    }
                    if (res && res.error === 'NO_SUCH_CHANNEL') {
                        initFriendsPromise = null;
                        const again = await ensureInitFriends();
                        if (again && again.error) return again;
                        res = await messengerCmd('GET_ROOMS',
                            { curvePublic: curvePublic }, 'CHAT_OPEN_TIMEOUT');
                    }
                }
                if (res && res.error) return res;
                if (!Array.isArray(res) || !res[0] || typeof res[0].id !== 'string') {
                    return { error: 'CHAT_FAILED', errorType: 'GET_ROOMS reply shape unexpected' };
                }
                const dmSessionId = mkTxid();
                dmSessions.set(dmSessionId, { curvePublic: curvePublic, channel: res[0].id });
                return { dmSessionId: dmSessionId, channel: res[0].id };
            } finally {
                dmOpensInFlight.delete(curvePublic);
            }
        },

        dmRooms: async (dmSessionId) => {
            const entry = dmSessions.get(dmSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            const res = await messengerCmd('GET_ROOMS',
                { curvePublic: entry.curvePublic }, 'CHAT_OPEN_TIMEOUT');
            if (res && res.error) return res;
            if (!Array.isArray(res) || !res[0] || !Array.isArray(res[0].messages)) {
                return { error: 'CHAT_FAILED', errorType: 'GET_ROOMS reply shape unexpected' };
            }
            return { messages: res[0].messages };
        },

        sendDM: async (dmSessionId, text) => {
            const entry = dmSessions.get(dmSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            if (typeof text !== 'string') {
                throw new Error('SwiftPad: sendDM requires a text string');
            }
            const res = await messengerCmd('SEND_MESSAGE',
                { id: entry.channel, content: text });
            if (res && res.error) return res;
            return { ok: true };
        },

        dmMoreHistory: async (dmSessionId, sig, count) => {
            const entry = dmSessions.get(dmSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            if (typeof sig !== 'string' || !sig.length) {
                throw new Error('SwiftPad: dmMoreHistory requires a sig string');
            }
            const n = (typeof count === 'number' && count > 0)
                ? Math.min(Math.floor(count), 100) : 10;
            const res = await messengerCmd('GET_MORE_HISTORY',
                { id: entry.channel, sig: sig, count: n }, 'CHAT_HISTORY_TIMEOUT');
            if (res && res.error) return res;
            if (!Array.isArray(res)) {
                return { error: 'CHAT_FAILED', errorType: 'GET_MORE_HISTORY reply not an array' };
            }
            return { messages: res };
        },

        dmMarkRead: async (dmSessionId, sig) => {
            const entry = dmSessions.get(dmSessionId);
            if (!entry) return { error: 'CHAT_CLOSED' };
            if (typeof sig !== 'string' || !sig.length) {
                throw new Error('SwiftPad: dmMarkRead requires a sig string');
            }
            const res = await messengerCmd('SET_CHANNEL_HEAD',
                { id: entry.channel, sig: sig });
            if (res && res.error) return res;
            return { ok: true };
        },

        closeDMChannel: async (dmSessionId) => {
            if (!dmSessionId || typeof dmSessionId !== 'string') {
                throw new Error('SwiftPad: closeDMChannel requires a dmSessionId');
            }
            dmSessions.delete(dmSessionId);
            return { ok: true };
        },

        getDrive: async () => {
            return driveEntriesReply(undefined);
        },

        getTeamDrive: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: getTeamDrive requires a teamId string');
            }
            return driveEntriesReply(teamId);
        },

        getTeamPinnedUsage: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: getTeamPinnedUsage requires a teamId string');
            }
            const res = await query('GET_PINNED_USAGE', { teamId: teamId });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return res;
        },

        getTeamPinLimit: async (teamId) => {
            if (typeof teamId !== 'string' || !teamId) {
                throw new Error('SwiftPad: getTeamPinLimit requires a teamId string');
            }
            const res = await query('GET_PIN_LIMIT', { teamId: teamId });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            return res;
        },

        serializeDriveForCache: async (teamId) => {
            if (teamId !== undefined && (typeof teamId !== 'string' || !teamId)) {
                throw new Error('SwiftPad: serializeDriveForCache teamId must be a non-empty string when present');
            }
            const res = await query('GET_DRIVE', { teamId: teamId });
            if (res && typeof res === 'object' && typeof res.error === 'string') return res;
            const proxy = (res && res.drive) || {};
            return {
                driveUserDoc: JSON.stringify({
                    filesData: proxy.filesData || {},
                    root: proxy.root || {},
                    trash: proxy.trash || {},
                    template: Array.isArray(proxy.template) ? proxy.template : [],
                    sharedFolders: proxy.sharedFolders || {},
                    sharedFoldersTemp: proxy.sharedFoldersTemp || {}
                })
            };
        },

        streamFileContent_open: async (channel) => {
            if (!channel || typeof channel !== 'string') {
                return { error: 'PROTOCOL', errorType: 'channel must be a string' };
            }
            const found = findFileInProxy(channel);
            if (!found) return { error: 'ENOENT' };
            const entry = found.entry;
            const url = entry.href || entry.roHref || '';
            if (!url) return { error: 'ENOENT' };

            const parsed = CryptPad_Hash.parsePadUrl(url);
            if (!parsed || !parsed.hash) {
                return { error: 'FILE_NOT_BLOB', errorType: 'parsePadUrl failed' };
            }
            if (parsed.type !== 'file') {
                return { error: 'FILE_NOT_BLOB', errorType: 'parsed.type=' + parsed.type };
            }

            const password = (typeof entry.password === 'string' && entry.password.length > 0) ? entry.password : undefined;
            const secret = CryptPad_Hash.getSecrets('file', parsed.hash, password);
            if (!secret || !secret.keys || !secret.keys.cryptKey) {
                return { error: 'FILE_DECRYPT_FAILED', errorType: 'no cryptKey from getSecrets' };
            }
            const cryptKey = (secret.keys.cryptKey instanceof Uint8Array)
                ? secret.keys.cryptKey
                : CryptPad_Util.decodeBase64(secret.keys.cryptKey);

            const driveTitle = entry.filename || entry.title || '';

            const apiConfig = globalThis.__sp_apiConfig || {};
            const fileHost = apiConfig.fileHost || apiConfig.httpUnsafeOrigin || '';
            if (!fileHost) {
                return { error: 'FILE_FETCH_FAILED', errorType: 'no fileHost in apiConfig' };
            }
            const blobUrl = fileHost + CryptPad_Hash.getBlobPathFromHex(channel);

            let httpStream;
            try {
                httpStream = __sp_http.stream(blobUrl);
            } catch (e) {
                return { error: 'FILE_FETCH_FAILED', errorType: 'stream open: ' + (e && e.message ? e.message : String(e)) };
            }

            const h = {
                cryptKey: cryptKey,
                httpStream: httpStream,
                buffered: [],
                bufferedLen: 0,
                chunkNonce: new Uint8Array(24),
                sourceEof: false,
                terminal: null
            };

            let metadata;
            try {
                await _streamReadAtLeast(h, 2);
                if (h.bufferedLen < 2) {
                    try { httpStream.close(); } catch (_) {}
                    return { error: 'FILE_DECRYPT_FAILED', errorType: 'truncated: missing metadata prefix' };
                }
                const prefix = _streamConsume(h, 2);
                const metaLen = (prefix[0] << 8) | prefix[1];
                if (metaLen <= 0 || metaLen > FILE_METADATA_MAX) {
                    try { httpStream.close(); } catch (_) {}
                    return { error: 'FILE_DECRYPT_FAILED', errorType: 'metadata length out of range: ' + metaLen };
                }
                await _streamReadAtLeast(h, metaLen);
                if (h.bufferedLen < metaLen) {
                    try { httpStream.close(); } catch (_) {}
                    return { error: 'FILE_DECRYPT_FAILED', errorType: 'truncated: metadata buffer short' };
                }
                const encMeta = _streamConsume(h, metaLen);
                const zeroNonce = new Uint8Array(24);
                const metaPlain = nacl.secretbox.open(encMeta, zeroNonce, cryptKey);
                if (!metaPlain) {
                    try { httpStream.close(); } catch (_) {}
                    return { error: 'FILE_DECRYPT_FAILED', errorType: 'metadata secretbox.open returned null' };
                }
                let metaJson;
                try {
                    metaJson = CryptPad_Util.encodeUTF8(metaPlain);
                    metadata = JSON.parse(metaJson);
                } catch (e) {
                    try { httpStream.close(); } catch (_) {}
                    return { error: 'FILE_DECRYPT_FAILED', errorType: 'metadata not JSON: ' + (e && e.message ? e.message : String(e)) };
                }
                if (typeof metadata.name !== 'string' || metadata.name.length === 0) {
                    try { httpStream.close(); } catch (_) {}
                    return { error: 'FILE_DECRYPT_FAILED', errorType: 'metadata.name absent or empty' };
                }
            } catch (e) {
                try { httpStream.close(); } catch (_) {}
                return { error: 'FILE_FETCH_FAILED', errorType: 'metadata read: ' + (e && e.message ? e.message : String(e)) };
            }

            const handleId = _nextStreamHandleId++;
            _streamHandles[handleId] = h;
            return {
                handle: handleId,
                metadata: {
                    name: metadata.name,
                    mimeType: (typeof metadata.type === 'string') ? metadata.type : '',
                    driveTitle: driveTitle
                }
            };
        },

        streamFileContent_next: async (handleId) => {
            const h = _streamHandles[handleId];
            if (!h) return { error: 'FILE_FETCH_FAILED', errorType: 'unknown handle' };
            if (h.terminal) return h.terminal;

            const out = [];
            for (let i = 0; i < FILE_BATCH_CHUNKS_PER_NEXT; i++) {
                try {
                    await _streamReadAtLeast(h, FILE_CIPHERTEXT_CHUNK_SIZE);
                } catch (e) {
                    h.terminal = { error: 'FILE_FETCH_FAILED', errorType: e && e.message ? e.message : String(e) };
                    return h.terminal;
                }
                const available = Math.min(h.bufferedLen, FILE_CIPHERTEXT_CHUNK_SIZE);
                if (available === 0) {
                    h.terminal = { chunks: out, done: true };
                    return h.terminal;
                }
                const ct = _streamConsume(h, available);
                _fileCryptoIncrement(h.chunkNonce);
                const pt = nacl.secretbox.open(ct, h.chunkNonce, h.cryptKey);
                if (!pt) {
                    h.terminal = { error: 'FILE_DECRYPT_FAILED', errorType: 'chunk secretbox.open returned null' };
                    return h.terminal;
                }
                out.push(CryptPad_Util.encodeBase64(pt));
                if (h.sourceEof && h.bufferedLen === 0) {
                    h.terminal = { chunks: out, done: true };
                    return h.terminal;
                }
            }
            return { chunks: out, done: false };
        },

        streamFileContent_close: async (handleId) => {
            const h = _streamHandles[handleId];
            if (!h) return { ok: true };
            delete _streamHandles[handleId];
            try { h.httpStream.close(); } catch (_) {}
            return { ok: true };
        },

        uploadFile_open: async (name, mimeType) => {
            if (typeof name !== 'string' || name.length === 0) {
                return { error: 'PROTOCOL', errorType: 'name must be a non-empty string' };
            }
            if (typeof mimeType !== 'string' || mimeType.length === 0) {
                return { error: 'PROTOCOL', errorType: 'mimeType must be a non-empty string' };
            }
            const proxy = (typeof CryptPad_AsyncStore !== 'undefined') ? CryptPad_AsyncStore.proxy : null;
            if (!proxy || typeof proxy.edPrivate !== 'string' || typeof proxy.edPublic !== 'string') {
                return { error: 'NOT_AUTHENTICATED', errorType: 'edPrivate/edPublic absent on proxy' };
            }
            for (const existingId in _uploadHandles) {
                const existing = _uploadHandles[existingId];
                if (existing && existing.finalized === false) {
                    return { error: 'FILE_UPLOAD_FAILED', errorType: 'concurrent upload not supported in phase-1 (one in-flight upload per session)' };
                }
            }
            if (proxy.edPrivate.length !== 88 || proxy.edPublic.length !== 44) {
                return { error: 'NOT_AUTHENTICATED', errorType: 'edPrivate/edPublic shape unexpected' };
            }
            const apiConfig = globalThis.__sp_apiConfig || {};
            let apiOrigin;
            try {
                apiOrigin = _authApiOrigin(apiConfig);
            } catch (e) {
                return { error: 'FILE_UPLOAD_FAILED', errorType: 'ServerCommand origin: ' + (e && e.message ? e.message : String(e)) };
            }
            const fileHost = apiConfig.fileHost || apiConfig.httpUnsafeOrigin || '';
            if (!apiOrigin || !fileHost) {
                return { error: 'FILE_UPLOAD_FAILED', errorType: 'apiConfig missing auth origin (httpUnsafeOrigin/websocketPath) or fileHost' };
            }

            const hash = CryptPad_Hash.createRandomHash('file');
            const secret = CryptPad_Hash.getSecrets('file', hash);
            if (!secret || !secret.keys || !secret.keys.cryptKey || !secret.channel) {
                return { error: 'FILE_UPLOAD_FAILED', errorType: 'getSecrets returned bad shape' };
            }
            const cryptKey = (secret.keys.cryptKey instanceof Uint8Array)
                ? secret.keys.cryptKey
                : CryptPad_Util.decodeBase64(secret.keys.cryptKey);
            const channel = secret.channel;
            const href = '/file/#' + hash;

            const edPublic = proxy.edPublic;
            const secretKey = CryptPad_Util.decodeBase64(proxy.edPrivate);
            const owners = [edPublic];

            try {
                await query('UPLOAD_CANCEL', { teamId: undefined, id: channel, size: 1 });
            } catch (_) {
            }

            let cookie;
            try {
                const r2 = await _serverCommand(apiOrigin,
                    { publicKey: edPublic, secretKey: secretKey },
                    { command: 'UPLOAD_COOKIE', id: channel });
                if (!r2.cookie) {
                    throw new Error('UPLOAD_COOKIE step2 missing cookie');
                }
                cookie = r2.cookie;
            } catch (e) {
                return { error: 'FILE_UPLOAD_FAILED', errorType: 'ServerCommand: ' + (e && e.message ? e.message : String(e)) };
            }

            const metadata = { name: name, type: mimeType, owners: owners };
            const metaPlain = CryptPad_Util.decodeUTF8(JSON.stringify(metadata));
            if (metaPlain.length > FILE_METADATA_MAX) {
                return { error: 'PROTOCOL', errorType: 'metadata too large: ' + metaPlain.length };
            }
            const zeroNonce = new Uint8Array(24);
            const encMeta = _fileCryptoEncryptChunk(metaPlain, zeroNonce, cryptKey);
            if (encMeta.length > FILE_METADATA_MAX) {
                return { error: 'PROTOCOL', errorType: 'encrypted metadata too large: ' + encMeta.length };
            }
            const prefixed = _fileCryptoConcat2(_fileCryptoEncodePrefix(encMeta.length), encMeta);
            try {
                cookie = await _uploadChunkPost(fileHost, channel, prefixed, cookie, edPublic, secretKey);
            } catch (e) {
                return { error: 'FILE_UPLOAD_FAILED', errorType: 'metadata POST: ' + (e && e.message ? e.message : String(e)) };
            }

            const chunkNonce = new Uint8Array(24);

            const handleId = _nextUploadHandleId++;
            _uploadHandles[handleId] = {
                cryptKey: cryptKey,
                secretKey: secretKey,
                edPublic: edPublic,
                cookie: cookie,
                channel: channel,
                hash: hash,
                href: href,
                owners: owners,
                mimeType: mimeType,
                title: name,
                nonce: chunkNonce,
                totalEncryptedBytes: prefixed.length,
                totalPlaintextBytesSeen: 0,
                plainChunkSize: FILE_PLAIN_CHUNK_SIZE,
                fileHost: fileHost,
                finalized: false
            };
            return {
                handle: handleId,
                channel: channel,
                hash: hash,
                href: href,
                plainChunkSize: FILE_PLAIN_CHUNK_SIZE
            };
        },

        uploadFile_writeChunks: async (handleId, plaintextBase64Array, isFinal) => {
            const h = _uploadHandles[handleId];
            if (!h) return { error: 'FILE_UPLOAD_FAILED', errorType: 'unknown handle' };
            if (h.finalized) return { error: 'FILE_UPLOAD_FAILED', errorType: 'handle already finalized' };
            if (!Array.isArray(plaintextBase64Array)) {
                return { error: 'PROTOCOL', errorType: 'plaintextBase64Array must be array' };
            }
            if (plaintextBase64Array.length === 0) {
                return { error: 'PROTOCOL', errorType: 'plaintextBase64Array empty' };
            }
            if (plaintextBase64Array.length > FILE_UPLOAD_BATCH_MAX) {
                return { error: 'PROTOCOL', errorType: 'batch exceeds max ' + FILE_UPLOAD_BATCH_MAX };
            }
            if (typeof isFinal !== 'boolean') {
                return { error: 'PROTOCOL', errorType: 'isFinal must be boolean' };
            }
            if (isFinal === true && plaintextBase64Array.length !== 1) {
                return { error: 'PROTOCOL', errorType: 'isFinal:true requires exactly one chunk in batch' };
            }

            for (let i = 0; i < plaintextBase64Array.length; i++) {
                const b64 = plaintextBase64Array[i];
                if (typeof b64 !== 'string') {
                    return { error: 'PROTOCOL', errorType: 'chunk[' + i + '] not a string' };
                }
                let bytes;
                try {
                    bytes = CryptPad_Util.decodeBase64(b64);
                } catch (_) {
                    return { error: 'PROTOCOL', errorType: 'chunk[' + i + '] not valid base64' };
                }
                const isTerminalChunk = isFinal && (i === plaintextBase64Array.length - 1);
                if (!isTerminalChunk && bytes.length !== h.plainChunkSize) {
                    return { error: 'PROTOCOL', errorType: 'chunk[' + i + '] non-terminal size mismatch: ' + bytes.length + ' vs ' + h.plainChunkSize };
                }
                if (bytes.length === 0) {
                    return { error: 'PROTOCOL', errorType: 'chunk[' + i + '] empty' };
                }
                if (bytes.length > h.plainChunkSize) {
                    return { error: 'PROTOCOL', errorType: 'chunk[' + i + '] oversized: ' + bytes.length };
                }

                h.totalPlaintextBytesSeen += bytes.length;

                _fileCryptoIncrement(h.nonce);
                const ciphertext = _fileCryptoEncryptChunk(bytes, h.nonce, h.cryptKey);

                try {
                    h.cookie = await _uploadChunkPost(h.fileHost, h.channel, ciphertext, h.cookie, h.edPublic, h.secretKey);
                } catch (e) {
                    return { error: 'FILE_UPLOAD_FAILED', errorType: 'chunk[' + i + '] POST: ' + (e && e.message ? e.message : String(e)) };
                }
                h.totalEncryptedBytes += ciphertext.length;
            }

            if (isFinal === true) {
                h.finalized = true;
            }
            return {
                ok: true,
                progress: { bytesUploaded: h.totalPlaintextBytesSeen }
            };
        },

        uploadFile_finalize: async (handleId, title, path) => {
            const h = _uploadHandles[handleId];
            if (!h) return { error: 'FILE_FINALIZE_FAILED', errorType: 'unknown handle' };
            if (!h.finalized) return { error: 'PROTOCOL', errorType: 'must call _writeChunks with isFinal:true before _finalize' };
            if (typeof title !== 'string') return { error: 'PROTOCOL', errorType: 'title must be a string' };
            if (!Array.isArray(path)) return { error: 'PROTOCOL', errorType: 'path must be an array' };
            const effectiveTitle = (title.length > 0) ? title : h.title;

            try {
                const r1 = await query('UPLOAD_COMPLETE', { teamId: undefined, id: h.channel, owned: true });
                if (r1 && typeof r1 === 'object' && typeof r1.error === 'string') {
                    return { error: 'FILE_FINALIZE_FAILED', errorType: 'UPLOAD_COMPLETE: ' + r1.error, partialUploadOrphanChannel: h.channel };
                }
            } catch (e) {
                return { error: 'FILE_FINALIZE_FAILED', errorType: 'UPLOAD_COMPLETE: ' + (e && e.message ? e.message : String(e)), partialUploadOrphanChannel: h.channel };
            }

            try {
                const setRes = await query('SET_PAD_TITLE', {
                    href: h.href,
                    channel: h.channel,
                    title: effectiveTitle,
                    path: (path.length > 0) ? path : undefined,
                    owners: h.owners,
                    forceSave: true,
                    teamId: undefined,
                    password: undefined
                });
                if (setRes && typeof setRes === 'object' && typeof setRes.error === 'string') {
                    return { error: 'FILE_FINALIZE_FAILED', errorType: 'SET_PAD_TITLE: ' + setRes.error, partialUploadOrphanChannel: h.channel };
                }
                if (setRes && typeof setRes === 'object' && setRes.notStored) {
                    return { error: 'FILE_FINALIZE_FAILED', errorType: 'SET_PAD_TITLE: notStored (anonymous/disabled-store)', partialUploadOrphanChannel: h.channel };
                }
            } catch (e) {
                return { error: 'FILE_FINALIZE_FAILED', errorType: 'SET_PAD_TITLE: ' + (e && e.message ? e.message : String(e)), partialUploadOrphanChannel: h.channel };
            }

            try {
                await query('SET_PAD_ATTRIBUTE', { href: h.href, attr: 'fileType', value: h.mimeType });
            } catch (_) {  }
            try {
                await query('SET_PAD_ATTRIBUTE', { href: h.href, attr: 'owners', value: h.owners });
            } catch (_) {  }

            let entry = null;
            const found = findFileInProxy(h.channel);
            if (found && found.entry) {
                entry = found.entry;
            } else {
                try {
                    const driveRes = await query('GET_DRIVE', { teamId: undefined });
                    const proxy2 = (driveRes && driveRes.drive) || {};
                    const filesData = proxy2.filesData || null;
                    if (filesData) {
                        for (const id of Object.keys(filesData)) {
                            const f = filesData[id];
                            if (f && typeof f === 'object' && f.channel === h.channel) {
                                entry = f;
                                break;
                            }
                        }
                    }
                } catch (_) {
                }
            }

            h.cryptKey = new Uint8Array(0);
            h.secretKey = new Uint8Array(0);
            h.cookie = '';
            delete _uploadHandles[handleId];

            if (entry) {
                const idForEntry = (entry.id || found && found.id) || h.channel;
                const finalEntry = Object.assign({}, entry, {
                    id: idForEntry,
                    channel: h.channel,
                    href: entry.href || h.href,
                    title: entry.title || effectiveTitle,
                    atime: (typeof entry.atime === 'number') ? entry.atime : Date.now(),
                    ctime: (typeof entry.ctime === 'number') ? entry.ctime : Date.now(),
                    owners: entry.owners || h.owners
                });
                return { driveEntry: finalEntry };
            }
            const now = Date.now();
            const synthEntry = {
                id: h.channel,
                channel: h.channel,
                href: h.href,
                title: effectiveTitle,
                atime: now,
                ctime: now,
                owners: h.owners,
                password: null
            };
            return { driveEntry: synthEntry };
        },

        uploadFile_cancel: async (handleId) => {
            const h = _uploadHandles[handleId];
            if (!h) return { ok: true };
            const size = Math.max(h.totalPlaintextBytesSeen, 1);
            try {
                await query('UPLOAD_CANCEL', { teamId: undefined, id: h.channel, size: size });
            } catch (_) {
            }
            h.cryptKey = new Uint8Array(0);
            h.secretKey = new Uint8Array(0);
            h.cookie = '';
            delete _uploadHandles[handleId];
            return { ok: true };
        }
    };

    globalThis.__swiftpad.test = {
        padSessionsSize: () => padSessions.size,

        authApiOrigin: (apiConfig) => ({ origin: _authApiOrigin(apiConfig) }),

        deriveInviteMaterial: async (safeSeed, password, instanceSaltOverride) => {
            if (typeof safeSeed !== 'string' || !safeSeed) {
                throw new Error('SwiftPad: deriveInviteMaterial requires a safeSeed string');
            }
            const pw = typeof password === 'string' ? password : '';
            const salt = typeof instanceSaltOverride === 'string'
                ? instanceSaltOverride : inviteInstanceSalt();
            const seeds = inviteDeriveSeeds(safeSeed);
            const bytes64 = await inviteDeriveBytesSerial(
                seeds.scrypt, inviteDeriveSalt(pw, salt));
            return { seeds: seeds, bytes64: bytes64, instanceSalt: salt };
        },

        messengerCmd: messengerCmd,

        mailboxCmd: mailboxCmd,
        interceptMailboxFrame: interceptMailboxFrame,
        mailboxBufferSize: () => mailboxBuffer.size,

        historyPendingTxid: () => (historyPending ? historyPending.txid : null),

        profileCmd: profileCmd,

        calendarCmd: calendarCmd,

        removeLoginBlock: async (scryptBytesB64, apiConfig) => {
            const derived = decomposeScryptBytes(bytesFromB64(scryptBytesB64));
            await _serverCommand(_authApiOrigin(apiConfig), blockSignKeyPair(derived), {
                command: 'REMOVE_BLOCK'
            });
            return { ok: true };
        },

        seedLegacyChannel: async (channelHex, contentJSON) => {
            if (typeof channelHex !== 'string' || !/^[0-9a-f]{32}$/.test(channelHex)) {
                throw new Error('SwiftPad: seedLegacyChannel requires a 32-hex channel');
            }
            if (typeof contentJSON !== 'string' || !contentJSON) {
                throw new Error('SwiftPad: seedLegacyChannel requires a content string');
            }
            const network = CryptPad_AsyncStore.network;
            if (!network || !network.historyKeeper) {
                throw new Error('SwiftPad: seedLegacyChannel: no network (CONNECT first)');
            }
            const keys = channelKeysFromSecret(CryptPad_Hash.getSecrets('drive', CryptPad_Hash.createRandomHash('drive')));
            await seedChannel({
                network: network,
                channel: channelHex,
                keys: keys,
                metadata: { validateKey: keys.validateKeyB64 },
                patches: [chainpadInitialPatch(contentJSON)],
                strict: true,
                label: 'seedLegacyChannel'
            });
            return { ok: true };
        }
    };
})();
