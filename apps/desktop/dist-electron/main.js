"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
const electron_1 = require("electron");
const path_1 = __importDefault(require("path"));
const webtorrent_1 = __importDefault(require("webtorrent"));
// import { getTrendingMovies } from './services/imdb';
// import { initScraper, getTrendingIMDb, searchIMDb, getMoviesByGenre, getLatestMovies, getYouTubeTrailer, getTop10ThisWeek, getMovieDetails } from './services/scraper';
const tmdb_1 = require("./services/tmdb");
const torrent_1 = require("./services/torrent");
const transcode_1 = require("./services/transcode");
// Spoof Chrome User Agent for YouTube
const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
electron_1.app.userAgentFallback = CHROME_UA;
// Define the absolute path to the HTML file or URL
const MAIN_WINDOW_VITE_DEV_SERVER_URL = process.env.VITE_DEV_SERVER_URL;
const MAIN_WINDOW_VITE_NAME = 'index.html';
const fs_1 = __importDefault(require("fs"));
let mainWindow = null;
const client = new webtorrent_1.default();
let currentMagnet = null;
let currentTorrent = null;
let prewarmMagnet = null;
const TRACKERS = [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://tracker.openbittorrent.com:80/announce",
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
    "udp://ch3oh.ru:6969/announce",
    "wss://tracker.openwebtorrent.com",
    "wss://tracker.btorrent.xyz",
    "wss://tracker.webtorrent.io"
];
function cleanup() {
    const tempPath = path_1.default.join(electron_1.app.getPath('temp'), 'streamhub');
    if (fs_1.default.existsSync(tempPath)) {
        try {
            fs_1.default.rmSync(tempPath, { recursive: true, force: true });
            console.log("Cleanup successful");
        }
        catch (e) {
            console.log("Cleanup failed:", e);
        }
    }
    (0, transcode_1.cleanupTranscodeRoot)();
}
function createWindow() {
    mainWindow = new electron_1.BrowserWindow({
        title: 'Popcorn',
        icon: path_1.default.join(__dirname, '../public/icon.png'),
        width: 1200,
        height: 800,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            webSecurity: false,
            preload: path_1.default.join(__dirname, 'preload.js'),
            webviewTag: true,
            devTools: !electron_1.app.isPackaged
        },
        backgroundColor: '#000000',
        autoHideMenuBar: true,
    });
    mainWindow.setMenuBarVisibility(false);
    if (MAIN_WINDOW_VITE_DEV_SERVER_URL) {
        mainWindow.loadURL(MAIN_WINDOW_VITE_DEV_SERVER_URL);
        mainWindow.webContents.openDevTools();
    }
    else {
        mainWindow.loadFile(path_1.default.join(__dirname, '../dist/index.html'));
        mainWindow.removeMenu();
    }
    mainWindow.setMenuBarVisibility(false);
    // Disable Developer Shortcuts in Production
    if (electron_1.app.isPackaged) {
        mainWindow.webContents.on('before-input-event', (event, input) => {
            if (input.control && input.shift && input.key.toLowerCase() === 'i') {
                event.preventDefault();
            }
            if (input.key === 'F12') {
                event.preventDefault();
            }
            if (input.control && input.shift && input.key.toLowerCase() === 'r') {
                event.preventDefault();
            }
        });
    }
    // Block all popups (Native AdBlock)
    mainWindow.webContents.setWindowOpenHandler(({ url }) => {
        console.log("Blocked Popup:", url);
        return { action: 'deny' };
    });
}
// Initialize Scraper when app is ready - No longer needed for TMDB
// app.whenReady().then(() => {
//     initScraper();
// });
// IPC Handlers
electron_1.ipcMain.handle('open-external', async (_, url) => {
    return await electron_1.shell.openExternal(url);
});
electron_1.ipcMain.handle('get-trending', async () => {
    return await (0, tmdb_1.getTrendingTMDB)();
});
electron_1.ipcMain.handle('search-movies', async (event, query) => {
    return await (0, tmdb_1.searchTMDB)(query);
});
electron_1.ipcMain.handle('get-category', async (event, genre) => {
    return await (0, tmdb_1.getMoviesByGenre)(genre);
});
// ...
electron_1.ipcMain.handle('get-latest', async () => {
    return await (0, tmdb_1.getLatestTMDB)();
});
electron_1.ipcMain.handle('get-top-10', async () => {
    return await (0, tmdb_1.getPopularTMDB)();
});
electron_1.ipcMain.handle('get-movie-details', async (event, id, type) => {
    return await (0, tmdb_1.getMovieDetailsTMDB)(id, type);
});
electron_1.ipcMain.handle('get-trailer', async (event, id, type) => {
    return await (0, tmdb_1.getTrailerTMDB)(id, type);
});
electron_1.ipcMain.handle('get-magnet', async (event, imdbId, title, year) => {
    return await (0, torrent_1.getBestMagnet)(imdbId, title, year);
});
electron_1.ipcMain.handle('get-torrents', async (event, imdbId, title, year) => {
    return await (0, torrent_1.getMovieTorrents)(imdbId, title, year);
});
electron_1.ipcMain.handle('get-season-details', async (event, tvId, seasonNumber) => {
    return await (0, tmdb_1.getSeasonDetailsTMDB)(tvId, seasonNumber);
});
electron_1.ipcMain.handle('get-episode-torrents', async (event, imdbId, title, season, episode) => {
    return await (0, torrent_1.getEpisodeTorrents)(imdbId, title, season, episode);
});
electron_1.ipcMain.handle('prewarm-torrent', async (event, magnetLink) => {
    // Remove a stale prewarm if it's a different magnet
    if (prewarmMagnet && prewarmMagnet !== magnetLink && prewarmMagnet !== currentMagnet) {
        const old = client.get(prewarmMagnet);
        if (old)
            client.remove(prewarmMagnet, { destroyStore: true }, () => { });
    }
    prewarmMagnet = magnetLink;
    if (client.get(magnetLink))
        return; // Already added
    const downloadPath = path_1.default.join(electron_1.app.getPath('temp'), 'streamhub');
    client.add(magnetLink, { path: downloadPath, announce: TRACKERS }, (torrent) => {
        // Deselect all files — we only needed metadata, not video data
        torrent.files.forEach((f) => f.deselect());
        console.log('Pre-warm complete, metadata ready');
    });
});
electron_1.ipcMain.handle('cancel-prewarm', async () => {
    if (prewarmMagnet && prewarmMagnet !== currentMagnet) {
        const t = client.get(prewarmMagnet);
        if (t)
            client.remove(prewarmMagnet, { destroyStore: true }, () => { });
    }
    prewarmMagnet = null;
});
electron_1.ipcMain.handle('start-stream', async (event, magnetLink) => {
    console.log('Received magnet link:', magnetLink);
    currentMagnet = magnetLink;
    return new Promise((resolve) => {
        const doStream = (torrent) => {
            currentTorrent = torrent;
            if (prewarmMagnet === magnetLink)
                prewarmMagnet = null;
            const file = torrent.files.find((f) => f.name.endsWith('.mp4') || f.name.endsWith('.mkv') || f.name.endsWith('.avi'));
            let targetFile = file;
            if (!targetFile) {
                const largest = torrent.files.reduce((a, b) => a.length > b.length ? a : b);
                console.log('Selected largest file:', largest.name);
                targetFile = largest;
            }
            torrent.files.forEach((f) => f.deselect());
            targetFile.select();
            const server = torrent.createServer();
            server.listen(0, () => {
                const port = server.address().port;
                const url = `http://localhost:${port}/${torrent.files.indexOf(targetFile)}`;
                console.log('Stream URL:', url);
                resolve({ url, filename: targetFile.name });
            });
        };
        const addTorrent = () => {
            const downloadPath = path_1.default.join(electron_1.app.getPath('temp'), 'streamhub');
            client.add(magnetLink, { path: downloadPath, announce: TRACKERS }, (torrent) => {
                console.log('Torrent added, looking for video file...');
                doStream(torrent);
            });
        };
        const existing = client.get(magnetLink);
        if (existing) {
            const t = existing;
            if (t.ready) {
                console.log('Reusing pre-warmed torrent, metadata already ready');
                doStream(t);
            }
            else {
                console.log('Torrent connecting, waiting for metadata...');
                t.once('ready', () => doStream(t));
            }
        }
        else {
            addTorrent();
        }
    });
});
electron_1.ipcMain.handle('stop-stream', async () => {
    console.log("Stopping stream...");
    (0, transcode_1.stopTranscodeSession)();
    if (prewarmMagnet && prewarmMagnet !== currentMagnet) {
        const t = client.get(prewarmMagnet);
        if (t)
            client.remove(prewarmMagnet, { destroyStore: true }, () => { });
        prewarmMagnet = null;
    }
    if (currentMagnet) {
        return new Promise((resolve) => {
            client.remove(currentMagnet, { destroyStore: true }, (err) => {
                if (err)
                    console.error("Error cleaning up torrent:", err);
                else
                    console.log("Torrent removed and files deleted.");
                currentMagnet = null;
                currentTorrent = null;
                resolve(true);
            });
        });
    }
    return true;
});
electron_1.ipcMain.handle('get-torrent-stats', async () => {
    if (!currentTorrent)
        return null;
    return {
        numPeers: currentTorrent.numPeers || 0,
        downloadSpeed: currentTorrent.downloadSpeed || 0
    };
});
// Audio transcoding (Chromium's bundled codecs can't decode AC3/DTS, common in scene releases)
electron_1.ipcMain.handle('probe-stream', async (event, url) => {
    return await (0, transcode_1.probeMedia)(url);
});
electron_1.ipcMain.handle('start-transcode', async (event, url, startTimeSeconds) => {
    return await (0, transcode_1.startTranscodeSession)(url, startTimeSeconds || 0);
});
electron_1.ipcMain.handle('stop-transcode', async () => {
    (0, transcode_1.stopTranscodeSession)();
});
// Watch History Handlers
const store_1 = require("./services/store");
electron_1.ipcMain.handle('get-watch-progress', async (event, tmdbId, season, episode) => {
    return store_1.historyStore.getProgress(tmdbId, season, episode);
});
electron_1.ipcMain.handle('update-watch-progress', async (event, tmdbId, progress, duration, season, episode, magnet) => {
    store_1.historyStore.updateProgress(tmdbId, progress, duration, season, episode, magnet);
});
electron_1.ipcMain.handle('get-watch-history', async () => {
    return store_1.historyStore.getHistory();
});
electron_1.ipcMain.handle('remove-watch-progress', async (event, tmdbId) => {
    store_1.historyStore.removeProgress(tmdbId);
});
// Favorites Handlers
electron_1.ipcMain.handle('add-favorite', async (event, movie) => {
    store_1.historyStore.addFavorite(movie);
});
electron_1.ipcMain.handle('remove-favorite', async (event, tmdbId) => {
    store_1.historyStore.removeFavorite(tmdbId);
});
electron_1.ipcMain.handle('get-favorites', async () => {
    return store_1.historyStore.getFavorites();
});
electron_1.ipcMain.handle('export-backup', async () => {
    if (!mainWindow)
        return false;
    try {
        const { canceled, filePath } = await electron_1.dialog.showSaveDialog(mainWindow, {
            title: 'Export Backup',
            defaultPath: path_1.default.join(electron_1.app.getPath('downloads'), 'popcorn_backup.json'),
            filters: [{ name: 'JSON Files', extensions: ['json'] }]
        });
        if (canceled || !filePath)
            return false;
        const storeData = store_1.historyStore.getHistory();
        // 1. Map Favorites
        const flutterFavorites = Object.values(storeData.favorites || {}).map((m) => ({
            id: m.id,
            title: m.title,
            year: m.year,
            image: m.posterUrl || m.image || null,
            backdrop: m.backdropUrl || m.backdrop || null,
            rating: m.rating,
            vote_count: m.voteCount || 0,
            description: m.description || '',
            type: m.type,
            in_cinemas: m.inCinemas || false,
            trailer_url: m.trailerUrl || null,
            imdb_id: m.imdbId || null
        }));
        // 2. Map Watch History (using Promise.all to fetch missing metadata in parallel)
        const watchHistoryPromises = Object.entries(storeData.movies || {}).map(async ([id, progress]) => {
            let movieDetails = storeData.favorites?.[id];
            if (!movieDetails) {
                try {
                    movieDetails = await (0, tmdb_1.getMovieDetailsTMDB)(id, 'movie');
                }
                catch (e) {
                    console.error("Failed to fetch metadata for movie ID during backup:", id, e);
                }
            }
            const movieObj = {
                id,
                title: movieDetails?.title || movieDetails?.name || 'Unknown',
                year: movieDetails?.year || 0,
                image: movieDetails?.posterUrl || movieDetails?.image || null,
                backdrop: movieDetails?.backdropUrl || movieDetails?.backdrop || null,
                rating: movieDetails?.rating || 'N/A',
                vote_count: movieDetails?.voteCount || movieDetails?.vote_count || 0,
                description: movieDetails?.description || '',
                type: 'movie',
                in_cinemas: movieDetails?.inCinemas || false,
                imdb_id: movieDetails?.imdbId || movieDetails?.imdb_id || null,
                progress: progress.duration > 0 ? (progress.progress / progress.duration) : 0
            };
            return {
                id,
                entry: {
                    movie: movieObj,
                    last_watched: progress.lastWatched
                }
            };
        });
        const movieEntries = await Promise.all(watchHistoryPromises);
        const flutterWatchHistory = {};
        movieEntries.forEach(item => {
            flutterWatchHistory[item.id] = item.entry;
        });
        // 3. Map Shows & Episode History
        const flutterEpisodeHistory = {};
        Object.entries(storeData.shows || {}).forEach(([showId, episodes]) => {
            Object.entries(episodes || {}).forEach(([epKey, progress]) => {
                const match = epKey.match(/s(\d+)e(\d+)/i);
                if (match) {
                    const s = match[1];
                    const e = match[2];
                    const flutterKey = `${showId}_${s}_${e}`;
                    flutterEpisodeHistory[flutterKey] = progress.duration > 0 ? (progress.progress / progress.duration) : 0;
                }
            });
        });
        // 4. Also add parent TV show records in watch_history_v1
        const showHistoryPromises = Object.entries(storeData.shows || {}).map(async ([showId, episodes]) => {
            let latestWatched = 0;
            let latestEpisodeKey = null;
            let latestEpProgress = null;
            Object.entries(episodes || {}).forEach(([epKey, progress]) => {
                if (progress.lastWatched > latestWatched) {
                    latestWatched = progress.lastWatched;
                    latestEpisodeKey = epKey;
                    latestEpProgress = progress;
                }
            });
            if (latestEpisodeKey && latestEpProgress) {
                const match = latestEpisodeKey.match(/s(\d+)e(\d+)/i);
                if (match) {
                    const season = parseInt(match[1]);
                    const episode = parseInt(match[2]);
                    let showDetails = storeData.favorites?.[showId];
                    if (!showDetails) {
                        try {
                            showDetails = await (0, tmdb_1.getMovieDetailsTMDB)(showId, 'tv');
                        }
                        catch (e) {
                            console.error("Failed to fetch metadata for TV show ID during backup:", showId, e);
                        }
                    }
                    const showObj = {
                        id: showId,
                        title: showDetails?.title || showDetails?.name || 'Unknown TV Show',
                        year: showDetails?.year || 0,
                        image: showDetails?.posterUrl || showDetails?.image || null,
                        backdrop: showDetails?.backdropUrl || showDetails?.backdrop || null,
                        rating: showDetails?.rating || 'N/A',
                        vote_count: showDetails?.voteCount || showDetails?.vote_count || 0,
                        description: showDetails?.description || '',
                        type: 'tv',
                        in_cinemas: false,
                        imdb_id: showDetails?.imdbId || showDetails?.imdb_id || null,
                        current_season: season,
                        current_episode: episode,
                        progress: latestEpProgress.duration > 0 ? (latestEpProgress.progress / latestEpProgress.duration) : 0
                    };
                    return {
                        id: showId,
                        entry: {
                            movie: showObj,
                            last_watched: latestWatched
                        }
                    };
                }
            }
            return null;
        });
        const showEntries = await Promise.all(showHistoryPromises);
        showEntries.forEach(item => {
            if (item) {
                flutterWatchHistory[item.id] = item.entry;
            }
        });
        const backupJson = {
            favorites_v1: JSON.stringify(flutterFavorites),
            watch_history_v1: JSON.stringify(flutterWatchHistory),
            episode_history_v1: JSON.stringify(flutterEpisodeHistory),
            selected_app_mode: 0
        };
        fs_1.default.writeFileSync(filePath, JSON.stringify(backupJson, null, 2), 'utf-8');
        return true;
    }
    catch (e) {
        console.error("Export backup error:", e);
        return false;
    }
});
electron_1.ipcMain.handle('import-backup', async () => {
    if (!mainWindow)
        return false;
    try {
        const { canceled, filePaths } = await electron_1.dialog.showOpenDialog(mainWindow, {
            title: 'Import Backup',
            filters: [{ name: 'JSON Files', extensions: ['json'] }],
            properties: ['openFile']
        });
        if (canceled || filePaths.length === 0)
            return false;
        const filePath = filePaths[0];
        const rawData = fs_1.default.readFileSync(filePath, 'utf-8');
        const parsedData = JSON.parse(rawData);
        if (typeof parsedData !== 'object' || parsedData === null) {
            throw new Error("Invalid backup format");
        }
        const success = store_1.historyStore.importData(parsedData);
        return success;
    }
    catch (e) {
        console.error("Import backup error:", e);
        return false;
    }
});
electron_1.app.on('ready', createWindow);
electron_1.app.on('window-all-closed', () => {
    cleanup();
    if (process.platform !== 'darwin') {
        electron_1.app.quit();
    }
});
electron_1.app.on('activate', () => {
    if (electron_1.BrowserWindow.getAllWindows().length === 0) {
        createWindow();
    }
});
//# sourceMappingURL=main.js.map