import React, { useRef, useEffect, useState, useCallback } from 'react';
import Hls from 'hls.js';
import type { WebProvider } from './WebPlayer';
import { fetchSubtitles, fetchSubtitleAsVttUrl, getLanguageName, type SubtitleTrackData } from '../services/subtitles';
import type { StreamOption } from '../types/stream';
import EpisodeDrawer from './EpisodeDrawer';
import SourceCard from './SourceCard';

// Same 4 web servers as DetailsPanel's "Select Source" grid, offered as a fallback when picking an episode's source.
const WEB_SERVERS: { provider: WebProvider; label: string; accentColor: string }[] = [
    { provider: 'vidlink', label: 'Server 1', accentColor: '#8A2BE2' },
    { provider: 'moviesapi', label: 'Server 2', accentColor: '#2b8ae2' },
    { provider: 'vidking', label: 'Server 3', accentColor: '#e2a82b' },
    { provider: 'vsembed', label: 'Server 4', accentColor: '#4caf50' },
];

interface VideoPlayerProps {
    url: string;
    onClose: () => void;
    onWebStream?: (tmdbId: string, season?: number, episode?: number, provider?: WebProvider) => void;
    tmdbId?: string;
    season?: number;
    episode?: number;
    magnet?: string;
    imdbId?: string;
    title?: string;
    movieType?: 'movie' | 'tv';
    logoUrl?: string;
    description?: string;
    quality?: string;
    availableStreams?: StreamOption[];
    seasons?: any[];
}

const SKIP_SECONDS = 10;
const CONTROLS_HIDE_DELAY = 4000;

function formatDuration(seconds: number): string {
    if (!isFinite(seconds) || seconds < 0) seconds = 0;
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60).toString().padStart(2, '0');
    const secs = Math.floor(seconds % 60).toString().padStart(2, '0');
    return hours > 0 ? `${hours}:${minutes}:${secs}` : `${minutes}:${secs}`;
}

function isEpisodeFuture(airDate?: string): boolean {
    if (!airDate) return false;
    const date = new Date(airDate);
    return !isNaN(date.getTime()) && date > new Date();
}

// Selection tile shared by the Quality and Subtitles pickers — mirrors Flutter's PlayerSettingsPanel._buildSelectionTile
const SelectionTile: React.FC<{ title: string; subtitle?: string; isSelected: boolean; onClick: () => void }> = ({ title, subtitle, isSelected, onClick }) => (
    <button
        onClick={onClick}
        style={{
            display: 'block', width: '100%', textAlign: 'left', border: '1px solid',
            borderColor: isSelected ? 'var(--primary-color)' : 'transparent',
            background: isSelected ? 'rgba(181,150,110,0.12)' : 'rgba(255,255,255,0.03)',
            borderRadius: '10px', padding: '12px 14px', marginBottom: '8px', cursor: 'pointer'
        }}
    >
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '8px' }}>
            <div style={{ minWidth: 0 }}>
                <div style={{ color: 'white', fontWeight: 700, fontSize: '15px' }}>{title}</div>
                {subtitle && <div style={{ color: 'rgba(255,255,255,0.4)', fontSize: '12px', marginTop: '3px' }}>{subtitle}</div>}
            </div>
            {isSelected && (
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="var(--primary-color)" strokeWidth="2" style={{ flexShrink: 0 }}>
                    <path d="M22 11.08V12a10 10 0 11-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline>
                </svg>
            )}
        </div>
    </button>
);

const PillButton: React.FC<{ onClick: () => void; disabled?: boolean; iconColor?: string; children: React.ReactNode; muted?: boolean }> = ({ onClick, disabled, iconColor, children, muted }) => (
    <button
        onClick={onClick}
        disabled={disabled}
        style={{
            background: 'rgba(255,255,255,0.08)', border: 'none', borderRadius: '8px',
            padding: '9px 16px', display: 'flex', alignItems: 'center', gap: '8px',
            cursor: disabled ? 'default' : 'pointer', color: muted ? 'rgba(255,255,255,0.38)' : (iconColor || 'white'),
            opacity: disabled ? 0.6 : 1
        }}
    >
        {children}
    </button>
);

const VideoPlayer: React.FC<VideoPlayerProps> = ({
    url, onClose, onWebStream, tmdbId, season, episode, magnet, imdbId, title,
    movieType, logoUrl, description, quality, availableStreams, seasons
}) => {
    const videoRef = useRef<HTMLVideoElement>(null);
    const progressBarRef = useRef<HTMLDivElement>(null);
    const lastUpdateRef = useRef(0);
    const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
    const lastSubtitleBlobUrlRef = useRef<string | null>(null);
    const pendingResumeRef = useRef<number | null>(null);
    const hlsRef = useRef<Hls | null>(null);
    // Absolute timeline offset of the current HLS transcode session (0 unless audio needed transcoding) —
    // ffmpeg always starts a fresh session's internal time near 0, so we add this back on for display/seeking.
    const transcodeBaseRef = useRef(0);

    const [isPlaying, setIsPlaying] = useState(false);
    const [currentTime, setCurrentTime] = useState(0);
    const [duration, setDuration] = useState(0);
    const [bufferedEnd, setBufferedEnd] = useState(0);
    const [isSeeking, setIsSeeking] = useState(false);
    const [seekPreview, setSeekPreview] = useState(0);
    const [controlsVisible, setControlsVisible] = useState(true);
    const [skipFlash, setSkipFlash] = useState<{ dir: 'back' | 'forward'; id: number } | null>(null);

    // Torrent stats (peers / download speed)
    const [torrentStats, setTorrentStats] = useState<{ numPeers: number; downloadSpeed: number } | null>(null);

    // Subtitles
    const [availableSubtitles, setAvailableSubtitles] = useState<SubtitleTrackData[]>([]);
    const [selectedSubtitle, setSelectedSubtitle] = useState<SubtitleTrackData | null>(null);
    const [isLoadingSubtitles, setIsLoadingSubtitles] = useState(false);
    const [subtitleVttUrl, setSubtitleVttUrl] = useState<string | null>(null);
    const [showSubtitleMenu, setShowSubtitleMenu] = useState(false);

    // Mutable playback session state (changes on quality switch / episode switch)
    const [internalUrl, setInternalUrl] = useState(url);
    // Set only when the source's audio needs transcoding (AC3/DTS -> AAC) — points hls.js at the
    // local ffmpeg-fed HLS server instead of letting <video> load internalUrl directly.
    const [hlsPlaylistUrl, setHlsPlaylistUrl] = useState<string | null>(null);
    const [probedDuration, setProbedDuration] = useState<number | null>(null);
    const [currentMagnet, setCurrentMagnet] = useState(magnet);
    const [currentQuality, setCurrentQuality] = useState(quality);
    const [currentStreams, setCurrentStreams] = useState<StreamOption[]>(availableStreams || []);
    const [currentSeason, setCurrentSeason] = useState(season);
    const [currentEpisode, setCurrentEpisode] = useState(episode);
    const [showQualityMenu, setShowQualityMenu] = useState(false);
    const [isSwitching, setIsSwitching] = useState(false);
    const [switchingMessage, setSwitchingMessage] = useState('');

    // Episode metadata (for the "Now Playing" panel + Next Episode logic)
    const [playingSeasonEpisodes, setPlayingSeasonEpisodes] = useState<any[]>([]);

    // Episode Drawer (browsing may differ from what's actually playing)
    const [showEpisodeDrawer, setShowEpisodeDrawer] = useState(false);
    const [browsingSeason, setBrowsingSeason] = useState(season || 1);
    const [drawerEpisodes, setDrawerEpisodes] = useState<any[]>([]);
    const [loadingDrawerEpisodes, setLoadingDrawerEpisodes] = useState(false);
    const [drawerProgress, setDrawerProgress] = useState<Record<number, number>>({});

    // Source picker shown when tapping an episode in the drawer (lets the user choose quality/server)
    const [episodeSourcePicker, setEpisodeSourcePicker] = useState<{
        season: number; episode: number; episodeName?: string; streams: StreamOption[]; loading: boolean;
    } | null>(null);

    const isTv = movieType === 'tv';

    // probedDuration (the real file length from ffprobe) stands in for the native video duration while
    // transcoding, since an in-progress HLS session reports Infinity/partial length until ffmpeg finishes.
    const effectiveDuration = probedDuration || duration;
    const bufferedAbsolute = hlsPlaylistUrl ? transcodeBaseRef.current + bufferedEnd : bufferedEnd;

    // Starts (or resumes) playback at a given source URL + absolute start time. Probes the file's
    // audio codec first — if Chromium can't decode it (AC3/DTS, common in scene releases), spins up
    // an ffmpeg HLS transcode session instead of handing the URL straight to <video>.
    const startPlaybackFor = useCallback(async (urlToPlay: string, startTimeSeconds: number) => {
        pendingResumeRef.current = startTimeSeconds || null;
        setHlsPlaylistUrl(null);
        setProbedDuration(null);
        setBufferedEnd(0);

        if (!window.electronAPI) {
            setInternalUrl(urlToPlay);
            return;
        }

        setIsSwitching(true);
        setSwitchingMessage('Preparing stream...');
        try {
            const info = await window.electronAPI.probeStream(urlToPlay);
            if (info?.needsTranscode) {
                setSwitchingMessage('Decoding audio...');
                const { playlistUrl } = await window.electronAPI.startTranscode(urlToPlay, startTimeSeconds || 0);
                transcodeBaseRef.current = startTimeSeconds || 0;
                setProbedDuration(info.duration || null);
                pendingResumeRef.current = null; // the transcode session already starts at the right offset
                setHlsPlaylistUrl(playlistUrl);
            }
        } catch (e) {
            console.error('Probe/transcode failed, falling back to direct playback (audio may be silent)', e);
        } finally {
            setInternalUrl(urlToPlay);
            setIsSwitching(false);
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    // 1. Resume Progress + initial probe (only on the very first stream of this session)
    useEffect(() => {
        if (!tmdbId || !window.electronAPI) {
            startPlaybackFor(url, 0);
            return;
        }

        let active = true;
        (async () => {
            let startTime = 0;
            try {
                const progress = await window.electronAPI.getWatchProgress(tmdbId!, currentSeason, currentEpisode);
                if (progress && progress.progress > 10 && (progress.progress / progress.duration) < 0.95) {
                    console.log("Resuming from:", progress.progress);
                    startTime = progress.progress;
                }
            } catch (e) {
                console.error("Failed to load progress:", e);
            }
            if (active) startPlaybackFor(url, startTime);
        })();

        return () => { active = false; };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    // 2. Save Progress (Throttled) + drive the custom seek bar / time display
    // (transcodeBaseRef + the video's own currentTime, since each HLS session's internal clock restarts near 0)
    const absoluteTime = () => transcodeBaseRef.current + (videoRef.current?.currentTime || 0);

    const handleTimeUpdate = () => {
        if (!videoRef.current) return;
        if (!isSeeking) setCurrentTime(absoluteTime());

        if (!tmdbId || !window.electronAPI) return;
        const now = Date.now();
        if (now - lastUpdateRef.current > 5000) {
            window.electronAPI.updateWatchProgress(
                tmdbId,
                absoluteTime(),
                probedDuration || videoRef.current.duration,
                currentSeason,
                currentEpisode,
                currentMagnet
            );
            lastUpdateRef.current = now;
        }
    };

    // Save on Unmount / Close
    useEffect(() => {
        return () => {
            if (videoRef.current && tmdbId && window.electronAPI) {
                window.electronAPI.updateWatchProgress(
                    tmdbId,
                    absoluteTime(),
                    probedDuration || videoRef.current.duration,
                    currentSeason,
                    currentEpisode,
                    currentMagnet
                );
            }
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []);

    useEffect(() => {
        if (videoRef.current) {
            videoRef.current.play().catch(e => console.error("Auto-play failed", e));
        }
    }, [internalUrl, hlsPlaylistUrl]);

    // --- Attach/detach hls.js whenever a (new) transcode session's playlist URL is ready ---
    useEffect(() => {
        const video = videoRef.current;
        if (!video || !hlsPlaylistUrl) return;

        if (Hls.isSupported()) {
            const hls = new Hls({ maxBufferLength: 30 });
            hlsRef.current = hls;
            let mediaErrorRecoveries = 0;
            hls.loadSource(hlsPlaylistUrl);
            hls.attachMedia(video);
            // Without explicit recovery, a fatal error on one SourceBuffer (e.g. audio) just halts
            // that track silently while the other (e.g. video) keeps playing — official hls.js pattern.
            hls.on(Hls.Events.ERROR, (_evt, data) => {
                if (!data.fatal) return;
                console.error('Fatal HLS error:', data.type, data.details);
                if (data.type === Hls.ErrorTypes.NETWORK_ERROR) {
                    hls.startLoad();
                } else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) {
                    mediaErrorRecoveries++;
                    if (mediaErrorRecoveries <= 1) {
                        hls.recoverMediaError();
                    } else if (mediaErrorRecoveries <= 3) {
                        hls.swapAudioCodec();
                        hls.recoverMediaError();
                    } else {
                        console.error('Giving up after repeated fatal media errors');
                        hls.destroy();
                    }
                } else {
                    hls.destroy();
                }
            });
            return () => {
                hls.destroy();
                if (hlsRef.current === hls) hlsRef.current = null;
            };
        } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
            video.src = hlsPlaylistUrl;
        }
    }, [hlsPlaylistUrl]);

    // --- Torrent Stats (peers / download speed), polled from the main process ---
    useEffect(() => {
        if (!window.electronAPI) return;
        let active = true;

        const poll = async () => {
            try {
                const stats = await window.electronAPI.getTorrentStats();
                if (active) setTorrentStats(stats);
            } catch (e) {
                console.error("Failed to fetch torrent stats:", e);
            }
        };

        poll();
        const interval = setInterval(poll, 1500);
        return () => { active = false; clearInterval(interval); };
    }, []);

    // --- Subtitles ---
    const selectSubtitle = async (track: SubtitleTrackData | null) => {
        setSelectedSubtitle(track);
        setShowSubtitleMenu(false);

        if (!track || !track.url) {
            setSubtitleVttUrl(null);
            return;
        }

        const vttUrl = await fetchSubtitleAsVttUrl(track.url);
        setSubtitleVttUrl(vttUrl);
    };

    useEffect(() => {
        if (!imdbId) return;
        let active = true;
        setIsLoadingSubtitles(true);

        async function load() {
            const subs = await fetchSubtitles(imdbId!, currentSeason, currentEpisode);
            if (!active) return;
            setAvailableSubtitles(subs);
            setIsLoadingSubtitles(false);

            const engSub = subs.find(s => s.lang.toLowerCase() === 'eng' || s.lang.toLowerCase() === 'en');
            if (engSub) selectSubtitle(engSub);
        }
        load();

        return () => { active = false; };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [imdbId, currentSeason, currentEpisode]);

    // Manually manage the <track> element (browsers reset TextTrack mode on src changes, so
    // React-rendered <track> alone won't reliably stay enabled — same workaround Flutter avoids
    // by using a native player API for subtitle tracks).
    useEffect(() => {
        const video = videoRef.current;
        if (!video) return;

        Array.from(video.querySelectorAll('track')).forEach(t => t.remove());

        if (subtitleVttUrl) {
            const trackEl = document.createElement('track');
            trackEl.kind = 'subtitles';
            trackEl.label = selectedSubtitle ? getLanguageName(selectedSubtitle.lang) : 'Subtitle';
            trackEl.srclang = selectedSubtitle?.lang?.slice(0, 2) || 'en';
            trackEl.src = subtitleVttUrl;
            video.appendChild(trackEl);

            const enable = () => {
                if (video.textTracks.length > 0) {
                    video.textTracks[video.textTracks.length - 1].mode = 'showing';
                }
            };
            trackEl.addEventListener('load', enable);
            enable();
        }

        if (lastSubtitleBlobUrlRef.current && lastSubtitleBlobUrlRef.current !== subtitleVttUrl) {
            URL.revokeObjectURL(lastSubtitleBlobUrlRef.current);
        }
        lastSubtitleBlobUrlRef.current = subtitleVttUrl;
    }, [subtitleVttUrl, selectedSubtitle]);

    useEffect(() => {
        return () => {
            if (lastSubtitleBlobUrlRef.current) URL.revokeObjectURL(lastSubtitleBlobUrlRef.current);
        };
    }, []);

    // --- Episode metadata for the season currently playing (Now Playing panel + Next Episode) ---
    useEffect(() => {
        if (!isTv || !tmdbId || currentSeason == null || !window.electronAPI) return;
        let active = true;
        window.electronAPI.getSeasonDetails(tmdbId, currentSeason).then((eps: any) => {
            if (active) setPlayingSeasonEpisodes(eps || []);
        }).catch((e: any) => console.error("Failed to fetch episode metadata", e));
        return () => { active = false; };
    }, [isTv, tmdbId, currentSeason]);

    const currentEpisodeMeta = playingSeasonEpisodes.find((e: any) => e.episode_number === currentEpisode);

    const nextEpisode = (() => {
        if (!isTv || currentEpisode == null || playingSeasonEpisodes.length === 0) return null;
        const idx = playingSeasonEpisodes.findIndex((e: any) => e.episode_number === currentEpisode);
        if (idx === -1 || idx >= playingSeasonEpisodes.length - 1) return null;
        const next = playingSeasonEpisodes[idx + 1];
        return isEpisodeFuture(next.air_date) ? null : next;
    })();

    // --- Mid-playback quality switching (preserves timestamp) ---
    const switchQuality = async (stream: StreamOption) => {
        if (!window.electronAPI || stream.magnet === currentMagnet) { setShowQualityMenu(false); return; }

        const savedPos = videoRef.current?.currentTime || 0;
        setShowQualityMenu(false);
        setIsSwitching(true);
        setSwitchingMessage(`Switching quality to ${stream.quality || 'HD'}...`);

        try {
            await window.electronAPI.stopStream();
            const { url: newUrl } = await window.electronAPI.startStream(stream.magnet);
            setCurrentMagnet(stream.magnet);
            setCurrentQuality(stream.quality);
            await startPlaybackFor(newUrl, savedPos);
        } catch (e) {
            console.error("Failed to switch quality", e);
            alert("Failed to switch quality.");
        } finally {
            setIsSwitching(false);
        }
    };

    // --- Episode switching (drawer tap / Next Episode), resets playback to 0 ---
    // Auto-picks the best stream — used by "Next Episode" where asking the user would slow down binge-watching.
    const autoPlayEpisode = async (seasonNumber: number, episodeNumber: number) => {
        if (!tmdbId || !title || !window.electronAPI) return;
        setShowEpisodeDrawer(false);
        setIsSwitching(true);
        setSwitchingMessage(`Loading Episode: S${seasonNumber} E${episodeNumber}...`);

        try {
            const list = await window.electronAPI.getEpisodeTorrents(imdbId, title, seasonNumber, episodeNumber);
            if (list && list.length > 0) {
                const best = list[0];
                await window.electronAPI.stopStream();
                const { url: newUrl } = await window.electronAPI.startStream(best.magnet);
                setCurrentMagnet(best.magnet);
                setCurrentQuality(best.quality);
                setCurrentStreams(list);
                setCurrentSeason(seasonNumber);
                setCurrentEpisode(episodeNumber);
                await startPlaybackFor(newUrl, 0);
            } else if (onWebStream) {
                onClose();
                onWebStream(tmdbId, seasonNumber, episodeNumber, 'vidking');
            } else {
                alert("No streams found for this episode.");
            }
        } catch (e) {
            console.error("Failed to play episode", e);
            alert("Failed to play episode.");
        } finally {
            setIsSwitching(false);
        }
    };

    const playNextEpisode = () => {
        if (!nextEpisode || currentSeason == null) return;
        autoPlayEpisode(currentSeason, nextEpisode.episode_number);
    };

    // Tapping an episode in the drawer opens a source picker instead of auto-playing.
    const openEpisodeSourcePicker = async (seasonNumber: number, episodeNumber: number) => {
        if (!tmdbId || !title || !window.electronAPI) return;
        const epMeta = drawerEpisodes.find((e: any) => e.episode_number === episodeNumber);
        setEpisodeSourcePicker({ season: seasonNumber, episode: episodeNumber, episodeName: epMeta?.name, streams: [], loading: true });

        try {
            const list = await window.electronAPI.getEpisodeTorrents(imdbId, title, seasonNumber, episodeNumber);
            setEpisodeSourcePicker(prev =>
                prev && prev.season === seasonNumber && prev.episode === episodeNumber
                    ? { ...prev, streams: list || [], loading: false }
                    : prev
            );
        } catch (e) {
            console.error("Failed to fetch episode sources", e);
            setEpisodeSourcePicker(prev => prev ? { ...prev, streams: [], loading: false } : prev);
        }
    };

    const confirmPlayEpisode = async (seasonNumber: number, episodeNumber: number, stream: StreamOption, allStreams: StreamOption[]) => {
        if (!window.electronAPI) return;
        setEpisodeSourcePicker(null);
        setShowEpisodeDrawer(false);
        setIsSwitching(true);
        setSwitchingMessage(`Loading Episode: S${seasonNumber} E${episodeNumber}...`);

        try {
            await window.electronAPI.stopStream();
            const { url: newUrl } = await window.electronAPI.startStream(stream.magnet);
            setCurrentMagnet(stream.magnet);
            setCurrentQuality(stream.quality);
            setCurrentStreams(allStreams);
            setCurrentSeason(seasonNumber);
            setCurrentEpisode(episodeNumber);
            await startPlaybackFor(newUrl, 0);
        } catch (e) {
            console.error("Failed to switch to episode stream", e);
            alert("Failed to play episode.");
        } finally {
            setIsSwitching(false);
        }
    };

    const playEpisodeViaWeb = (seasonNumber: number, episodeNumber: number, provider: WebProvider) => {
        if (!tmdbId || !onWebStream) return;
        setEpisodeSourcePicker(null);
        onClose();
        onWebStream(tmdbId, seasonNumber, episodeNumber, provider);
    };

    // --- Episode Drawer browsing ---
    const openEpisodeDrawer = () => {
        setBrowsingSeason(currentSeason || 1);
        setShowEpisodeDrawer(true);
    };

    useEffect(() => {
        if (!showEpisodeDrawer || !tmdbId || !window.electronAPI) return;
        let active = true;
        setLoadingDrawerEpisodes(true);
        setDrawerProgress({});

        window.electronAPI.getSeasonDetails(tmdbId, browsingSeason).then(async (eps: any) => {
            if (!active) return;
            setDrawerEpisodes(eps || []);
            setLoadingDrawerEpisodes(false);

            // Fetch saved watch-history progress for every episode in this season
            const list = eps || [];
            const results = await Promise.all(list.map((ep: any) =>
                window.electronAPI.getWatchProgress(tmdbId, browsingSeason, ep.episode_number).catch(() => null)
            ));
            if (!active) return;
            const map: Record<number, number> = {};
            list.forEach((ep: any, i: number) => {
                const p = results[i];
                if (p && p.duration > 0) map[ep.episode_number] = (p.progress / p.duration) * 100;
            });
            setDrawerProgress(map);
        }).catch((e: any) => { console.error("Failed to load drawer episodes", e); if (active) setLoadingDrawerEpisodes(false); });

        return () => { active = false; };
    }, [showEpisodeDrawer, tmdbId, browsingSeason]);

    const getDrawerEpisodeProgress = (s: number, epNum: number): number => {
        // The currently-playing episode has a live position that's more up to date than the last saved snapshot.
        if (s === currentSeason && epNum === currentEpisode && effectiveDuration > 0) {
            return (currentTime / effectiveDuration) * 100;
        }
        if (s === browsingSeason) {
            return drawerProgress[epNum] || 0;
        }
        return 0;
    };

    // --- Controls auto-hide (mirrors Flutter: always visible while paused, auto-hides after 4s while playing) ---
    const resetHideTimer = useCallback(() => {
        if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
        if (isPlaying) {
            hideTimerRef.current = setTimeout(() => setControlsVisible(false), CONTROLS_HIDE_DELAY);
        }
    }, [isPlaying]);

    useEffect(() => {
        if (isPlaying) {
            resetHideTimer();
        } else {
            setControlsVisible(true);
            if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
        }
        return () => { if (hideTimerRef.current) clearTimeout(hideTimerRef.current); };
    }, [isPlaying, resetHideTimer]);

    const showControlsAndResetTimer = () => {
        setControlsVisible(true);
        resetHideTimer();
    };

    const togglePlayPause = () => {
        if (!videoRef.current) return;
        if (videoRef.current.paused) {
            videoRef.current.play();
        } else {
            videoRef.current.pause();
        }
    };

    // Seeks to an absolute timeline position. In direct-playback mode this is just <video>.currentTime.
    // In HLS/transcode mode, a seek within what's already been generated (video.buffered) can be handled
    // natively by hls.js; a seek beyond that requires restarting ffmpeg at the new position.
    const seekTo = async (absoluteTarget: number) => {
        const max = effectiveDuration || Infinity;
        const target = Math.min(Math.max(absoluteTarget, 0), max);

        if (!hlsPlaylistUrl) {
            if (videoRef.current) videoRef.current.currentTime = target;
            setCurrentTime(target);
            return;
        }

        const sessionRelative = target - transcodeBaseRef.current;
        if (sessionRelative >= 0 && sessionRelative <= bufferedEnd && window.electronAPI) {
            if (videoRef.current) videoRef.current.currentTime = sessionRelative;
            setCurrentTime(target);
            return;
        }

        if (!window.electronAPI) return;
        setIsSwitching(true);
        setSwitchingMessage('Seeking...');
        try {
            const { playlistUrl } = await window.electronAPI.startTranscode(internalUrl, target);
            transcodeBaseRef.current = target;
            setBufferedEnd(0);
            setCurrentTime(target);
            setHlsPlaylistUrl(playlistUrl);
        } catch (e) {
            console.error('Failed to seek (transcode restart)', e);
        } finally {
            setIsSwitching(false);
        }
    };

    const skip = (deltaSeconds: number) => {
        const base = hlsPlaylistUrl ? transcodeBaseRef.current + (videoRef.current?.currentTime || 0) : (videoRef.current?.currentTime || 0);
        seekTo(base + deltaSeconds);
        showControlsAndResetTimer();
    };

    // Single click on the video toggles controls visibility (does NOT play/pause — matches Flutter's gesture overlay)
    const handleVideoAreaClick = () => {
        if (!isPlaying) {
            setControlsVisible(true);
            return;
        }
        if (controlsVisible) {
            setControlsVisible(false);
            if (hideTimerRef.current) clearTimeout(hideTimerRef.current);
        } else {
            showControlsAndResetTimer();
        }
    };

    const handleDoubleClickSide = (dir: 'back' | 'forward') => {
        skip(dir === 'back' ? -SKIP_SECONDS : SKIP_SECONDS);
        setSkipFlash({ dir, id: Date.now() });
    };

    useEffect(() => {
        if (!skipFlash) return;
        const t = setTimeout(() => setSkipFlash(null), 550);
        return () => clearTimeout(t);
    }, [skipFlash]);

    // --- Custom seek bar (click + drag), with buffered range like Flutter's secondaryTrackValue ---
    const computeTimeFromClientX = (clientX: number): number => {
        if (!progressBarRef.current || !effectiveDuration) return 0;
        const rect = progressBarRef.current.getBoundingClientRect();
        const ratio = Math.min(Math.max((clientX - rect.left) / rect.width, 0), 1);
        return ratio * effectiveDuration;
    };

    const handleSeekMouseDown = (e: React.MouseEvent) => {
        setIsSeeking(true);
        const t = computeTimeFromClientX(e.clientX);
        setSeekPreview(t);
        showControlsAndResetTimer();
    };

    useEffect(() => {
        if (!isSeeking) return;

        const handleMouseMove = (e: MouseEvent) => {
            setSeekPreview(computeTimeFromClientX(e.clientX));
        };
        const handleMouseUp = (e: MouseEvent) => {
            const t = computeTimeFromClientX(e.clientX);
            seekTo(t);
            setIsSeeking(false);
        };

        window.addEventListener('mousemove', handleMouseMove);
        window.addEventListener('mouseup', handleMouseUp);
        return () => {
            window.removeEventListener('mousemove', handleMouseMove);
            window.removeEventListener('mouseup', handleMouseUp);
        };
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [isSeeking, effectiveDuration]);

    const handleProgress = () => {
        const v = videoRef.current;
        if (!v || !v.buffered.length) return;
        for (let i = 0; i < v.buffered.length; i++) {
            if (v.buffered.start(i) <= v.currentTime && v.currentTime <= v.buffered.end(i)) {
                setBufferedEnd(v.buffered.end(i));
                return;
            }
        }
        setBufferedEnd(v.buffered.end(v.buffered.length - 1));
    };

    const handleLoadedMetadata = () => {
        // An in-progress HLS transcode session reports Infinity (or the partial-so-far length) until
        // ffmpeg finishes — the probed file duration (effectiveDuration) is the real total in that case.
        const nativeDuration = videoRef.current?.duration;
        if (nativeDuration && isFinite(nativeDuration)) setDuration(nativeDuration);
        if (pendingResumeRef.current != null && videoRef.current) {
            videoRef.current.currentTime = pendingResumeRef.current;
            pendingResumeRef.current = null;
        }
    };

    const displayedTime = isSeeking ? seekPreview : currentTime;
    const playedPct = effectiveDuration > 0 ? (displayedTime / effectiveDuration) * 100 : 0;
    const bufferedPct = effectiveDuration > 0 ? (bufferedAbsolute / effectiveDuration) * 100 : 0;

    return (
        <div
            style={{
                position: 'fixed', top: 0, left: 0, width: '100vw', height: '100vh',
                backgroundColor: 'black', zIndex: 1000, overflow: 'hidden'
            }}
            onMouseMove={() => isPlaying && showControlsAndResetTimer()}
        >
            <video
                ref={videoRef}
                {...(!hlsPlaylistUrl ? { src: internalUrl } : {})}
                autoPlay
                onTimeUpdate={handleTimeUpdate}
                onProgress={handleProgress}
                onDurationChange={handleLoadedMetadata}
                onLoadedMetadata={handleLoadedMetadata}
                onPlay={() => setIsPlaying(true)}
                onPause={() => setIsPlaying(false)}
                style={{
                    width: '100%', height: '100%', objectFit: 'contain',
                    transform: isPlaying ? 'scale(1)' : 'scale(1.04)',
                    transition: 'transform 350ms cubic-bezier(0.2, 0.8, 0.2, 1)'
                }}
            />

            {/* Click-to-toggle-controls layer + double-click skip zones */}
            <div style={{ position: 'absolute', inset: 0, display: 'flex' }}>
                <div style={{ flex: 1 }} onClick={handleVideoAreaClick} onDoubleClick={() => handleDoubleClickSide('back')} />
                <div style={{ flex: 1 }} onClick={handleVideoAreaClick} onDoubleClick={() => handleDoubleClickSide('forward')} />
            </div>

            {/* Skip ±10s flash indicator */}
            {skipFlash && (
                <div
                    key={skipFlash.id}
                    style={{
                        position: 'absolute', top: '50%', [skipFlash.dir === 'back' ? 'left' : 'right']: '15%',
                        transform: 'translateY(-50%)',
                        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '4px',
                        color: 'white', pointerEvents: 'none',
                        animation: 'skipFlashFade 550ms ease-out'
                    }}
                >
                    <svg width="36" height="36" viewBox="0 0 24 24" fill="white">
                        {skipFlash.dir === 'back'
                            ? <path d="M11 6V2L5 8l6 6V10c3.31 0 6 2.69 6 6s-2.69 6-6 6-6-2.69-6-6H3c0 4.42 3.58 8 8 8s8-3.58 8-8-3.58-8-8-8z" />
                            : <path d="M13 6V2l6 6-6 6V10c-3.31 0-6 2.69-6 6s2.69 6 6 6 6-2.69 6-6h2c0 4.42-3.58 8-8 8s-8-3.58-8-8 3.58-8 8-8z" />}
                    </svg>
                    <span style={{ fontSize: '13px', fontWeight: 700 }}>{SKIP_SECONDS}s</span>
                </div>
            )}

            {/* Initial buffering / loading spinner */}
            {(effectiveDuration === 0 || isSwitching) && (
                <div style={{ position: 'absolute', inset: 0, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', pointerEvents: 'none', background: isSwitching ? 'rgba(0,0,0,0.6)' : 'transparent' }}>
                    <div style={{
                        width: '64px', height: '64px',
                        border: '3px solid rgba(255,255,255,0.15)', borderTopColor: 'var(--primary-color)',
                        borderRadius: '50%', animation: 'spin 0.9s linear infinite'
                    }} />
                    {isSwitching && switchingMessage && (
                        <p style={{ color: 'white', fontWeight: 700, marginTop: '16px', fontSize: '15px' }}>{switchingMessage}</p>
                    )}
                </div>
            )}

            {/* Controls Overlay */}
            <div
                style={{
                    position: 'absolute', inset: 0,
                    opacity: controlsVisible ? 1 : 0,
                    pointerEvents: controlsVisible ? 'auto' : 'none',
                    transition: 'opacity 280ms ease',
                    background: 'linear-gradient(to bottom, rgba(0,0,0,0.7) 0%, transparent 18%, transparent 60%, rgba(0,0,0,0.85) 100%)'
                }}
            >
                {/* Left-side cinematic gradient + Now Playing panel, visible only while paused */}
                <div style={{
                    position: 'absolute', inset: 0, pointerEvents: 'none',
                    opacity: !isPlaying ? 1 : 0, transition: 'opacity 350ms ease'
                }}>
                    <div style={{
                        position: 'absolute', inset: 0,
                        background: 'linear-gradient(to right, rgba(0,0,0,0.85) 0%, rgba(0,0,0,0.4) 35%, transparent 65%)'
                    }} />
                    <div style={{ position: 'absolute', left: '48px', bottom: '160px', maxWidth: '44%' }}>
                        <span style={{
                            padding: '5px 12px', borderRadius: '5px', background: 'rgba(181,150,110,0.15)',
                            color: 'var(--primary-color)', fontSize: '13px', fontWeight: 800, letterSpacing: '2.5px'
                        }}>
                            NOW PLAYING
                        </span>

                        <div style={{ marginTop: '18px' }}>
                            {logoUrl ? (
                                <img src={logoUrl} alt={title} style={{ height: '96px', maxWidth: '100%', objectFit: 'contain', objectPosition: 'left' }} />
                            ) : (
                                <div style={{
                                    color: 'white', fontSize: '42px', fontWeight: 800, lineHeight: 1.15,
                                    display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden'
                                }}>{title}</div>
                            )}
                        </div>

                        {isTv && currentEpisode != null && (
                            <div style={{ marginTop: '14px', display: 'flex', alignItems: 'center', gap: '10px' }}>
                                <span style={{ padding: '4px 10px', borderRadius: '5px', background: 'rgba(255,255,255,0.1)', color: 'white', fontSize: '15px', fontWeight: 700 }}>
                                    S{currentSeason} E{currentEpisode}
                                </span>
                                <span style={{ color: 'rgba(255,255,255,0.7)', fontSize: '17px', fontWeight: 500, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                    {currentEpisodeMeta?.name || ''}
                                </span>
                            </div>
                        )}

                        <p style={{
                            marginTop: '16px', color: 'rgba(255,255,255,0.6)', fontSize: '16px', lineHeight: 1.6,
                            display: '-webkit-box', WebkitLineClamp: 3, WebkitBoxOrient: 'vertical', overflow: 'hidden'
                        }}>
                            {(isTv && currentEpisodeMeta?.overview) || description || ''}
                        </p>
                    </div>
                </div>

                {/* Top Bar */}
                <div style={{
                    padding: '1rem',
                    position: 'absolute', top: 0, left: 0, width: '100%', boxSizing: 'border-box',
                    display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start'
                }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: '14px', minWidth: 0 }}>
                        <button
                            onClick={onClose}
                            style={{
                                background: 'transparent', color: 'white', border: '1px solid white',
                                padding: '0.6rem 1.2rem', borderRadius: '8px', cursor: 'pointer', fontSize: '15px',
                                display: 'flex', alignItems: 'center', gap: '8px', backdropFilter: 'blur(4px)', flexShrink: 0
                            }}
                        >
                            ← Back
                        </button>
                        {isPlaying && (
                            logoUrl ? (
                                <img src={logoUrl} alt={title} style={{ height: '36px', maxWidth: '220px', objectFit: 'contain', objectPosition: 'left' }} />
                            ) : title ? (
                                <span style={{ color: 'white', fontSize: '1.2rem', fontWeight: 600, whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
                                    {title}
                                </span>
                            ) : null
                        )}
                    </div>

                    <div style={{ display: 'flex', alignItems: 'center', gap: '12px', flexShrink: 0 }}>
                        {torrentStats && (
                            <div style={{
                                display: 'flex', alignItems: 'center', gap: '8px',
                                padding: '8px 14px', borderRadius: '24px',
                                background: 'rgba(255,255,255,0.08)'
                            }}>
                                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#4ade80" strokeWidth="2.5"><line x1="12" y1="5" x2="12" y2="19"></line><polyline points="19 12 12 19 5 12"></polyline></svg>
                                <span style={{ color: '#4ade80', fontWeight: 600, fontSize: '14px' }}>
                                    {(torrentStats.downloadSpeed / 1024 / 1024).toFixed(1)} MB/s
                                </span>
                                <div style={{ width: '1px', height: '14px', background: 'rgba(255,255,255,0.15)' }} />
                                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.5)" strokeWidth="2"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"></path><circle cx="9" cy="7" r="4"></circle><path d="M23 21v-2a4 4 0 0 0-3-3.87"></path><path d="M16 3.13a4 4 0 0 1 0 7.75"></path></svg>
                                <span style={{ color: 'rgba(255,255,255,0.65)', fontWeight: 600, fontSize: '14px' }}>{torrentStats.numPeers}</span>
                            </div>
                        )}
                    </div>
                </div>

                {/* Center Play/Pause (matches Flutter — no visible skip buttons, only double-click zones) */}
                <div style={{ position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%, -50%)' }}>
                    <button
                        onClick={togglePlayPause}
                        style={{
                            background: 'transparent', border: 'none', cursor: 'pointer',
                            borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center',
                            boxShadow: '0 0 30px 4px rgba(255,255,255,0.08)'
                        }}
                    >
                        {isPlaying ? (
                            <svg width="72" height="72" viewBox="0 0 24 24" fill="white"><path d="M6 5h4v14H6zm8 0h4v14h-4z" /></svg>
                        ) : (
                            <svg width="72" height="72" viewBox="0 0 24 24" fill="white"><path d="M8 5v14l11-7z" /></svg>
                        )}
                    </button>
                </div>

                {/* Bottom Bar: Seek bar + timestamps + action pills */}
                <div style={{ position: 'absolute', bottom: '24px', left: '24px', right: '24px' }}>
                    <div
                        ref={progressBarRef}
                        onMouseDown={handleSeekMouseDown}
                        style={{ position: 'relative', height: '20px', display: 'flex', alignItems: 'center', cursor: 'pointer' }}
                    >
                        <div style={{ position: 'relative', width: '100%', height: '3px', background: 'rgba(255,255,255,0.12)', borderRadius: '2px' }}>
                            <div style={{ position: 'absolute', left: 0, top: 0, height: '100%', width: `${bufferedPct}%`, background: 'rgba(255,255,255,0.3)', borderRadius: '2px' }} />
                            <div style={{ position: 'absolute', left: 0, top: 0, height: '100%', width: `${playedPct}%`, background: 'var(--primary-color)', borderRadius: '2px' }} />
                            <div style={{
                                position: 'absolute', top: '50%', left: `${playedPct}%`, transform: 'translate(-50%, -50%)',
                                width: '14px', height: '14px', borderRadius: '50%', background: 'var(--primary-color)'
                            }} />
                        </div>
                    </div>

                    <div style={{ display: 'flex', alignItems: 'center', padding: '0 4px', marginTop: '8px', gap: '14px' }}>
                        <span style={{ color: 'white', fontSize: '15px', fontWeight: 600 }}>{formatDuration(displayedTime)}</span>
                        <span style={{ color: 'rgba(255,255,255,0.35)', fontSize: '15px', marginLeft: '-10px' }}>/ {formatDuration(effectiveDuration)}</span>

                        <div style={{ flex: 1 }} />

                        {/* Quality Selector */}
                        {currentStreams.length > 0 && (
                            <div style={{ position: 'relative' }}>
                                <PillButton onClick={() => setShowQualityMenu(!showQualityMenu)}>
                                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2"><rect x="2" y="6" width="20" height="12" rx="2"></rect><path d="M6 10v4M9 10v4M9 12h2M14 10h2.5a1.5 1.5 0 010 3H14v-3zm0 3h2.5"></path></svg>
                                    <span style={{ color: 'white', fontSize: '14px', fontWeight: 600 }}>{currentQuality || '1080p'}</span>
                                </PillButton>
                                {showQualityMenu && (
                                    <div style={{
                                        position: 'absolute', bottom: '100%', right: 0, marginBottom: '8px',
                                        background: '#000', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '10px',
                                        minWidth: '260px', maxHeight: '320px', overflowY: 'auto', padding: '10px',
                                        zIndex: 1002, boxShadow: '0 4px 12px rgba(0,0,0,0.5)'
                                    }}>
                                        {currentStreams.map((s, i) => (
                                            <SelectionTile
                                                key={i}
                                                title={s.quality || 'Unknown Quality'}
                                                subtitle={[s.size, typeof s.seeds === 'number' ? `🚀 ${s.seeds}` : null].filter(Boolean).join(' • ') || s.title}
                                                isSelected={s.magnet === currentMagnet}
                                                onClick={() => switchQuality(s)}
                                            />
                                        ))}
                                    </div>
                                )}
                            </div>
                        )}

                        {/* Subtitle Selector */}
                        {imdbId && (
                            <div style={{ position: 'relative' }}>
                                <PillButton onClick={() => !isLoadingSubtitles && setShowSubtitleMenu(!showSubtitleMenu)} disabled={isLoadingSubtitles} iconColor={selectedSubtitle ? 'var(--primary-color)' : 'white'}>
                                    <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                                        <rect x="2" y="5" width="20" height="14" rx="2"></rect><line x1="6" y1="14" x2="10" y2="14"></line><line x1="12" y1="14" x2="18" y2="14"></line><line x1="6" y1="10" x2="14" y2="10"></line>
                                    </svg>
                                    <span style={{ color: 'white', fontSize: '14px', fontWeight: 600 }}>
                                        {selectedSubtitle ? getLanguageName(selectedSubtitle.lang) : (isLoadingSubtitles ? 'Loading...' : 'Subtitles')}
                                    </span>
                                </PillButton>

                                {showSubtitleMenu && (
                                    <div style={{
                                        position: 'absolute', bottom: '100%', right: 0, marginBottom: '8px',
                                        background: '#000', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '10px',
                                        minWidth: '230px', maxHeight: '320px', overflowY: 'auto', padding: '10px',
                                        zIndex: 1002, boxShadow: '0 4px 12px rgba(0,0,0,0.5)'
                                    }}>
                                        <SelectionTile title="Subtitles Off" isSelected={!selectedSubtitle} onClick={() => selectSubtitle(null)} />
                                        {availableSubtitles.length === 0 ? (
                                            <div style={{ padding: '12px', fontSize: '13px', color: '#777' }}>No subtitles found</div>
                                        ) : (
                                            availableSubtitles.map(track => (
                                                <SelectionTile
                                                    key={track.id}
                                                    title={getLanguageName(track.lang)}
                                                    isSelected={selectedSubtitle?.id === track.id}
                                                    onClick={() => selectSubtitle(track)}
                                                />
                                            ))
                                        )}
                                    </div>
                                )}
                            </div>
                        )}

                        {/* Episodes (TV only) */}
                        {isTv && (
                            <PillButton onClick={openEpisodeDrawer}>
                                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2"><rect x="3" y="3" width="7" height="7"></rect><rect x="14" y="3" width="7" height="7"></rect><rect x="14" y="14" width="7" height="7"></rect><rect x="3" y="14" width="7" height="7"></rect></svg>
                                <span style={{ color: 'white', fontSize: '14px', fontWeight: 600 }}>Episodes</span>
                            </PillButton>
                        )}

                        {/* Next Episode (TV only) */}
                        {isTv && (
                            <PillButton onClick={playNextEpisode} disabled={!nextEpisode} muted={!nextEpisode}>
                                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polygon points="5 4 15 12 5 20 5 4"></polygon><line x1="19" y1="5" x2="19" y2="19"></line></svg>
                                <span style={{ fontSize: '14px', fontWeight: 600, color: 'inherit' }}>Next Episode</span>
                            </PillButton>
                        )}
                    </div>
                </div>
            </div>

            {showEpisodeDrawer && isTv && tmdbId && (
                <EpisodeDrawer
                    episodes={drawerEpisodes}
                    seasons={seasons}
                    title={title || ''}
                    logoUrl={logoUrl}
                    browsingSeason={browsingSeason}
                    playingSeason={currentSeason || 1}
                    playingEpisode={currentEpisode || 1}
                    loading={loadingDrawerEpisodes}
                    getEpisodeProgress={getDrawerEpisodeProgress}
                    onSeasonChange={setBrowsingSeason}
                    onEpisodeTap={(epNum) => openEpisodeSourcePicker(browsingSeason, epNum)}
                    onClose={() => setShowEpisodeDrawer(false)}
                />
            )}

            {episodeSourcePicker && (
                <div
                    style={{ position: 'fixed', inset: 0, zIndex: 1150, background: 'rgba(0,0,0,0.92)', display: 'flex', flexDirection: 'column' }}
                    onClick={() => setEpisodeSourcePicker(null)}
                >
                    <div onClick={e => e.stopPropagation()} style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0 }}>
                        {/* Header */}
                        <div style={{ display: 'flex', alignItems: 'center', gap: '16px', padding: '28px 40px', flexShrink: 0 }}>
                            <button onClick={() => setEpisodeSourcePicker(null)} style={{ background: 'rgba(255,255,255,0.08)', border: 'none', borderRadius: '50%', width: '44px', height: '44px', cursor: 'pointer', color: 'white', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
                                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="19" y1="12" x2="5" y2="12"></line><polyline points="12 19 5 12 12 5"></polyline></svg>
                            </button>
                            <div>
                                <div style={{ color: 'white', fontSize: '24px', fontWeight: 700 }}>
                                    S{episodeSourcePicker.season} E{episodeSourcePicker.episode}{episodeSourcePicker.episodeName ? ` · ${episodeSourcePicker.episodeName}` : ''}
                                </div>
                                <div style={{ color: 'rgba(255,255,255,0.5)', fontSize: '15px', marginTop: '2px' }}>Select a source</div>
                            </div>
                        </div>

                        {/* Body */}
                        <div style={{ flex: 1, minHeight: 0, overflowY: 'auto', padding: '8px 40px 40px' }}>
                            {episodeSourcePicker.loading ? (
                                <p style={{ color: '#777', fontStyle: 'italic', fontSize: '16px' }}>Searching for sources...</p>
                            ) : (
                                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(260px, 1fr))', gap: '16px' }}>
                                    {onWebStream && WEB_SERVERS.map(({ provider, label, accentColor }) => (
                                        <SourceCard
                                            key={provider}
                                            title={label}
                                            accentColor={accentColor}
                                            onClick={() => playEpisodeViaWeb(episodeSourcePicker.season, episodeSourcePicker.episode, provider)}
                                        />
                                    ))}
                                    {episodeSourcePicker.streams.map((s, i) => (
                                        <SourceCard
                                            key={i}
                                            title={s.title || s.quality || 'Unknown Quality'}
                                            subtitle="Source: P2P"
                                            quality={s.quality}
                                            size={s.size}
                                            seeds={s.seeds}
                                            onClick={() => confirmPlayEpisode(episodeSourcePicker.season, episodeSourcePicker.episode, s, episodeSourcePicker.streams)}
                                        />
                                    ))}
                                    {episodeSourcePicker.streams.length === 0 && !onWebStream && (
                                        <p style={{ color: '#d64d4d', fontSize: '15px' }}>No streams found for this episode.</p>
                                    )}
                                </div>
                            )}
                        </div>
                    </div>
                </div>
            )}

            <style>{`
                @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
                @keyframes skipFlashFade {
                    0% { opacity: 0; transform: translateY(-50%) scale(0.8); }
                    20% { opacity: 1; transform: translateY(-50%) scale(1); }
                    100% { opacity: 0; transform: translateY(-50%) scale(1); }
                }
            `}</style>
        </div>
    );
};

export default VideoPlayer;
