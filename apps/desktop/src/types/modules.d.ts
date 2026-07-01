declare module 'torrent-search-api' {
    export function enablePublicProviders(): void;
    export function search(query: string, category: string, limit: number): Promise<any[]>;
    // Add other methods if needed
}

declare module 'ffprobe-static' {
    const ffprobeStatic: { path: string };
    export default ffprobeStatic;
}
