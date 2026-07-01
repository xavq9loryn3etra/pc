export interface SubtitleTrackData {
    id: string;
    url: string;
    lang: string;
}

// Mirrors Flutter's SubtitleService: Stremio's OpenSubtitles v3 addon.
// Movies: https://opensubtitles-v3.strem.io/subtitles/movie/{imdbId}.json
// Series: https://opensubtitles-v3.strem.io/subtitles/series/{imdbId}:{season}:{episode}.json
export async function fetchSubtitles(imdbId: string, season?: number, episode?: number): Promise<SubtitleTrackData[]> {
    try {
        const url = (season != null && episode != null)
            ? `https://opensubtitles-v3.strem.io/subtitles/series/${imdbId}:${season}:${episode}.json`
            : `https://opensubtitles-v3.strem.io/subtitles/movie/${imdbId}.json`;

        const res = await fetch(url);
        if (!res.ok) return [];
        const data = await res.json();
        const subs = data?.subtitles;
        if (!Array.isArray(subs)) return [];

        return subs.map((s: any) => ({
            id: String(s?.id ?? ''),
            url: String(s?.url ?? ''),
            lang: String(s?.lang ?? '')
        }));
    } catch (e) {
        console.error('SubtitleService Error:', e);
        return [];
    }
}

// The addon serves .srt files; browsers' <track> only understands WebVTT.
function srtToVtt(srt: string): string {
    const normalized = srt.replace(/\r+/g, '');
    const withDotTimestamps = normalized.replace(/(\d{2}:\d{2}:\d{2}),(\d{3})/g, '$1.$2');
    return `WEBVTT\n\n${withDotTimestamps}`;
}

// Fetches the raw subtitle file and returns a blob: URL of the converted VTT, suitable for <track src>.
export async function fetchSubtitleAsVttUrl(srtUrl: string): Promise<string | null> {
    try {
        const res = await fetch(srtUrl);
        if (!res.ok) return null;
        const text = await res.text();
        const vtt = srtToVtt(text);
        const blob = new Blob([vtt], { type: 'text/vtt' });
        return URL.createObjectURL(blob);
    } catch (e) {
        console.error('Subtitle conversion failed:', e);
        return null;
    }
}

// Mirrors Flutter's _getLanguageName mapping.
export function getLanguageName(code: string): string {
    const c = code.toLowerCase().trim();
    const names: Record<string, string> = {
        eng: 'English', en: 'English',
        spa: 'Spanish', es: 'Spanish',
        fre: 'French', fra: 'French', fr: 'French',
        ger: 'German', deu: 'German', de: 'German',
        ita: 'Italian', it: 'Italian',
        por: 'Portuguese', pt: 'Portuguese',
        rus: 'Russian', ru: 'Russian',
        chi: 'Chinese', zho: 'Chinese', zh: 'Chinese',
        jpn: 'Japanese', ja: 'Japanese',
        ara: 'Arabic', ar: 'Arabic',
        tur: 'Turkish', tr: 'Turkish',
        dut: 'Dutch', nld: 'Dutch', nl: 'Dutch',
        swe: 'Swedish', sv: 'Swedish',
        nor: 'Norwegian', no: 'Norwegian',
        dan: 'Danish', da: 'Danish',
        fin: 'Finnish', fi: 'Finnish',
        pol: 'Polish', pl: 'Polish',
        ind: 'Indonesian', id: 'Indonesian',
        vie: 'Vietnamese', vi: 'Vietnamese',
        hin: 'Hindi', hi: 'Hindi'
    };
    return names[c] || code.toUpperCase();
}
