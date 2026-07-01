import { spawn, ChildProcessWithoutNullStreams } from 'child_process';
import fs from 'fs';
import path from 'path';
import http from 'http';
import { app } from 'electron';
import ffmpegPath from 'ffmpeg-static';
import ffprobeStatic from 'ffprobe-static';

const ffprobePath = ffprobeStatic.path;

// Audio codecs Chromium's bundled (royalty-free) decoders already handle natively —
// anything else (AC3, DTS, TrueHD, etc, common in scene releases) needs transcoding to AAC.
const COMPATIBLE_AUDIO_CODECS = new Set(['aac', 'mp3', 'opus', 'vorbis', 'flac', 'pcm_s16le', 'pcm_u8']);

let currentProc: ChildProcessWithoutNullStreams | null = null;
let currentSessionDir: string | null = null;
let server: http.Server | null = null;
let serverPort = 0;

function getTranscodeRoot(): string {
    return path.join(app.getPath('temp'), 'streamhub-transcode');
}

export interface ProbeResult {
    needsTranscode: boolean;
    duration: number;
    audioCodec?: string;
}

export function probeMedia(url: string): Promise<ProbeResult> {
    return new Promise((resolve) => {
        const args = ['-v', 'quiet', '-print_format', 'json', '-show_format', '-show_streams', url];
        const proc = spawn(ffprobePath, args);

        let stdout = '';
        let settled = false;
        const timer = setTimeout(() => {
            if (settled) return;
            settled = true;
            proc.kill();
            console.error('ffprobe timed out, assuming direct playback is fine');
            resolve({ needsTranscode: false, duration: 0 });
        }, 15000);

        proc.stdout.on('data', (d) => { stdout += d.toString(); });
        proc.on('close', () => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            try {
                const info = JSON.parse(stdout);
                const duration = parseFloat(info.format?.duration) || 0;
                const audioStream = (info.streams || []).find((s: any) => s.codec_type === 'audio');
                const audioCodec = audioStream?.codec_name;
                const needsTranscode = !!audioCodec && !COMPATIBLE_AUDIO_CODECS.has(audioCodec);
                console.log(`Probed media: audioCodec=${audioCodec}, needsTranscode=${needsTranscode}, duration=${duration}`);
                resolve({ needsTranscode, duration, audioCodec });
            } catch (e) {
                console.error('Failed to parse ffprobe output:', e);
                resolve({ needsTranscode: false, duration: 0 });
            }
        });
        proc.on('error', (e) => {
            if (settled) return;
            settled = true;
            clearTimeout(timer);
            console.error('ffprobe spawn error:', e);
            resolve({ needsTranscode: false, duration: 0 });
        });
    });
}

function ensureServer(): Promise<number> {
    if (server) return Promise.resolve(serverPort);

    return new Promise((resolve) => {
        server = http.createServer((req, res) => {
            if (!currentSessionDir || !req.url) {
                res.writeHead(404);
                res.end();
                return;
            }

            // Server only ever serves the single active session's directory — strip any
            // path/query the client sent and resolve purely by filename for safety.
            const requestedName = path.basename(decodeURIComponent(req.url.split('?')[0]));
            const filePath = path.join(currentSessionDir, requestedName);

            if (!filePath.startsWith(currentSessionDir) || !fs.existsSync(filePath)) {
                res.writeHead(404);
                res.end();
                return;
            }

            const ext = path.extname(filePath);
            const contentType = ext === '.m3u8' ? 'application/vnd.apple.mpegurl' : ext === '.ts' ? 'video/mp2t' : 'application/octet-stream';

            res.setHeader('Access-Control-Allow-Origin', '*');
            res.setHeader('Content-Type', contentType);
            res.setHeader('Cache-Control', 'no-cache');
            fs.createReadStream(filePath).pipe(res);
        });
        server.listen(0, () => {
            serverPort = (server!.address() as any).port;
            resolve(serverPort);
        });
    });
}

function waitForPlaylist(playlistPath: string, timeoutMs = 20000): Promise<void> {
    return new Promise((resolve, reject) => {
        const start = Date.now();
        const check = () => {
            if (fs.existsSync(playlistPath)) {
                const content = fs.readFileSync(playlistPath, 'utf-8');
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
        try { currentProc.kill('SIGKILL'); } catch { /* already dead */ }
        currentProc = null;
    }
    if (currentSessionDir) {
        try { fs.rmSync(currentSessionDir, { recursive: true, force: true }); } catch { /* best effort, OS may still hold a handle briefly */ }
        currentSessionDir = null;
    }
}

export async function startTranscodeSession(sourceUrl: string, startTimeSeconds: number): Promise<{ playlistUrl: string }> {
    killCurrentSession();

    const port = await ensureServer();
    const sessionId = Date.now().toString();
    const dir = path.join(getTranscodeRoot(), sessionId);
    fs.mkdirSync(dir, { recursive: true });
    currentSessionDir = dir;

    const playlistPath = path.join(dir, 'playlist.m3u8');

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
        '-hls_segment_filename', path.join(dir, 'seg_%05d.ts'),
        playlistPath
    ];

    console.log('Starting ffmpeg transcode session:', sessionId, 'at', startTimeSeconds + 's');
    const proc = spawn(ffmpegPath as unknown as string, args);
    currentProc = proc;

    proc.stderr.on('data', (d) => console.log('[ffmpeg]', d.toString().trim()));
    proc.on('exit', (code) => console.log('ffmpeg transcode session exited, code:', code));
    proc.on('error', (e) => console.error('ffmpeg spawn error:', e));

    try {
        await waitForPlaylist(playlistPath);
    } catch (e) {
        killCurrentSession();
        throw e;
    }

    return { playlistUrl: `http://localhost:${port}/playlist.m3u8?t=${sessionId}` };
}

export function stopTranscodeSession() {
    killCurrentSession();
}

export function cleanupTranscodeRoot() {
    const root = getTranscodeRoot();
    if (fs.existsSync(root)) {
        try { fs.rmSync(root, { recursive: true, force: true }); } catch { /* best effort */ }
    }
}
