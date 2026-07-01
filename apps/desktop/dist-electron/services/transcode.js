"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.probeMedia = probeMedia;
exports.startTranscodeSession = startTranscodeSession;
exports.stopTranscodeSession = stopTranscodeSession;
exports.cleanupTranscodeRoot = cleanupTranscodeRoot;
const child_process_1 = require("child_process");
const fs_1 = __importDefault(require("fs"));
const path_1 = __importDefault(require("path"));
const http_1 = __importDefault(require("http"));
const electron_1 = require("electron");
const ffmpeg_static_1 = __importDefault(require("ffmpeg-static"));
const ffprobe_static_1 = __importDefault(require("ffprobe-static"));
const ffprobePath = ffprobe_static_1.default.path;
// Audio codecs Chromium's bundled (royalty-free) decoders already handle natively —
// anything else (AC3, DTS, TrueHD, etc, common in scene releases) needs transcoding to AAC.
const COMPATIBLE_AUDIO_CODECS = new Set(['aac', 'mp3', 'opus', 'vorbis', 'flac', 'pcm_s16le', 'pcm_u8']);
let currentProc = null;
let currentSessionDir = null;
let server = null;
let serverPort = 0;
function getTranscodeRoot() {
    return path_1.default.join(electron_1.app.getPath('temp'), 'streamhub-transcode');
}
function probeMedia(url) {
    return new Promise((resolve) => {
        const args = ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', url];
        const proc = (0, child_process_1.spawn)(ffprobePath, args);
        let stdout = '';
        let settled = false;
        const timer = setTimeout(() => {
            if (settled)
                return;
            settled = true;
            proc.kill();
            console.error('ffprobe timed out, assuming direct playback is fine');
            resolve({ needsTranscode: false, duration: 0 });
        }, 15000);
        proc.stdout.on('data', (d) => { stdout += d.toString(); });
        proc.on('close', () => {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            try {
                const info = JSON.parse(stdout);
                const duration = parseFloat(info.format?.duration) || 0;
                const audioStream = (info.streams || []).find((s) => s.codec_type === 'audio');
                const audioCodec = audioStream?.codec_name;
                const needsTranscode = !!audioCodec && !COMPATIBLE_AUDIO_CODECS.has(audioCodec);
                console.log(`Probed media: audioCodec=${audioCodec}, needsTranscode=${needsTranscode}, duration=${duration}`);
                resolve({ needsTranscode, duration, audioCodec });
            }
            catch (e) {
                console.error('Failed to parse ffprobe output:', e);
                resolve({ needsTranscode: false, duration: 0 });
            }
        });
        proc.on('error', (e) => {
            if (settled)
                return;
            settled = true;
            clearTimeout(timer);
            console.error('ffprobe spawn error:', e);
            resolve({ needsTranscode: false, duration: 0 });
        });
    });
}
function ensureServer() {
    if (server)
        return Promise.resolve(serverPort);
    return new Promise((resolve) => {
        server = http_1.default.createServer((req, res) => {
            if (!currentSessionDir || !req.url) {
                res.writeHead(404);
                res.end();
                return;
            }
            // Server only ever serves the single active session's directory — strip any
            // path/query the client sent and resolve purely by filename for safety.
            const requestedName = path_1.default.basename(decodeURIComponent(req.url.split('?')[0]));
            const filePath = path_1.default.join(currentSessionDir, requestedName);
            if (!filePath.startsWith(currentSessionDir) || !fs_1.default.existsSync(filePath)) {
                res.writeHead(404);
                res.end();
                return;
            }
            const ext = path_1.default.extname(filePath);
            const contentType = ext === '.m3u8' ? 'application/vnd.apple.mpegurl' : ext === '.ts' ? 'video/mp2t' : 'application/octet-stream';
            res.setHeader('Access-Control-Allow-Origin', '*');
            res.setHeader('Content-Type', contentType);
            res.setHeader('Cache-Control', 'no-cache');
            fs_1.default.createReadStream(filePath).pipe(res);
        });
        server.listen(0, () => {
            serverPort = server.address().port;
            resolve(serverPort);
        });
    });
}
function waitForPlaylist(playlistPath, timeoutMs = 20000) {
    return new Promise((resolve, reject) => {
        const start = Date.now();
        const check = () => {
            if (fs_1.default.existsSync(playlistPath)) {
                const content = fs_1.default.readFileSync(playlistPath, 'utf-8');
                if (content.includes('.ts')) {
                    resolve();
                    return;
                }
            }
            if (Date.now() - start > timeoutMs) {
                reject(new Error('Timed out waiting for transcode to produce output'));
                return;
            }
            setTimeout(check, 100);
        };
        check();
    });
}
function killCurrentSession() {
    if (currentProc) {
        try {
            currentProc.kill('SIGKILL');
        }
        catch { /* already dead */ }
        currentProc = null;
    }
    if (currentSessionDir) {
        try {
            fs_1.default.rmSync(currentSessionDir, { recursive: true, force: true });
        }
        catch { /* best effort, OS may still hold a handle briefly */ }
        currentSessionDir = null;
    }
}
async function startTranscodeSession(sourceUrl, startTimeSeconds) {
    killCurrentSession();
    const port = await ensureServer();
    const sessionId = Date.now().toString();
    const dir = path_1.default.join(getTranscodeRoot(), sessionId);
    fs_1.default.mkdirSync(dir, { recursive: true });
    currentSessionDir = dir;
    const playlistPath = path_1.default.join(dir, 'playlist.m3u8');
    const args = [
        '-loglevel', 'error',
        '-fflags', '+genpts',
        ...(startTimeSeconds > 0 ? ['-ss', String(startTimeSeconds)] : []),
        '-i', sourceUrl,
        '-map', '0:v:0',
        '-map', '0:a:0?',
        '-avoid_negative_ts', 'make_zero',
        '-c:v', 'copy',
        '-c:a', 'aac',
        '-b:a', '192k',
        '-ac', '2',
        '-f', 'hls',
        '-hls_init_time', '1',
        '-hls_time', '4',
        '-hls_list_size', '0',
        '-hls_flags', 'independent_segments',
        '-hls_segment_filename', path_1.default.join(dir, 'seg_%05d.ts'),
        playlistPath
    ];
    console.log('Starting ffmpeg transcode session:', sessionId, 'at', startTimeSeconds + 's');
    const proc = (0, child_process_1.spawn)(ffmpeg_static_1.default, args);
    currentProc = proc;
    proc.stderr.on('data', (d) => console.log('[ffmpeg]', d.toString().trim()));
    proc.on('exit', (code) => console.log('ffmpeg transcode session exited, code:', code));
    proc.on('error', (e) => console.error('ffmpeg spawn error:', e));
    try {
        await waitForPlaylist(playlistPath);
    }
    catch (e) {
        killCurrentSession();
        throw e;
    }
    return { playlistUrl: `http://localhost:${port}/playlist.m3u8?t=${sessionId}` };
}
function stopTranscodeSession() {
    killCurrentSession();
}
function cleanupTranscodeRoot() {
    const root = getTranscodeRoot();
    if (fs_1.default.existsSync(root)) {
        try {
            fs_1.default.rmSync(root, { recursive: true, force: true });
        }
        catch { /* best effort */ }
    }
}
//# sourceMappingURL=transcode.js.map