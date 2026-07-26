import { app } from 'electron';
import path from 'path';
import fs from 'fs';

interface MediaProgress {
    progress: number; // Seconds
    duration: number; // Seconds
    lastWatched: number; // Timestamp
    magnet?: string;
}

interface HistoryStoreData {
    movies: Record<string, MediaProgress>; // Key: tmdbId
    shows: Record<string, Record<string, MediaProgress>>; // Key: tmdbId -> s{X}e{Y}
    favorites: Record<string, any>; // Key: tmdbId, Value: Movie Object
}

class HistoryStore {
    private path: string;
    private data: HistoryStoreData;

    constructor() {
        this.path = path.join(app.getPath('userData'), 'watch-history.json');
        this.data = this.load();
    }

    private load(): HistoryStoreData {
        try {
            if (fs.existsSync(this.path)) {
                return JSON.parse(fs.readFileSync(this.path, 'utf-8'));
            }
        } catch (e) {
            console.error("Failed to load history:", e);
        }
        return { movies: {}, shows: {}, favorites: {} };
    }

    private save() {
        try {
            fs.writeFileSync(this.path, JSON.stringify(this.data, null, 2));
        } catch (e) {
            console.error("Failed to save history:", e);
        }
    }

    public getProgress(tmdbId: string, season?: number, episode?: number): MediaProgress | null {
        if (season !== undefined && episode !== undefined) {
            const show = this.data.shows[tmdbId];
            if (!show) return null;
            const key = `s${season}e${episode}`;
            return show[key] || null;
        } else {
            return this.data.movies[tmdbId] || null;
        }
    }

    public updateProgress(tmdbId: string, progress: number, duration: number, season?: number, episode?: number, magnet?: string) {
        const entry: MediaProgress = {
            progress,
            duration,
            lastWatched: Date.now(),
            magnet // Added magnet to the entry
        };

        if (season !== undefined && episode !== undefined) {
            if (!this.data.shows[tmdbId]) this.data.shows[tmdbId] = {};
            const key = `s${season}e${episode}`;
            this.data.shows[tmdbId][key] = entry;
        } else {
            this.data.movies[tmdbId] = entry;
        }
        this.save();
    }
    public getHistory() {
        return this.data;
    }
    public removeProgress(tmdbId: string) {
        if (this.data.movies[tmdbId]) {
            delete this.data.movies[tmdbId];
        }
        if (this.data.shows[tmdbId]) {
            delete this.data.shows[tmdbId];
        }
        this.save();
    }

    // Favorites Logic
    public addFavorite(movie: any) {
        if (!this.data.favorites) this.data.favorites = {};
        this.data.favorites[movie.id.toString()] = movie;
        this.save();
    }

    public removeFavorite(tmdbId: string) {
        if (this.data.favorites && this.data.favorites[tmdbId]) {
            delete this.data.favorites[tmdbId];
            this.save();
        }
    }

    public getFavorites() {
        return this.data.favorites || {};
    }

    public importData(parsedData: any): boolean {
        if (typeof parsedData !== 'object' || parsedData === null) return false;

        // Check if it is the Flutter SharedPreferences backup format
        if ('favorites_v1' in parsedData || 'watch_history_v1' in parsedData || 'episode_history_v1' in parsedData) {
            console.log("Importing backup from Flutter format...");

            const importedFavorites = parsedData.favorites_v1 ? JSON.parse(parsedData.favorites_v1) : [];
            const importedHistory = parsedData.watch_history_v1 ? JSON.parse(parsedData.watch_history_v1) : {};
            const importedEpisodes = parsedData.episode_history_v1 ? JSON.parse(parsedData.episode_history_v1) : {};

            const newFavorites: Record<string, any> = {};
            const newMovies: Record<string, MediaProgress> = {};
            const newShows: Record<string, Record<string, MediaProgress>> = {};

            // 1. Map Favorites
            if (Array.isArray(importedFavorites)) {
                importedFavorites.forEach((m: any) => {
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
            Object.entries(importedHistory).forEach(([id, item]: [string, any]) => {
                const movie = item.movie || {};
                const lastWatched = item.last_watched || Date.now();
                const progressRatio = movie.progress || 0.0;

                const isTv = movie.type === 'tv';
                const duration = isTv ? 2400 : 7200;
                const progressSeconds = Math.round(progressRatio * duration);

                if (isTv) {
                    const season = movie.current_season || 1;
                    const episode = movie.current_episode || 1;

                    if (!newShows[id]) newShows[id] = {};
                    const key = `s${season}e${episode}`;
                    newShows[id][key] = {
                        progress: progressSeconds,
                        duration,
                        lastWatched
                    };
                } else {
                    newMovies[id] = {
                        progress: progressSeconds,
                        duration,
                        lastWatched
                    };
                }
            });

            // 3. Map individual episode progress (episode_history_v1)
            Object.entries(importedEpisodes).forEach(([key, val]: [string, any]) => {
                const match = key.split('_');
                if (match.length >= 3) {
                    const showId = match[0];
                    const season = match[1];
                    const episode = match[2];
                    const progressRatio = parseFloat(val) || 0;

                    const duration = 2400; // 40 minutes default
                    const progressSeconds = Math.round(progressRatio * duration);

                    if (!newShows[showId]) newShows[showId] = {};
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
                    } else {
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
        } else {
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

export const historyStore = new HistoryStore();
