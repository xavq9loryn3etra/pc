export interface ElectronAPI {
    prewarmTorrent: (magnetLink: string) => Promise<void>;
    cancelPrewarm: () => Promise<void>;
    startStream: (magnetLink: string) => Promise<{ url: string; filename: string }>;
    stopStream: () => Promise<boolean>;
    getTorrentStats: () => Promise<{ numPeers: number; downloadSpeed: number } | null>;
    probeStream: (url: string) => Promise<{ needsTranscode: boolean; duration: number; audioCodec?: string }>;
    startTranscode: (url: string, startTimeSeconds?: number) => Promise<{ playlistUrl: string }>;
    stopTranscode: () => Promise<void>;
    getTrending: () => Promise<any[]>;
    getLatest: () => Promise<any[]>;
    getTop10: () => Promise<any[]>;
    getTrailer: (id: string) => Promise<string | null>;
    searchMovies: (query: string) => Promise<any[]>;
    getCategory: (genre: string) => Promise<any[]>;
    getTorrents: (imdbId: string | null | undefined, title: string, year: number) => Promise<any[]>;
    getMagnet: (imdbId: string | null | undefined, title: string, year: number) => Promise<string | null>;
    getMovieDetails: (id: string, type?: string) => Promise<any>;
    getSeasonDetails: (tvId: string, seasonNumber: number) => Promise<any>;
    getEpisodeTorrents: (imdbId: string | null | undefined, title: string, season: number, episode: number) => Promise<any[]>;
    getWatchProgress: (tmdbId: string, season?: number, episode?: number) => Promise<{ progress: number; duration: number; lastWatched: number } | null>;
    updateWatchProgress: (tmdbId: string, progress: number, duration: number, season?: number, episode?: number, magnet?: string) => Promise<void>;
    removeWatchProgress: (tmdbId: string) => Promise<void>;
    getWatchHistory: () => Promise<any>;
    addFavorite: (movie: any) => Promise<void>;
    removeFavorite: (tmdbId: string) => Promise<void>;
    getFavorites: () => Promise<any>;
    openExternal: (url: string) => Promise<void>;
    exportBackup: () => Promise<boolean>;
    importBackup: () => Promise<boolean>;
}


declare global {
    interface Window {
        electronAPI: ElectronAPI;
    }
}
