import { app, BrowserWindow, ipcMain, session, shell, dialog } from 'electron';
import path from 'path';
import WebTorrent from 'webtorrent';
// import { getTrendingMovies } from './services/imdb';
// import { initScraper, getTrendingIMDb, searchIMDb, getMoviesByGenre, getLatestMovies, getYouTubeTrailer, getTop10ThisWeek, getMovieDetails } from './services/scraper';
import {
    getTrendingTMDB,
    searchTMDB,
    getMoviesByGenre,
    getLatestTMDB,
    getTrailerTMDB,
    getPopularTMDB,
    getMovieDetailsTMDB,
    getSeasonDetailsTMDB
} from './services/tmdb';
import { getBestMagnet, getMovieTorrents, getEpisodeTorrents } from './services/torrent';
import { probeMedia, startTranscodeSession, stopTranscodeSession, cleanupTranscodeRoot } from './services/transcode';

// Spoof Chrome User Agent for YouTube
const CHROME_UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
app.userAgentFallback = CHROME_UA;

// Define the absolute path to the HTML file or URL
const MAIN_WINDOW_VITE_DEV_SERVER_URL = process.env.VITE_DEV_SERVER_URL;
const MAIN_WINDOW_VITE_NAME = 'index.html';

import fs from 'fs';

let mainWindow: BrowserWindow | null = null;
const client = new WebTorrent();
let currentMagnet: string | null = null;
let currentTorrent: any = null;
let prewarmMagnet: string | null = null;

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
    const tempPath = path.join(app.getPath('temp'), 'streamhub');
    if (fs.existsSync(tempPath)) {
        try {
            fs.rmSync(tempPath, { recursive: true, force: true });
            console.log("Cleanup successful");
        } catch (e) {
            console.log("Cleanup failed:", e);
        }
    }
    cleanupTranscodeRoot();
}

function createWindow() {
    mainWindow = new BrowserWindow({
        title: 'Popcorn',
        icon: path.join(__dirname, '../public/icon.png'),
        width: 1200,
        height: 800,
        webPreferences: {
            nodeIntegration: false,
            contextIsolation: true,
            webSecurity: false,
            preload: path.join(__dirname, 'preload.js'),
            webviewTag: true,
            devTools: !app.isPackaged
        },
        backgroundColor: '#000000',
        autoHideMenuBar: true,
    });

    mainWindow.setMenuBarVisibility(false);

    if (MAIN_WINDOW_VITE_DEV_SERVER_URL) {
        mainWindow.loadURL(MAIN_WINDOW_VITE_DEV_SERVER_URL);
        mainWindow.webContents.openDevTools();
    } else {
        mainWindow.loadFile(path.join(__dirname, '../dist/index.html'));
        mainWindow.removeMenu();
    }

    mainWindow.setMenuBarVisibility(false);

    // Disable Developer Shortcuts in Production
    if (app.isPackaged) {
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
ipcMain.handle('open-external', async (_, url) => {
    return await shell.openExternal(url);
});

ipcMain.handle('get-trending', async () => {
    return await getTrendingTMDB();
});

ipcMain.handle('search-movies', async (event, query) => {
    return await searchTMDB(query);
});

ipcMain.handle('get-category', async (event, genre) => {
    return await getMoviesByGenre(genre);
});



// ...

ipcMain.handle('get-latest', async () => {
    return await getLatestTMDB();
});

ipcMain.handle('get-top-10', async () => {
    return await getPopularTMDB();
});



ipcMain.handle('get-movie-details', async (event, id, type) => {
    return await getMovieDetailsTMDB(id, type);
});

ipcMain.handle('get-trailer', async (event, id, type) => {
    return await getTrailerTMDB(id, type);
});

ipcMain.handle('get-magnet', async (event, imdbId, title, year) => {
    return await getBestMagnet(imdbId, title, year);
});

ipcMain.handle('get-torrents', async (event, imdbId, title, year) => {
    return await getMovieTorrents(imdbId, title, year);
});

ipcMain.handle('get-season-details', async (event, tvId, seasonNumber) => {
    return await getSeasonDetailsTMDB(tvId, seasonNumber);
});

ipcMain.handle('get-episode-torrents', async (event, imdbId, title, season, episode) => {
    return await getEpisodeTorrents(imdbId, title, season, episode);
});

ipcMain.handle('prewarm-torrent', async (event, magnetLink) => {
    // Remove a stale prewarm if it's a different magnet
    if (prewarmMagnet && prewarmMagnet !== magnetLink && prewarmMagnet !== currentMagnet) {
        const old = client.get(prewarmMagnet);
        if (old as unknown as boolean) (client as any).remove(prewarmMagnet, { destroyStore: true }, () => {});
    }
    prewarmMagnet = magnetLink;

    if (client.get(magnetLink) as unknown as boolean) return; // Already added

    const downloadPath = path.join(app.getPath('temp'), 'streamhub');
    client.add(magnetLink, { path: downloadPath, announce: TRACKERS }, (torrent: any) => {
        // Deselect all files — we only needed metadata, not video data
        torrent.files.forEach((f: any) => f.deselect());
        console.log('Pre-warm complete, metadata ready');
    });
});

ipcMain.handle('cancel-prewarm', async () => {
    if (prewarmMagnet && prewarmMagnet !== currentMagnet) {
        const t = client.get(prewarmMagnet);
        if (t as unknown as boolean) (client as any).remove(prewarmMagnet, { destroyStore: true }, () => {});
    }
    prewarmMagnet = null;
});

ipcMain.handle('start-stream', async (event, magnetLink) => {
    console.log('Received magnet link:', magnetLink);
    currentMagnet = magnetLink;

    return new Promise((resolve) => {
        const doStream = (torrent: any) => {
            currentTorrent = torrent;
            if (prewarmMagnet === magnetLink) prewarmMagnet = null;

            const file = torrent.files.find((f: any) => f.name.endsWith('.mp4') || f.name.endsWith('.mkv') || f.name.endsWith('.avi'));
            let targetFile = file;
            if (!targetFile) {
                const largest = torrent.files.reduce((a: any, b: any) => a.length > b.length ? a : b);
                console.log('Selected largest file:', largest.name);
                targetFile = largest;
            }

            torrent.files.forEach((f: any) => f.deselect());
            targetFile.select();

            const server = torrent.createServer();
            server.listen(0, () => {
                const port = (server.address() as any).port;
                const url = `http://localhost:${port}/${torrent.files.indexOf(targetFile)}`;
                console.log('Stream URL:', url);
                resolve({ url, filename: targetFile.name });
            });
        };

        const addTorrent = () => {
            const downloadPath = path.join(app.getPath('temp'), 'streamhub');
            client.add(magnetLink, { path: downloadPath, announce: TRACKERS }, (torrent: any) => {
                console.log('Torrent added, looking for video file...');
                doStream(torrent);
            });
        };

        const existing = client.get(magnetLink);
        if (existing as unknown as boolean) {
            const t = existing as any;
            if (t.ready) {
                console.log('Reusing pre-warmed torrent, metadata already ready');
                doStream(t);
            } else {
                console.log('Torrent connecting, waiting for metadata...');
                t.once('ready', () => doStream(t));
            }
        } else {
            addTorrent();
        }
    });
});

ipcMain.handle('stop-stream', async () => {
    console.log("Stopping stream...");
    stopTranscodeSession();

    if (prewarmMagnet && prewarmMagnet !== currentMagnet) {
        const t = client.get(prewarmMagnet);
        if (t as unknown as boolean) (client as any).remove(prewarmMagnet, { destroyStore: true }, () => {});
        prewarmMagnet = null;
    }

    if (currentMagnet) {
        return new Promise((resolve) => {
            client.remove(currentMagnet!, { destroyStore: true }, (err) => {
                if (err) console.error("Error cleaning up torrent:", err);
                else console.log("Torrent removed and files deleted.");
                currentMagnet = null;
                currentTorrent = null;
                resolve(true);
            });
        });
    }
    return true;
});

ipcMain.handle('get-torrent-stats', async () => {
    if (!currentTorrent) return null;
    return {
        numPeers: currentTorrent.numPeers || 0,
        downloadSpeed: currentTorrent.downloadSpeed || 0
    };
});

// Audio transcoding (Chromium's bundled codecs can't decode AC3/DTS, common in scene releases)
ipcMain.handle('probe-stream', async (event, url) => {
    return await probeMedia(url);
});

ipcMain.handle('start-transcode', async (event, url, startTimeSeconds) => {
    return await startTranscodeSession(url, startTimeSeconds || 0);
});

ipcMain.handle('stop-transcode', async () => {
    stopTranscodeSession();
});

// Watch History Handlers
import { historyStore } from './services/store';

ipcMain.handle('get-watch-progress', async (event, tmdbId, season, episode) => {
    return historyStore.getProgress(tmdbId, season, episode);
});

ipcMain.handle('update-watch-progress', async (event, tmdbId, progress, duration, season, episode, magnet) => {
    historyStore.updateProgress(tmdbId, progress, duration, season, episode, magnet);
});

ipcMain.handle('get-watch-history', async () => {
    return historyStore.getHistory();
});

ipcMain.handle('remove-watch-progress', async (event, tmdbId) => {
    historyStore.removeProgress(tmdbId);
});

// Favorites Handlers
ipcMain.handle('add-favorite', async (event, movie) => {
    historyStore.addFavorite(movie);
});

ipcMain.handle('remove-favorite', async (event, tmdbId) => {
    historyStore.removeFavorite(tmdbId);
});

ipcMain.handle('get-favorites', async () => {
    return historyStore.getFavorites();
});

ipcMain.handle('export-backup', async () => {
    if (!mainWindow) return false;
    try {
        const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
            title: 'Export Backup',
            defaultPath: path.join(app.getPath('downloads'), 'popcorn_backup.json'),
            filters: [{ name: 'JSON Files', extensions: ['json'] }]
        });

        if (canceled || !filePath) return false;

        const storeData = historyStore.getHistory();

        // 1. Map Favorites
        const flutterFavorites = Object.values(storeData.favorites || {}).map((m: any) => ({
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
                    movieDetails = await getMovieDetailsTMDB(id, 'movie');
                } catch (e) {
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
        const flutterWatchHistory: Record<string, any> = {};
        movieEntries.forEach(item => {
            flutterWatchHistory[item.id] = item.entry;
        });

        // 3. Map Shows & Episode History
        const flutterEpisodeHistory: Record<string, number> = {};
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
            let latestEpisodeKey: string | null = null;
            let latestEpProgress: any = null;

            Object.entries(episodes || {}).forEach(([epKey, progress]) => {
                if (progress.lastWatched > latestWatched) {
                    latestWatched = progress.lastWatched;
                    latestEpisodeKey = epKey;
                    latestEpProgress = progress;
                }
            });

            if (latestEpisodeKey && latestEpProgress) {
                const match = (latestEpisodeKey as string).match(/s(\d+)e(\d+)/i);
                if (match) {
                    const season = parseInt(match[1]);
                    const episode = parseInt(match[2]);

                    let showDetails = storeData.favorites?.[showId];
                    if (!showDetails) {
                        try {
                            showDetails = await getMovieDetailsTMDB(showId, 'tv');
                        } catch (e) {
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

        fs.writeFileSync(filePath, JSON.stringify(backupJson, null, 2), 'utf-8');
        return true;
    } catch (e) {
        console.error("Export backup error:", e);
        return false;
    }
});

ipcMain.handle('import-backup', async () => {
    if (!mainWindow) return false;
    try {
        const { canceled, filePaths } = await dialog.showOpenDialog(mainWindow, {
            title: 'Import Backup',
            filters: [{ name: 'JSON Files', extensions: ['json'] }],
            properties: ['openFile']
        });

        if (canceled || filePaths.length === 0) return false;

        const filePath = filePaths[0];
        const rawData = fs.readFileSync(filePath, 'utf-8');
        const parsedData = JSON.parse(rawData);

        if (typeof parsedData !== 'object' || parsedData === null) {
            throw new Error("Invalid backup format");
        }

        const success = historyStore.importData(parsedData);
        return success;
    } catch (e) {
        console.error("Import backup error:", e);
        return false;
    }
});

app.on('ready', createWindow);

app.on('window-all-closed', () => {
    cleanup();
    if ((process.platform as any) !== 'darwin') {
        app.quit();
    }
});

app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
    }
});
