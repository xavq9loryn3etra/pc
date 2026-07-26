"use strict";
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.historyStore = void 0;
const electron_1 = require("electron");
const path_1 = __importDefault(require("path"));
const fs_1 = __importDefault(require("fs"));
class HistoryStore {
    constructor() {
        this.path = path_1.default.join(electron_1.app.getPath('userData'), 'watch-history.json');
        this.data = this.load();
    }
    load() {
        try {
            if (fs_1.default.existsSync(this.path)) {
                return JSON.parse(fs_1.default.readFileSync(this.path, 'utf-8'));
            }
        }
        catch (e) {
            console.error("Failed to load history:", e);
        }
        return { movies: {}, shows: {}, favorites: {} };
    }
    save() {
        try {
            fs_1.default.writeFileSync(this.path, JSON.stringify(this.data, null, 2));
        }
        catch (e) {
            console.error("Failed to save history:", e);
        }
    }
    getProgress(tmdbId, season, episode) {
        if (season !== undefined && episode !== undefined) {
            const show = this.data.shows[tmdbId];
            if (!show)
                return null;
            const key = `s${season}e${episode}`;
            return show[key] || null;
        }
        else {
            return this.data.movies[tmdbId] || null;
        }
    }
    updateProgress(tmdbId, progress, duration, season, episode, magnet) {
        const entry = {
            progress,
            duration,
            lastWatched: Date.now(),
            magnet // Added magnet to the entry
        };
        if (season !== undefined && episode !== undefined) {
            if (!this.data.shows[tmdbId])
                this.data.shows[tmdbId] = {};
            const key = `s${season}e${episode}`;
            this.data.shows[tmdbId][key] = entry;
        }
        else {
            this.data.movies[tmdbId] = entry;
        }
        this.save();
    }
    getHistory() {
        return this.data;
    }
    removeProgress(tmdbId) {
        if (this.data.movies[tmdbId]) {
            delete this.data.movies[tmdbId];
        }
        if (this.data.shows[tmdbId]) {
            delete this.data.shows[tmdbId];
        }
        this.save();
    }
    // Favorites Logic
    addFavorite(movie) {
        if (!this.data.favorites)
            this.data.favorites = {};
        this.data.favorites[movie.id.toString()] = movie;
        this.save();
    }
    removeFavorite(tmdbId) {
        if (this.data.favorites && this.data.favorites[tmdbId]) {
            delete this.data.favorites[tmdbId];
            this.save();
        }
    }
    getFavorites() {
        return this.data.favorites || {};
    }
    importData(parsedData) {
        if (typeof parsedData !== 'object' || parsedData === null)
            return false;
        // Check if it is the Flutter SharedPreferences backup format
        if ('favorites_v1' in parsedData || 'watch_history_v1' in parsedData || 'episode_history_v1' in parsedData) {
            console.log("Importing backup from Flutter format...");
            const importedFavorites = parsedData.favorites_v1 ? JSON.parse(parsedData.favorites_v1) : [];
            const importedHistory = parsedData.watch_history_v1 ? JSON.parse(parsedData.watch_history_v1) : {};
            const importedEpisodes = parsedData.episode_history_v1 ? JSON.parse(parsedData.episode_history_v1) : {};
            const newFavorites = {};
            const newMovies = {};
            const newShows = {};
            // 1. Map Favorites
            if (Array.isArray(importedFavorites)) {
                importedFavorites.forEach((m) => {
                    if (m && m.id) {
                        newFavorites[m.id.toString()] = {
                            id: m.id.toString(),
                            title: m.title || '',
                            year: m.year || 0,
                            posterUrl: m.image || m.posterUrl || null,
                            backdropUrl: m.backdrop || m.backdropUrl || null,
                            rating: m.rating || 'N/A',
                            voteCount: m.vote_count || m.voteCount || 0,
                            description: m.description || '',
                            type: m.type || 'movie',
                            inCinemas: m.in_cinemas || m.inCinemas || false,
                            trailerUrl: m.trailer_url || m.trailerUrl || null,
                            imdbId: m.imdb_id || m.imdbId || null
                        };
                    }
                });
            }
            // 2. Map Watch History
            Object.entries(importedHistory).forEach(([id, item]) => {
                const movie = item.movie || {};
                const lastWatched = item.last_watched || Date.now();
                const progressRatio = movie.progress || 0.0;
                const isTv = movie.type === 'tv';
                const duration = isTv ? 2400 : 7200;
                const progressSeconds = Math.round(progressRatio * duration);
                if (isTv) {
                    const season = movie.current_season || 1;
                    const episode = movie.current_episode || 1;
                    if (!newShows[id])
                        newShows[id] = {};
                    const key = `s${season}e${episode}`;
                    newShows[id][key] = {
                        progress: progressSeconds,
                        duration,
                        lastWatched
                    };
                }
                else {
                    newMovies[id] = {
                        progress: progressSeconds,
                        duration,
                        lastWatched
                    };
                }
            });
            // 3. Map individual episode progress (episode_history_v1)
            Object.entries(importedEpisodes).forEach(([key, val]) => {
                const match = key.split('_');
                if (match.length >= 3) {
                    const showId = match[0];
                    const season = match[1];
                    const episode = match[2];
                    const progressRatio = parseFloat(val) || 0;
                    const duration = 2400; // 40 minutes default
                    const progressSeconds = Math.round(progressRatio * duration);
                    if (!newShows[showId])
                        newShows[showId] = {};
                    const epKey = `s${season}e${episode}`;
                    const existing = newShows[showId][epKey];
                    if (!existing) {
                        const parentHistory = importedHistory[showId];
                        const parentLastWatched = parentHistory ? parentHistory.last_watched : Date.now();
                        newShows[showId][epKey] = {
                            progress: progressSeconds,
                            duration,
                            lastWatched: parentLastWatched - 1000 // Slightly older so it doesn't override active ep
                        };
                    }
                    else {
                        // Just update the progress if different (though it should be the same)
                        existing.progress = progressSeconds;
                    }
                }
            });
            this.data = {
                movies: newMovies,
                shows: newShows,
                favorites: newFavorites
            };
            this.save();
            return true;
        }
        else {
            // Native format
            console.log("Importing backup from native Electron format...");
            this.data = {
                movies: parsedData.movies || {},
                shows: parsedData.shows || {},
                favorites: parsedData.favorites || {}
            };
            this.save();
            return true;
        }
    }
}
exports.historyStore = new HistoryStore();
//# sourceMappingURL=store.js.map