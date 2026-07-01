export interface Movie {
    id: string;
    title: string;
    description: string;
    posterUrl: string; // Scraper returns 'image', we map to this
    backdropUrl: string;
    magnetLink?: string; // Optional now, fetched on demand
    year: number;
    duration?: string;
    rating?: string;
    voteCount?: number;
    inCinemas?: boolean;
    logoUrl?: string; // High-res PNG logo
    type?: 'movie' | 'tv';
    season?: number;
    episode?: number;
}

// Fallback data
export const MOVIES: Movie[] = [];
