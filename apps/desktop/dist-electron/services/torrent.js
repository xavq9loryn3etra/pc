"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.searchTorrent = searchTorrent;
exports.getTorrentioStreams = getTorrentioStreams;
exports.getBestMagnet = getBestMagnet;
exports.getMovieTorrents = getMovieTorrents;
exports.getEpisodeTorrents = getEpisodeTorrents;
const torrent_search_api_1 = __importDefault(require("torrent-search-api"));
const axios_1 = __importDefault(require("axios"));
// Enable public providers
torrent_search_api_1.default.enablePublicProviders();
// Helper to guess quality
function parseQuality(title) {
    const t = title.toLowerCase();
    if (t.includes('2160p') || t.includes('4k'))
        return '4K';
    if (t.includes('1080p'))
        return '1080p';
    if (t.includes('720p'))
        return '720p';
    if (t.includes('480p'))
        return '480p';
    if (t.includes('cam'))
        return 'CAM';
    return 'Unknown';
}
async function searchTorrent(query) {
    console.log(`Searching for: ${query}`);
    try {
        const magnets = await torrent_search_api_1.default.search(query, 'Video', 20); // Limit to 20
        return magnets.map((m) => ({
            title: m.title,
            size: m.size,
            magnet: m.magnet,
            seeds: m.seeds,
            quality: parseQuality(m.title)
        }));
    }
    catch (err) {
        console.error("Torrent search error:", err);
        return [];
    }
}
const TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:6969/announce",
    "udp://tracker.coppersurfer.tk:6969/announce",
    "udp://tracker.leechers-paradise.org:6969/announce",
    "udp://9.rarbg.to:2710/announce",
    "udp://9.rarbg.me:2710/announce",
    "udp://tracker.internetwarriors.net:1337/announce",
    "udp://tracker.cyberia.is:6969/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://tracker.tiny-vps.com:6969/announce",
    "udp://tracker.moeking.me:6969/announce",
    "udp://opentracker.i2p.rocks:6969/announce",
    "udp://open.tracker.cl:1337/announce",
    "udp://explodie.org:6969/announce",
    "udp://ch3oh.ru:6969/announce"
];
const trackerParams = TRACKERS.map(t => `&tr=${encodeURIComponent(t)}`).join('');
async function getTorrentioStreams(type, id) {
    try {
        const url = `https://torrentio.strem.fun/stream/${type}/${id}.json`;
        console.log(`Fetching Torrentio streams: ${url}`);
        const res = await axios_1.default.get(url, {
            headers: { 'User-Agent': 'Mozilla/5.0' },
            timeout: 10000
        });
        if (!res.data || !res.data.streams) {
            return [];
        }
        return res.data.streams
            .filter((s) => s.infoHash)
            .map((s) => {
            const rawTitle = s.title || '';
            const rawName = s.name || '';
            const titleLines = rawTitle.split('\n');
            const nameLines = rawName.split('\n');
            const name = titleLines.length > 0 ? titleLines[0].trim() : 'Unknown Torrent';
            // Quality
            let quality = 'HDRip';
            const qualityStr = nameLines.length > 1 ? nameLines[1].trim().toLowerCase() : '';
            if (qualityStr.includes('4k') || qualityStr.includes('2160')) {
                quality = '4K';
            }
            else if (qualityStr.includes('1080')) {
                quality = '1080p';
            }
            else if (qualityStr.includes('720')) {
                quality = '720p';
            }
            else if (qualityStr.includes('480')) {
                quality = '480p';
            }
            else if (qualityStr.includes('cam') || qualityStr.includes('scr')) {
                quality = 'CAM';
            }
            else {
                // Fallback to title check
                const titleLower = name.toLowerCase();
                if (titleLower.includes('2160p') || titleLower.includes('4k')) {
                    quality = '4K';
                }
                else if (titleLower.includes('1080p')) {
                    quality = '1080p';
                }
                else if (titleLower.includes('720p')) {
                    quality = '720p';
                }
                else if (titleLower.includes('480p')) {
                    quality = '480p';
                }
            }
            // Size
            let size = 'Unknown size';
            const statsLine = titleLines.length > 1 ? titleLines[1] : '';
            const sizeMatch = statsLine.match(/💾\s*(\d+(?:\.\d+)?\s*(?:GB|MB|TB))/i);
            if (sizeMatch) {
                size = sizeMatch[1];
            }
            // Seeds
            let seeds = 0;
            const seedersMatch = statsLine.match(/👤\s*(\d+)/);
            if (seedersMatch) {
                seeds = parseInt(seedersMatch[1]) || 0;
            }
            const magnet = `magnet:?xt=urn:btih:${s.infoHash}${trackerParams}`;
            return {
                title: name,
                size,
                magnet,
                seeds,
                quality
            };
        })
            .filter((s) => s.seeds > 0); // Drop dead torrents — nothing to stream from
    }
    catch (e) {
        console.error('Error fetching Torrentio streams:', e);
        return [];
    }
}
async function getBestMagnet(imdbId, title, year) {
    const torrents = await getMovieTorrents(imdbId, title, year);
    if (torrents.length > 0)
        return torrents[0].magnet;
    return null;
}
async function getMovieTorrents(imdbId, title, year) {
    if (imdbId && imdbId.startsWith('tt')) {
        const streams = await getTorrentioStreams('movie', imdbId);
        if (streams.length > 0)
            return streams;
    }
    const query = `${title} ${year}`;
    const results = await searchTorrent(query);
    // Sort by seeds
    return results
        .filter((r) => r.magnet) // Ensure magnet link
        .filter((r) => (r.seeds || 0) > 0) // Drop dead torrents — nothing to stream from
        .filter((r) => {
        const t = r.title.toLowerCase();
        // Aggressive Bad Quality Filter
        const badKeywords = [
            'cam', 'hdcam', 'camrip',
            'telesync', 'ts', 'hdts',
            'hardcoded', 'hc', // hardcoded subs usually implies early rip
            'screener', 'scr', 'dvdscr', 'dvdscreener',
            'korsub', 'hcsub',
            'workprint', 'wp'
        ];
        // Check for specific substrings that definitely mean bad quality
        const isBad = badKeywords.some(k => {
            if (t.includes(k)) {
                if (k === 'ts')
                    return /\bts\b/.test(t) || t.includes('hdts');
                if (k === 'cam')
                    return /\bcam\b/.test(t) || t.includes('hdcam') || t.includes('webcam');
                return true;
            }
            return false;
        });
        if (isBad) {
            console.log(`[Filter] Dropped partial/CAM torrent: ${r.title}`);
        }
        return !isBad;
    })
        .sort((a, b) => b.seeds - a.seeds);
}
async function getEpisodeTorrents(imdbId, title, season, episode) {
    if (imdbId && imdbId.startsWith('tt')) {
        const streams = await getTorrentioStreams('series', `${imdbId}:${season}:${episode}`);
        if (streams.length > 0)
            return streams;
    }
    const s = season.toString().padStart(2, '0');
    const e = episode.toString().padStart(2, '0');
    const query = `${title} S${s}E${e}`;
    const results = await searchTorrent(query);
    return results
        .filter((r) => r.magnet)
        .filter((r) => (r.seeds || 0) > 0) // Drop dead torrents — nothing to stream from
        .sort((a, b) => b.seeds - a.seeds);
}
//# sourceMappingURL=torrent.js.map