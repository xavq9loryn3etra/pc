export interface StreamOption {
    magnet: string;
    quality?: string;
    size?: string;
    seeds?: number;
    title?: string;
}

export interface PlayStreamOptions {
    magnet: string;
    season?: number;
    episode?: number;
    imdbId?: string;
    quality?: string;
    availableStreams?: StreamOption[];
    seasons?: any[];
    logoUrl?: string;
    description?: string;
}
