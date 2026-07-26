"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};
Object.defineProperty(exports, "__esModule", { value: true });
exports.searchTMDB = searchTMDB;
exports.getTrendingTMDB = getTrendingTMDB;
exports.getLatestTMDB = getLatestTMDB;
exports.getPopularTMDB = getPopularTMDB;
exports.getMoviesByGenre = getMoviesByGenre;
exports.getMovieDetailsTMDB = getMovieDetailsTMDB;
exports.getSeasonDetailsTMDB = getSeasonDetailsTMDB;
exports.getTrailerTMDB = getTrailerTMDB;
const axios_1 = __importDefault(require("axios"));
const fs = __importStar(require("fs"));
const path = __importStar(require("path"));
const electron_1 = require("electron");
const omdb_1 = require("./omdb");
// --- Environment Variable Loading (Simple Implementation) ---
let TMDB_API_KEY = process.env.TMDB_API_KEY || '';
if (!TMDB_API_KEY) {
    try {
        // Try loading from app root (works in Dev and Prod/ASAR)
        const envPath = path.join(electron_1.app.getAppPath(), '.env');
        if (fs.existsSync(envPath)) {
            const lines = fs.readFileSync(envPath, 'utf-8').split('\n');
            for (const line of lines) {
                const [key, val] = line.split('=');
                if (key && (key.trim() === 'TMDB_API_KEY' || key.trim() === 'VITE_TMDB_API_KEY')) {
                    TMDB_API_KEY = val ? val.trim() : '';
                    break;
                }
            }
        }
    }
    catch (e) {
        console.error("Failed to load .env manually:", e);
    }
}
// Fallback to a hardcoded key if you want to test immediately (Not recommended for prod)
// TMDB_API_KEY = "YOUR_KEY_HERE"; 
const BASE_URL = 'https://api.themoviedb.org/3';
const IMAGE_BASE = 'https://image.tmdb.org/t/p/w500'; // w780 or original also available
const BACKDROP_BASE = 'https://image.tmdb.org/t/p/w1280';
// Genre Mapping (TMDB uses IDs)
const GENRES = {
    "action": 28,
    "adventure": 12,
    "animation": 16,
    "comedy": 35,
    "crime": 80,
    "documentary": 99,
    "drama": 18,
    "family": 10751,
    "fantasy": 14,
    "history": 36,
    "horror": 27,
    "music": 10402,
    "mystery": 9648,
    "romance": 10749,
    "science fiction": 878,
    "sci-fi": 878,
    "tv movie": 10770,
    "thriller": 53,
    "war": 10752,
    "western": 37
};
function formatMovie(m) {
    if (!m)
        return null;
    // Calculate Cinema Window (e.g. 45 days) - Only for Movies
    let inCinemas = false;
    const isTv = m.media_type === 'tv' || !!m.first_air_date;
    // Only check for movies
    if (!isTv) {
        const releaseDate = m.release_date;
        if (releaseDate) {
            const release = new Date(releaseDate);
            const now = new Date();
            const diffTime = Math.abs(now.getTime() - release.getTime());
            const diffDays = Math.ceil(diffTime / (1000 * 60 * 60 * 24));
            // If released in last 45 days OR in future
            if (release > now || diffDays < 45) {
                inCinemas = true;
            }
        }
    }
    return {
        id: String(m.id), // String ID for compatibility
        title: m.title || m.name, // 'name' for TV shows
        year: parseInt((m.release_date || m.first_air_date || '0000').substring(0, 4)),
        image: m.poster_path ? `${IMAGE_BASE}${m.poster_path}` : null,
        backdrop: m.backdrop_path ? `${BACKDROP_BASE}${m.backdrop_path}` : null,
        rating: m.vote_average ? m.vote_average.toFixed(1) : 'N/A',
        voteCount: m.vote_count || 0,
        description: m.overview,
        type: m.media_type || (m.first_air_date ? 'tv' : 'movie'),
        inCinemas: inCinemas
    };
}
async function searchTMDB(query) {
    try {
        const url = `${BASE_URL}/search/multi`;
        const res = await axios_1.default.get(url, {
            params: {
                api_key: TMDB_API_KEY,
                query: query,
                include_adult: false
            }
        });
        // Filter out people, only Movies and TV
        const results = res.data.results.filter((r) => r.media_type === 'movie' || r.media_type === 'tv');
        return results.map(formatMovie);
    }
    catch (e) {
        console.error("TMDB Search Error:", e);
        return [];
    }
}
async function getTrendingTMDB() {
    try {
        const res = await axios_1.default.get(`${BASE_URL}/trending/all/week`, {
            params: { api_key: TMDB_API_KEY }
        });
        return res.data.results.map(formatMovie);
    }
    catch (e) {
        console.error("TMDB Trending Error:", e);
        return [];
    }
}
async function getLatestTMDB() {
    try {
        // "Now Playing" is good for movies
        const res = await axios_1.default.get(`${BASE_URL}/movie/now_playing`, {
            params: { api_key: TMDB_API_KEY }
        });
        return res.data.results.map(formatMovie);
    }
    catch (e) {
        console.error("TMDB Latest Error:", e);
        return [];
    }
}
async function getPopularTMDB() {
    try {
        const res = await axios_1.default.get(`${BASE_URL}/movie/popular`, {
            params: { api_key: TMDB_API_KEY }
        });
        // Return top 10
        return res.data.results.slice(0, 10).map(formatMovie);
    }
    catch (e) {
        console.error("TMDB Popular Error:", e);
        return [];
    }
}
async function getMoviesByGenre(genreName) {
    const gid = GENRES[genreName.toLowerCase()];
    if (!gid)
        return [];
    try {
        const res = await axios_1.default.get(`${BASE_URL}/discover/movie`, {
            params: {
                api_key: TMDB_API_KEY,
                with_genres: gid,
                sort_by: 'popularity.desc'
            }
        });
        return res.data.results.map(formatMovie);
    }
    catch (e) {
        console.error("TMDB Genre Error:", e);
        return [];
    }
}
async function getMovieDetailsTMDB(id, type) {
    // 1. Try Movie (unless explicitly TV)
    if (type !== 'tv') {
        try {
            const res = await axios_1.default.get(`${BASE_URL}/movie/${id}`, {
                params: {
                    api_key: TMDB_API_KEY,
                    append_to_response: 'credits,videos,images,release_dates',
                    include_image_language: 'en,null'
                }
            });
            const m = res.data;
            let logoUrl = null;
            if (m.images && m.images.logos && m.images.logos.length > 0) {
                const logo = m.images.logos.find((l) => l.iso_639_1 === 'en') || m.images.logos[0];
                if (logo)
                    logoUrl = `${IMAGE_BASE}${logo.file_path}`;
            }
            // Extract Certification (US)
            let certification = 'PG-13'; // Default
            const releaseDates = m.release_dates?.results?.find((r) => r.iso_3166_1 === 'US');
            if (releaseDates && releaseDates.release_dates) {
                // Find the first non-empty certification
                const cert = releaseDates.release_dates.find((d) => d.certification);
                if (cert)
                    certification = cert.certification;
            }
            const director = m.credits?.crew?.find((c) => c.job === 'Director')?.name || 'Unknown';
            const cast = m.credits?.cast?.slice(0, 5).map((c) => c.name) || [];
            const genres = m.genres?.map((g) => g.name) || [];
            // Fetch OMDB Ratings
            let omdbRatings = {};
            if (m.imdb_id) {
                omdbRatings = await (0, omdb_1.getOMDBRatings)(m.imdb_id);
            }
            return {
                ...formatMovie(m),
                ...omdbRatings, // Merge OMDB ratings
                imdbId: m.imdb_id || null,
                director,
                cast,
                genres,
                logoUrl,
                runtime: m.runtime ? `${Math.floor(m.runtime / 60)}h ${m.runtime % 60}m` : '',
                mpaa: m.adult ? 'R' : certification,
                certification
            };
        }
        catch (e) {
            // If explicitly movie, fail here
            if (type === 'movie') {
                console.error("TMDB Movie Details Error:", e);
                return { error: 'Failed to load details' };
            }
            // Otherwise, continue to TV fallback
        }
    }
    // 2. Try TV (Fallback or Explicit)
    try {
        const resTv = await axios_1.default.get(`${BASE_URL}/tv/${id}`, {
            params: {
                api_key: TMDB_API_KEY,
                append_to_response: 'credits,videos,images,content_ratings,external_ids',
                include_image_language: 'en,null'
            }
        });
        const m = resTv.data;
        let logoUrl = null;
        if (m.images && m.images.logos && m.images.logos.length > 0) {
            const logo = m.images.logos.find((l) => l.iso_639_1 === 'en') || m.images.logos[0];
            if (logo)
                logoUrl = `${IMAGE_BASE}${logo.file_path}`;
        }
        // Extract TV Rating
        let certification = 'TV-14';
        const ratings = m.content_ratings?.results?.find((r) => r.iso_3166_1 === 'US');
        if (ratings)
            certification = ratings.rating;
        // Fetch OMDB Ratings (TV shows usually have imdb_id in external_ids)
        let omdbRatings = {};
        if (m.external_ids && m.external_ids.imdb_id) {
            omdbRatings = await (0, omdb_1.getOMDBRatings)(m.external_ids.imdb_id);
        }
        const cast = m.credits?.cast?.slice(0, 5).map((c) => c.name) || [];
        const genres = m.genres?.map((g) => g.name) || [];
        return {
            ...formatMovie(m),
            ...omdbRatings,
            imdbId: m.external_ids?.imdb_id || null,
            cast,
            genres,
            logoUrl,
            runtime: m.episode_run_time?.[0] ? `${m.episode_run_time[0]}m` : '',
            seasons: m.seasons || [],
            certification,
            // Override image with latest season poster if available
            image: (() => {
                if (m.seasons && m.seasons.length > 0) {
                    const sorted = [...m.seasons].sort((a, b) => b.season_number - a.season_number);
                    const latest = sorted.find((s) => s.poster_path && s.season_number > 0)
                        || sorted.find((s) => s.poster_path);
                    if (latest)
                        return `${IMAGE_BASE}${latest.poster_path}`;
                }
                return m.poster_path ? `${IMAGE_BASE}${m.poster_path}` : null;
            })()
        };
    }
    catch (err2) {
        console.error("TMDB Details Error:", err2);
        return { error: 'Failed to load details' };
    }
}
async function getSeasonDetailsTMDB(tvId, seasonNumber) {
    try {
        const res = await axios_1.default.get(`${BASE_URL}/tv/${tvId}/season/${seasonNumber}`, {
            params: { api_key: TMDB_API_KEY }
        });
        return res.data.episodes.map((e) => ({
            id: e.id,
            episode_number: e.episode_number,
            name: e.name,
            overview: e.overview,
            still_path: e.still_path ? `${IMAGE_BASE}${e.still_path}` : null,
            air_date: e.air_date,
            vote_average: e.vote_average
        }));
    }
    catch (e) {
        console.error("TMDB Season Details Error:", e);
        return [];
    }
}
async function getTrailerTMDB(id, type) {
    try {
        let videos = [];
        if (type === 'tv') {
            const res = await axios_1.default.get(`${BASE_URL}/tv/${id}/videos`, { params: { api_key: TMDB_API_KEY } });
            videos = res.data.results;
        }
        else if (type === 'movie') {
            const res = await axios_1.default.get(`${BASE_URL}/movie/${id}/videos`, { params: { api_key: TMDB_API_KEY } });
            videos = res.data.results;
        }
        else {
            // Type unknown — fall back to the old guess-and-check behavior
            try {
                const res = await axios_1.default.get(`${BASE_URL}/movie/${id}/videos`, { params: { api_key: TMDB_API_KEY } });
                videos = res.data.results;
            }
            catch {
                const res = await axios_1.default.get(`${BASE_URL}/tv/${id}/videos`, { params: { api_key: TMDB_API_KEY } });
                videos = res.data.results;
            }
        }
        // Find "Trailer" type, official from YouTube
        const trailer = videos.find((v) => v.site === 'YouTube' && v.type === 'Trailer' && v.official) || videos.find((v) => v.site === 'YouTube' && v.type === 'Trailer')
            || videos.find((v) => v.site === 'YouTube'); // Fallback
        return trailer ? trailer.key : null;
    }
    catch (e) {
        console.error("TMDB Trailer Error:", e);
        return null;
    }
}
//# sourceMappingURL=tmdb.js.map