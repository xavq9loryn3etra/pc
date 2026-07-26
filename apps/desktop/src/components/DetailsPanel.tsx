import React, { useState, useEffect, useRef } from 'react';
import type { Movie } from '../data/movies';
import placeholder from '../assets/placeholder.png';
import SourceCard from './SourceCard';
import type { WebProvider } from './WebPlayer';
import type { PlayStreamOptions } from '../types/stream';




// Same 4 web servers as the Flutter app's "Alternative Web Servers" menu, in the same order.
const WEB_SERVERS: { provider: WebProvider; label: string; accentColor: string }[] = [
    { provider: 'vidlink', label: 'Server 1', accentColor: '#8A2BE2' },
    { provider: 'moviesapi', label: 'Server 2', accentColor: '#2b8ae2' },
    { provider: 'vidking', label: 'Server 3', accentColor: '#e2a82b' },
    { provider: 'vsembed', label: 'Server 4', accentColor: '#4caf50' },
];

interface DetailsPanelProps {
    movie: Movie | null;
    isOpen: boolean;
    onClose: () => void;
    onStream: (options: PlayStreamOptions) => void;
    onWebStream?: (tmdbId: string, season?: number, episode?: number, provider?: WebProvider) => void;
    watchHistory?: any;
}

const DetailsPanel: React.FC<DetailsPanelProps> = ({ movie, isOpen, onClose, onStream, onWebStream, watchHistory }) => {
    const [details, setDetails] = useState<any>(null);
    const [torrents, setTorrents] = useState<any[]>([]);
    const [isLoading, setIsLoading] = useState(true);
    const panelRef = useRef<HTMLDivElement>(null);
    const parallaxRef = useRef<HTMLDivElement>(null);
    const prewarmRef = useRef<string | null>(null);

    // Helper to compare magnets by hash
    const extractHash = (magnet: string) => {
        try {
            const match = magnet.match(/xt=urn:btih:([a-zA-Z0-9]+)/);
            return match ? match[1].toLowerCase() : null;
        } catch (e) { return null; }
    };

    // Progress Helpers
    const getEpisodeProgress = (season: number, epNum: number, sourceId?: string): number => {
        if (!watchHistory || !watchHistory.shows || !movie) return 0;
        const show = watchHistory.shows[movie.id.toString()];
        if (!show) return 0;

        const key = `s${season}e${epNum}`;
        const ep = show[key];

        if (!ep || !ep.duration) return 0;

        if (sourceId) {
            const storedMagnet = ep.magnet;
            if (!storedMagnet) return 0;

            const isHash = storedMagnet.startsWith('magnet:?xt=urn:btih:');

            if (isHash) {
                // Stored is Torrent
                const h1 = extractHash(sourceId); // sourceId is magnet
                const h2 = extractHash(storedMagnet);
                if (h1 && h2 && h1 !== h2) return 0;
                if (!h1) return 0; // sourceId wasn't magnet but stored is
            } else {
                // Stored is Web Provider (string)
                if (storedMagnet !== sourceId) return 0;
            }
        }

        return (ep.progress / ep.duration) * 100;
    };

    const isEpisodeReleased = (dateString?: string) => {
        if (!dateString) return false;
        const releaseDate = new Date(dateString);
        const today = new Date();
        return today >= releaseDate;
    };

    const getMovieProgress = (sourceId?: string): number => {
        if (!watchHistory || !watchHistory.movies || !movie || movie.type === 'tv') return 0;
        const entry = watchHistory.movies[movie.id.toString()];
        if (!entry || !entry.duration) return 0;

        if (sourceId) {
            const storedMagnet = entry.magnet;
            if (!storedMagnet) return 0;

            const isHash = storedMagnet.startsWith('magnet:?xt=urn:btih:');

            if (isHash) {
                // Stored is Torrent
                const h1 = extractHash(sourceId);
                const h2 = extractHash(storedMagnet);
                if (h1 && h2 && h1 !== h2) return 0;
                if (!h1) return 0;
            } else {
                // Stored is Web Provider (string)
                if (storedMagnet !== sourceId) return 0;
            }
        }

        return (entry.progress / entry.duration) * 100;
    };

    // TV Series State
    const [selectedSeason, setSelectedSeason] = useState(1);
    const [episodes, setEpisodes] = useState<any[]>([]);
    const [expandedEpisode, setExpandedEpisode] = useState<number | null>(null);
    const [episodeTorrents, setEpisodeTorrents] = useState<any[]>([]);
    const [loadingEpisodes, setLoadingEpisodes] = useState(false);
    const [loadingEpisodeTorrents, setLoadingEpisodeTorrents] = useState(false);

    const [isSeasonDropdownOpen, setIsSeasonDropdownOpen] = useState(false);
    const seasonDropdownRef = useRef<HTMLDivElement>(null);

    // Close season dropdown when clicking outside
    useEffect(() => {
        const handleClickOutside = (event: MouseEvent) => {
            if (seasonDropdownRef.current && !seasonDropdownRef.current.contains(event.target as Node)) {
                setIsSeasonDropdownOpen(false);
            }
        };
        document.addEventListener('mousedown', handleClickOutside);
        return () => document.removeEventListener('mousedown', handleClickOutside);
    }, []);



    // Fetch Episodes when season changes
    useEffect(() => {
        if (!movie || !isOpen || movie.type !== 'tv') return;

        let active = true;
        setLoadingEpisodes(true);
        setExpandedEpisode(null);

        async function fetchEps() {
            if (!window.electronAPI || !movie) return;
            try {
                const eps = await (window.electronAPI as any).getSeasonDetails(movie.id, selectedSeason);
                if (active && eps) setEpisodes(eps);
            } catch (e) { console.error(e); }
            finally { if (active) setLoadingEpisodes(false); }
        }
        fetchEps();
        return () => { active = false; };
    }, [movie, isOpen, selectedSeason]);

    const handleEpisodeClick = async (ep: any) => {
        if (!movie) return;
        if (!isEpisodeReleased(ep.air_date)) return;

        if (expandedEpisode === ep.id) {
            setExpandedEpisode(null);
            return;
        }
        setExpandedEpisode(ep.id);
        setEpisodeTorrents([]);
        setLoadingEpisodeTorrents(true);

        try {
            const list = await (window.electronAPI as any).getEpisodeTorrents(details?.imdbId, movie.title, selectedSeason, ep.episode_number);
            setEpisodeTorrents(list);
            if (list && list.length > 0) {
                prewarmRef.current = list[0].magnet;
                window.electronAPI.prewarmTorrent(list[0].magnet).catch(() => {});
            }
        } catch (e) { console.error(e); }
        finally { setLoadingEpisodeTorrents(false); }
    };

    // Parallax + Sticky Header (mirrors Flutter's scroll-based AppBar fade-in)
    const [headerOpacity, setHeaderOpacity] = useState(0);
    const [showStickyTitle, setShowStickyTitle] = useState(false);
    useEffect(() => {
        const panel = panelRef.current;
        if (!panel) return;
        const handleScroll = () => {
            const scrolled = panel.scrollTop;
            if (parallaxRef.current && scrolled < 800) { // Limit
                parallaxRef.current.style.transform = `translateY(${scrolled * 0.4}px)`;
            }
            const opacity = Math.min(scrolled / 200, 1);
            setHeaderOpacity(opacity);
            setShowStickyTitle(opacity > 0.3);
        };
        panel.addEventListener('scroll', handleScroll, { passive: true });
        return () => panel.removeEventListener('scroll', handleScroll);
    }, [isOpen]); // Re-attach when opened likely

    // Trailer + Share State
    const [trailerKey, setTrailerKey] = useState<string | null>(null);
    const [shareCopied, setShareCopied] = useState(false);

    useEffect(() => {
        let active = true;
        setDetails(null);
        setTorrents([]);
        setIsLoading(true);
        setTrailerKey(null);
        setShareCopied(false);

        // Reset TV State
        setEpisodes([]);
        setSelectedSeason(1);
        setExpandedEpisode(null);

        // Reset sticky header state so it doesn't carry over from a previous movie's scroll position
        setHeaderOpacity(0);
        setShowStickyTitle(false);
        if (panelRef.current) panelRef.current.scrollTop = 0;

        if (!movie || !isOpen) return;

        async function fetchData() {
            if (!window.electronAPI || !movie) return;

            // 1. Fetch Details Immediately
            const detailsPromise = (window.electronAPI as any).getMovieDetails(movie.id, movie.type);

            detailsPromise.then((meta: any) => {
                if (!active || !isOpen) return;
                if (meta && !meta.error) {
                    setDetails(meta);
                    setIsLoading(false); // Show UI as soon as details are ready

                    // 2. Fetch Torrents in Background (Movies Only)
                    if (movie.type !== 'tv') {
                        window.electronAPI.getTorrents(meta.imdbId, movie.title, movie.year)
                            .then((torrentList: any[]) => {
                                if (!active || !isOpen) return;
                                if (torrentList) {
                                    setTorrents(torrentList);
                                    if (torrentList.length > 0) {
                                        prewarmRef.current = torrentList[0].magnet;
                                        window.electronAPI.prewarmTorrent(torrentList[0].magnet).catch(() => {});
                                    }
                                }
                            })
                            .catch((e: any) => console.error("Torrent fetch failed", e));
                    }
                }
            }).catch((e: any) => console.error("Details fetch failed", e));

            // 3. Fetch Trailer (Movies & TV)
            (window.electronAPI as any).getTrailer?.(movie.id, movie.type)
                .then((key: string | null) => { if (active) setTrailerKey(key || null); })
                .catch((e: any) => console.error("Trailer fetch failed", e));
        }
        fetchData();
        return () => { active = false; };
    }, [movie, isOpen]);

    const handleTrailer = () => {
        if (!trailerKey || !window.electronAPI) return;
        window.electronAPI.openExternal(`https://www.youtube.com/watch?v=${trailerKey}`);
    };

    const handleShare = async () => {
        if (!movie) return;
        const m = details || movie;
        const downloadUrl = 'https://drive.google.com/drive/folders/1ftzQcKIUkB2sKwInoSdMG7-SH4rPf96i?usp=sharing';
        const smartLink = `https://script.google.com/macros/s/AKfycbzEwmEgC4JXWXz4TPHUUxPon_56ZN4VsOKq7FAw_3rWgRi2L4KIZAx1rs_HZ94-1h6IVg/exec?id=${movie.id}&type=${movie.type}`;
        const message = `🍿 Watch "${m.title || movie.title}" on Popcorn!\n\n📲 Tap to Play: ${smartLink}\n\n📥 Download App: ${downloadUrl}`;

        try {
            await navigator.clipboard.writeText(message);
            setShareCopied(true);
            setTimeout(() => setShareCopied(false), 2000);
        } catch (e) {
            console.error("Share failed", e);
        }
    };

    // Favorites Logic
    const [isFavorite, setIsFavorite] = useState(false);

    useEffect(() => {
        if (!movie || !isOpen || !window.electronAPI) return;
        async function checkFavorite() {
            try {
                const favs = await window.electronAPI.getFavorites();
                setIsFavorite(!!favs[movie!.id.toString()]);
            } catch (e) { console.error(e); }
        }
        checkFavorite();
    }, [movie, isOpen]);

    const toggleFavorite = async () => {
        if (!movie || !window.electronAPI) return;
        try {
            if (isFavorite) {
                await window.electronAPI.removeFavorite(movie.id.toString());
                setIsFavorite(false);
            } else {
                await window.electronAPI.addFavorite(movie);
                setIsFavorite(true);
            }
        } catch (e) {
            console.error(e);
        }
    };



    // Cancel any pending prewarm when the panel closes or the movie changes
    useEffect(() => {
        return () => {
            if (prewarmRef.current && window.electronAPI?.cancelPrewarm) {
                window.electronAPI.cancelPrewarm().catch(() => {});
                prewarmRef.current = null;
            }
        };
    }, [movie, isOpen]);

    // Lock Body Scroll when panel is open
    useEffect(() => {
        if (isOpen) {
            document.body.style.overflow = 'hidden';
        } else {
            document.body.style.overflow = '';
        }
        return () => {
            document.body.style.overflow = '';
        };
    }, [isOpen]);

    if (!movie) return null;

    const description = details?.description || movie.description;
    const genreList: string[] = details?.genres || [];
    const cast = details?.cast ? details.cast.join(', ') : "Loading...";

    return (
        <>
            {/* Backdrop Overlay */}
            <div
                onClick={onClose}
                style={{
                    position: 'fixed', inset: 0,
                    backgroundColor: 'rgba(0,0,0,0.7)',
                    zIndex: 200, // Higher than navbar
                    opacity: isOpen ? 1 : 0,
                    pointerEvents: isOpen ? 'auto' : 'none',
                    transition: 'opacity 0.4s ease-in-out'
                }}
            />

            {/* Sliding Panel (fixed, never scrolls itself — only the inner content area does) */}
            <div
                style={{
                    position: 'fixed',
                    top: 0, right: 0, bottom: 0,
                    width: '45vw', // Slightly narrower
                    minWidth: '500px',
                    maxWidth: '100vw',
                    backgroundColor: '#000000',
                    zIndex: 201,
                    transform: isOpen ? 'translateX(0)' : 'translateX(100%)',
                    transition: 'transform 0.35s cubic-bezier(0.2, 0.8, 0.2, 1)',
                    overflow: 'hidden',
                    boxSizing: 'border-box',
                    boxShadow: '-8px 0 25px rgba(0,0,0,0.7)'
                }}>
                {/* Fixed Overlay: Close/Favorite buttons + sticky title bar — stays put while content scrolls underneath */}
                <div style={{ position: 'absolute', top: 0, left: 0, right: 0, zIndex: 30, pointerEvents: 'none' }}>
                    <div style={{
                        height: '60px',
                        display: 'flex', alignItems: 'center', justifyContent: 'flex-start',
                        padding: '0 60px 0 64px', // left padding clears the close button, right clears the favorite button
                        backgroundColor: `rgba(0,0,0,${headerOpacity * 0.9})`,
                        backdropFilter: headerOpacity > 0.01 ? `blur(${20 * headerOpacity}px)` : 'none',
                        transition: 'background-color 0.1s linear'
                    }}>
                        {details?.logoUrl ? (
                            <img
                                src={details.logoUrl}
                                alt={movie.title}
                                style={{
                                    height: '28px', maxWidth: '160px', objectFit: 'contain',
                                    opacity: showStickyTitle ? 1 : 0,
                                    transition: 'opacity 0.3s ease'
                                }}
                            />
                        ) : (
                            <span style={{
                                color: 'white', fontWeight: 'bold', fontSize: '1.1rem',
                                whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
                                opacity: showStickyTitle ? 1 : 0,
                                transition: 'opacity 0.3s ease'
                            }}>
                                {movie.title}
                            </span>
                        )}
                    </div>

                    {/* Close Button */}
                    <button
                        onClick={onClose}
                        style={{
                            position: 'absolute', top: '15px', left: '15px',
                            background: 'rgba(0,0,0,0.5)',
                            border: 'none', color: 'white',
                            borderRadius: '50%', width: '36px', height: '36px',
                            cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center',
                            backdropFilter: 'blur(4px)',
                            pointerEvents: 'auto'
                        }}
                    >
                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                    </button>

                    {/* Favorites Button */}
                    <button
                        onClick={toggleFavorite}
                        style={{
                            position: 'absolute', top: '15px', right: '15px',
                            background: 'rgba(0,0,0,0.5)',
                            border: 'none', color: isFavorite ? 'var(--primary-color)' : 'white',
                            borderRadius: '50%', width: '36px', height: '36px',
                            cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'center',
                            backdropFilter: 'blur(4px)',
                            transition: 'all 0.2s',
                            pointerEvents: 'auto'
                        }}
                        title={isFavorite ? "Remove from Favorites" : "Add to Favorites"}
                    >
                        <svg width="20" height="20" viewBox="0 0 24 24" fill={isFavorite ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
                            <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path>
                        </svg>
                    </button>
                </div>

                {/* Scrollable Content */}
                <div
                    ref={panelRef}
                    style={{
                        position: 'absolute', inset: 0,
                        overflowY: 'auto',
                        overflowX: 'hidden', // Prevent horizontal scroll
                        boxSizing: 'border-box'
                    }}>

                <style>{`
                    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
                    @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
                    @keyframes popIn {
                        0% { opacity: 0; transform: scale(0.96) translateY(12px); }
                        100% { opacity: 1; transform: scale(1) translateY(0); }
                    }
                `}</style>

                {isLoading ? (
                    <div style={{
                        height: '100%', display: 'flex', flexDirection: 'column',
                        alignItems: 'center', justifyContent: 'center', color: '#777'
                    }}>
                        <div style={{
                            width: '40px', height: '40px',
                            border: '3px solid rgba(255,255,255,0.1)', borderTopColor: 'var(--primary-color)',
                            borderRadius: '50%', animation: 'spin 0.8s linear infinite', marginBottom: '1rem'
                        }} />
                        <p>Loading details...</p>
                    </div>
                ) : (
                    <>
                        {/* Hero Section */}
                        <div style={{
                            position: 'relative',
                            height: '38vh',
                            width: '100%',
                            overflow: 'hidden', // Fixes gradient and video containment
                            backgroundColor: '#000', // Gap fix
                            animation: 'popIn 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) forwards',
                            opacity: 0 // Start hidden
                        }}>
                            <div style={{ position: 'absolute', inset: 0 }}>
                                {/* Parallax Wrapper */}
                                <div ref={parallaxRef} style={{ position: 'absolute', inset: 0, zIndex: 0, willChange: 'transform' }}>
                                    {/* Background Image (Always) */}
                                    <div style={{
                                        position: 'absolute', inset: 0, zIndex: 0,
                                        backgroundImage: `url(${movie.backdropUrl || placeholder})`,
                                        backgroundSize: 'cover', backgroundPosition: 'center'
                                    }} />


                                </div>

                                {/* Gradient Overlay */}
                                <div style={{
                                    position: 'absolute',
                                    bottom: 0, left: 0, right: 0, zIndex: 2,
                                    height: '60%',
                                    background: 'linear-gradient(to bottom, transparent 0%, rgba(0,0,0,0.5) 60%, #000000 100%)',
                                    pointerEvents: 'none'
                                }} />
                            </div>

                            <div style={{
                                position: 'absolute', bottom: '25px', left: '30px', right: '30px',
                                zIndex: 10
                            }}>
                                {details?.logoUrl ? (
                                    <img
                                        src={details.logoUrl}
                                        alt={movie.title}
                                        style={{
                                            maxWidth: '250px',
                                            maxHeight: '100px',
                                            objectFit: 'contain',
                                            filter: 'drop-shadow(0 2px 4px rgba(0,0,0,0.8))',
                                            marginBottom: '0.5rem',
                                            display: 'block'
                                        }}
                                    />
                                ) : (
                                    <h1 style={{
                                        fontSize: '2.2rem',
                                        lineHeight: '1.2',
                                        fontWeight: 800,
                                        marginBottom: '0.5rem',
                                        textShadow: '0 2px 4px rgba(0,0,0,0.8)'
                                    }}>
                                        {movie.title}
                                    </h1>
                                 )}

                                {/* Year • Certification • Runtime + Rating, directly under logo */}
                                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                                    <p style={{ margin: 0, fontSize: '0.9rem', color: '#ddd', fontWeight: 500, textShadow: '0 1px 3px rgba(0,0,0,0.8)' }}>
                                        {details?.year || movie.year || 'N/A'}
                                        {'  •  '}
                                        {details?.certification || 'PG-13'}
                                        {'  •  '}
                                        {details?.runtime || 'N/A'}
                                    </p>
                                    <p style={{ margin: 0, display: 'flex', alignItems: 'center', gap: '4px' }}>
                                        <svg width="14" height="14" viewBox="0 0 24 24" fill="#f5c518" stroke="#f5c518" strokeWidth="1"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>
                                        <span style={{ color: '#f5c518', fontWeight: 'bold', fontSize: '0.9rem' }}>
                                            {details?.imdb || movie.rating || details?.vote_average || 'N/A'}
                                        </span>
                                    </p>
                                </div>
                            </div>
                        </div>

                        {/* Info Section */}
                        <div style={{
                            padding: '0 30px 40px',
                            color: '#ccc',
                            animation: 'popIn 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) forwards',
                            animationDelay: '0.1s',
                            opacity: 0 // Start hidden
                        }}>
                            {/* Trailer / Share Controls */}
                            <div style={{ display: 'flex', gap: '12px', marginBottom: '1.5rem' }}>
                                {trailerKey && (
                                    <button
                                        onClick={handleTrailer}
                                        style={{
                                            flex: 2,
                                            height: '50px',
                                            background: 'rgba(255,255,255,0.1)',
                                            border: 'none',
                                            borderRadius: '30px',
                                            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '8px',
                                            cursor: 'pointer',
                                            fontWeight: 'bold', fontSize: '1rem', color: 'white'
                                        }}
                                    >
                                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>
                                        Trailer
                                    </button>
                                )}

                                <button
                                    onClick={handleShare}
                                    title="Share"
                                    style={{
                                        width: '50px', height: '50px',
                                        background: 'rgba(255,255,255,0.1)',
                                        border: 'none',
                                        borderRadius: '30px',
                                        display: 'flex', alignItems: 'center', justifyContent: 'center',
                                        cursor: 'pointer', color: 'white', flexShrink: 0,
                                        position: 'relative'
                                    }}
                                >
                                    {shareCopied ? (
                                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="20 6 9 17 4 12"></polyline></svg>
                                    ) : (
                                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><circle cx="18" cy="5" r="3"></circle><circle cx="6" cy="12" r="3"></circle><circle cx="18" cy="19" r="3"></circle><line x1="8.59" y1="13.51" x2="15.42" y2="17.49"></line><line x1="15.41" y1="6.51" x2="8.59" y2="10.49"></line></svg>
                                    )}
                                </button>
                            </div>
                            {shareCopied && (
                                <p style={{ color: '#aaa', fontSize: '0.8rem', marginTop: '-1rem', marginBottom: '1rem' }}>Share link copied to clipboard!</p>
                            )}

                            <p style={{
                                fontSize: '1rem', lineHeight: '1.5', color: 'white',
                                marginBottom: '1.5rem', marginTop: '0'
                            }}>
                                {description || "Loading details..."}
                            </p>

                            <div style={{ fontSize: '0.9rem', lineHeight: '1.8' }}>
                                <p><span style={{ color: '#777' }}>Cast:</span> <span style={{ color: 'white' }}>{cast}</span></p>
                            </div>

                            {genreList.length > 0 && (
                                <div style={{ display: 'flex', flexWrap: 'wrap', gap: '8px', marginTop: '1rem' }}>
                                    {genreList.map((g) => (
                                        <span key={g} style={{
                                            padding: '6px 12px',
                                            border: '1px solid rgba(255,255,255,0.15)',
                                            borderRadius: '20px',
                                            fontSize: '0.8rem',
                                            color: '#ddd'
                                        }}>{g}</span>
                                    ))}
                                </div>
                            )}

                            {/* Streams / Episodes Section */}
                            <div style={{
                                marginTop: '2rem',
                                animation: 'popIn 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) forwards',
                                animationDelay: '0.2s',
                                opacity: 0 // Start hidden
                            }}>
                                {movie.type === 'tv' ? (
                                    <>
                                        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '1rem' }}>
                                            <h3 style={{ fontSize: '1.4rem', color: '#eee', margin: 0, fontWeight: 600 }}>Episodes</h3>
                                            {details?.seasons && details.seasons.length > 0 && (
                                                <div ref={seasonDropdownRef} style={{ position: 'relative' }}>
                                                    <button
                                                        onClick={() => setIsSeasonDropdownOpen(!isSeasonDropdownOpen)}
                                                        style={{
                                                            background: 'rgba(255,255,255,0.05)', color: '#fff',
                                                            padding: '8px 16px', border: '1px solid rgba(255,255,255,0.1)',
                                                            borderRadius: '8px', cursor: 'pointer',
                                                            fontSize: '0.95rem', fontWeight: 500,
                                                            display: 'flex', alignItems: 'center', gap: '8px',
                                                            transition: 'all 0.2s',
                                                            backdropFilter: 'blur(10px)'
                                                        }}
                                                        onMouseEnter={e => e.currentTarget.style.background = 'rgba(255,255,255,0.1)'}
                                                        onMouseLeave={e => e.currentTarget.style.background = 'rgba(255,255,255,0.05)'}
                                                    >
                                                        Season {selectedSeason}
                                                        <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3"
                                                            style={{ transform: isSeasonDropdownOpen ? 'rotate(180deg)' : 'rotate(0deg)', transition: 'transform 0.2s' }}>
                                                            <polyline points="6 9 12 15 18 9"></polyline>
                                                        </svg>
                                                    </button>

                                                     <div style={{
                                                         position: 'absolute', top: '100%', right: 0, marginTop: '8px',
                                                         background: '#000', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '8px',
                                                         overflow: 'hidden', zIndex: 100, minWidth: '130px', maxHeight: '300px', overflowY: 'auto',
                                                         boxShadow: '0 10px 40px rgba(0,0,0,0.5)',
                                                         opacity: isSeasonDropdownOpen ? 1 : 0,
                                                         transform: isSeasonDropdownOpen ? 'translateY(0) scale(1)' : 'translateY(-8px) scale(0.95)',
                                                         transformOrigin: 'top right',
                                                         pointerEvents: isSeasonDropdownOpen ? 'auto' : 'none',
                                                         willChange: 'opacity, transform',
                                                         transition: 'opacity 0.28s cubic-bezier(0.2, 0.8, 0.2, 1), transform 0.28s cubic-bezier(0.2, 0.8, 0.2, 1)'
                                                     }}>
                                                         {details.seasons.filter((s: any) => s.season_number > 0).map((s: any) => (
                                                             <button
                                                                 key={s.season_number}
                                                                 onClick={() => {
                                                                     setSelectedSeason(s.season_number);
                                                                     setIsSeasonDropdownOpen(false);
                                                                 }}
                                                                 style={{
                                                                     display: 'block', width: '100%', textAlign: 'left',
                                                                     padding: '8px 12px', background: selectedSeason === s.season_number ? 'rgba(181, 150, 110, 0.1)' : 'transparent',
                                                                     color: selectedSeason === s.season_number ? 'var(--primary-color)' : '#ddd',
                                                                     border: 'none', cursor: 'pointer', fontSize: '0.85rem',
                                                                     borderBottom: '1px solid rgba(255,255,255,0.08)', transition: 'background 0.2s'
                                                                 }}
                                                                 onMouseEnter={e => { if (selectedSeason !== s.season_number) e.currentTarget.style.background = 'rgba(255,255,255,0.08)'; }}
                                                                 onMouseLeave={e => { if (selectedSeason !== s.season_number) e.currentTarget.style.background = 'transparent'; }}
                                                             >
                                                                 <span style={{ fontWeight: 600 }}>{s.name}</span>
                                                             </button>
                                                         ))}
                                                     </div>
                                                </div>
                                            )}
                                        </div>

                                        <div style={{
                                            display: 'grid', gridTemplateColumns: '1fr', gap: '2px', width: '100%',
                                            opacity: loadingEpisodes ? 0.4 : 1,
                                            pointerEvents: loadingEpisodes ? 'none' : 'auto',
                                            transition: 'opacity 0.2s ease'
                                        }}>
                                            {loadingEpisodes && episodes.length === 0 ? (
                                                <p style={{ color: '#777', fontStyle: 'italic' }}>Loading season details...</p>
                                            ) : (
                                                episodes.map(ep => (
                                                    <div key={ep.id} style={{
                                                        width: '100%',
                                                        boxSizing: 'border-box',
                                                        background: '#000',
                                                        border: '1px solid rgba(255,255,255,0.06)',
                                                        padding: '16px',
                                                        borderRadius: '8px',
                                                        transition: 'background 0.2s',
                                                        opacity: isEpisodeReleased(ep.air_date) ? 1 : 0.5,
                                                        pointerEvents: isEpisodeReleased(ep.air_date) ? 'auto' : 'none' // Actually we want to allow click but maybe just show it's disabled? NO, user asked for disabled dropdowns.
                                                    }}>
                                                        <div
                                                            onClick={() => isEpisodeReleased(ep.air_date) && handleEpisodeClick(ep)}
                                                            style={{
                                                                display: 'flex',
                                                                width: '100%',
                                                                cursor: isEpisodeReleased(ep.air_date) ? 'pointer' : 'default',
                                                                alignItems: 'flex-start',
                                                                gap: '12px'
                                                            }}
                                                        >
                                                            {/* Thumbnail */}
                                                            <div style={{
                                                                position: 'relative', width: '140px', height: '80px', flexShrink: 0,
                                                                borderRadius: '4px', overflow: 'hidden', backgroundColor: '#000'
                                                            }}>
                                                                <img
                                                                    src={ep.still_path || movie.backdropUrl || placeholder}
                                                                    alt={ep.name}
                                                                    style={{
                                                                        width: '100%', height: '100%', objectFit: 'cover',
                                                                        opacity: isEpisodeReleased(ep.air_date) ? 1 : 0.6
                                                                    }}
                                                                />
                                                                <div style={{
                                                                    position: 'absolute', inset: 0,
                                                                    background: 'rgba(0,0,0,0.25)',
                                                                    display: 'flex', alignItems: 'center', justifyContent: 'center'
                                                                }}>
                                                                    {isEpisodeReleased(ep.air_date) ? (
                                                                        <svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2" style={{ opacity: 0.9 }}><circle cx="12" cy="12" r="10"></circle><polygon points="10 8 16 12 10 16 10 8" fill="white" stroke="none"></polygon></svg>
                                                                    ) : (
                                                                        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2" style={{ opacity: 0.8 }}><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
                                                                    )}
                                                                </div>
                                                                {getEpisodeProgress(selectedSeason, ep.episode_number) > 0 && (
                                                                    <div style={{
                                                                        position: 'absolute', bottom: 0, left: 0, right: 0, height: '3px',
                                                                        background: 'rgba(0,0,0,0.5)'
                                                                    }}>
                                                                        <div style={{
                                                                            height: '100%', width: `${getEpisodeProgress(selectedSeason, ep.episode_number)}%`,
                                                                            background: 'var(--primary-color)'
                                                                        }} />
                                                                    </div>
                                                                )}
                                                            </div>

                                                            <div style={{ flex: 1, marginRight: '1rem', minWidth: 0 }}>
                                                                <h4 style={{ margin: 0, fontSize: '1rem', color: '#eee', fontWeight: 500 }}>{ep.episode_number}. {ep.name}</h4>
                                                                <p style={{
                                                                    margin: '4px 0 4px', fontSize: '0.85rem', color: '#888',
                                                                    display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical',
                                                                    overflow: 'hidden'
                                                                }}>
                                                                    {ep.overview || "No description available."}
                                                                </p>
                                                                {isEpisodeReleased(ep.air_date) ? (
                                                                    <span style={{ fontSize: '0.8rem', color: '#888' }}>{typeof ep.vote_average === 'number' ? ep.vote_average.toFixed(1) : 'N/A'} ★</span>
                                                                ) : (
                                                                    <span style={{ fontSize: '0.8rem', color: 'var(--primary-color)', fontStyle: 'italic' }}>
                                                                        {ep.air_date ? `Available on: ${new Date(ep.air_date).toLocaleDateString('en-GB')}` : "Release date yet to be announced."}
                                                                    </span>
                                                                )}
                                                            </div>
                                                            <button style={{
                                                                background: 'transparent', border: 'none', color: '#aaa', cursor: isEpisodeReleased(ep.air_date) ? 'pointer' : 'default', flexShrink: 0
                                                            }}>
                                                                {expandedEpisode === ep.id ? (
                                                                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="18 15 12 9 6 15"></polyline></svg>
                                                                ) : (
                                                                    isEpisodeReleased(ep.air_date) ? (
                                                                        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="6 9 12 15 18 9"></polyline></svg>
                                                                    ) : (
                                                                        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ opacity: 0.5 }}>
                                                                            <circle cx="12" cy="12" r="10"></circle>
                                                                            <line x1="12" y1="8" x2="12" y2="12"></line>
                                                                            <line x1="12" y1="16" x2="12.01" y2="16"></line>
                                                                        </svg>
                                                                    )
                                                                )}
                                                            </button>
                                                        </div>

                                                        {/* Expanded View */}
                                                        {expandedEpisode === ep.id && (
                                                            <div style={{ marginTop: '1rem', borderTop: '1px solid rgba(255,255,255,0.08)', paddingTop: '1rem', animation: 'fadeIn 0.3s' }}>
                                                                <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '0.5rem' }}>
                                                                    <h5 style={{ color: '#eee', margin: 0, fontSize: '0.9rem' }}>Select Source:</h5>
                                                                </div>
                                                                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: '12px', animation: 'popIn 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) forwards' }}>
                                                                    {onWebStream && WEB_SERVERS.map(({ provider, label, accentColor }) => (
                                                                        <SourceCard
                                                                            key={provider}
                                                                            title={label}
                                                                            accentColor={accentColor}
                                                                            progress={getEpisodeProgress(selectedSeason, ep.episode_number, provider)}
                                                                            onClick={() => onWebStream(movie.id, selectedSeason, ep.episode_number, provider)}
                                                                        />
                                                                    ))}
                                                                    {episodeTorrents.map((t, i) => (
                                                                        <SourceCard
                                                                            key={i}
                                                                            title={t.title || t.quality}
                                                                            subtitle="Source: P2P"
                                                                            quality={t.quality}
                                                                            size={t.size}
                                                                            seeds={t.seeds}
                                                                            progress={getEpisodeProgress(selectedSeason, ep.episode_number, t.magnet)}
                                                                            onClick={() => onStream({
                                                                                magnet: t.magnet,
                                                                                season: selectedSeason,
                                                                                episode: ep.episode_number,
                                                                                imdbId: details?.imdbId,
                                                                                quality: t.quality,
                                                                                availableStreams: episodeTorrents,
                                                                                seasons: details?.seasons,
                                                                                logoUrl: details?.logoUrl,
                                                                                description: details?.description
                                                                            })}
                                                                        />
                                                                    ))}
                                                                </div>
                                                                {loadingEpisodeTorrents && (
                                                                    <div style={{ display: 'flex', alignItems: 'center', gap: '10px', color: '#777', marginTop: '10px' }}>
                                                                        <div style={{ width: '16px', height: '16px', border: '2px solid #555', borderTopColor: 'var(--primary-color)', borderRadius: '50%', animation: 'spin 1s linear infinite' }} />
                                                                        <span>Searching high-quality streams...</span>
                                                                    </div>
                                                                )}
                                                                {!loadingEpisodeTorrents && episodeTorrents.length === 0 && !onWebStream && <p style={{ color: '#d64d4d', fontSize: '0.9rem', marginTop: '10px' }}>No streams found for this episode.</p>}
                                                            </div>
                                                        )}
                                                    </div>
                                                )))}
                                        </div>
                                        <style>{`@keyframes fadeIn { from { opacity: 0; transform: translateY(-5px); } to { opacity: 1; transform: translateY(0); } }`}</style>
                                    </>
                                ) : (
                                    <>
                                        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: '1rem' }}>
                                            <h3 style={{ fontSize: '1.1rem', color: '#eee', margin: 0 }}>Available Streams</h3>
                                        </div>
                                        {movie.inCinemas ? (
                                            <div style={{
                                                padding: '2rem', border: '1px border #333', background: 'rgba(181,150,110,0.1)',
                                                borderRadius: '8px', textAlign: 'center', color: '#FDEDAD'
                                            }}>
                                                <h4 style={{ marginBottom: '0.5rem' }}>Only In Theaters</h4>
                                                <p style={{ fontSize: '0.9rem', opacity: 0.8 }}>
                                                    This title is currently exclusive to cinemas. <br />
                                                    Digital release is expected in ~45 days.
                                                </p>
                                            </div>
                                        ) : (
                                            (torrents.length > 0 || (!movie.inCinemas && onWebStream)) ? (
                                                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: '12px', animation: 'popIn 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) forwards' }}>
                                                    {onWebStream && !movie.inCinemas && WEB_SERVERS.map(({ provider, label, accentColor }) => (
                                                        <SourceCard
                                                            key={provider}
                                                            title={label}
                                                            accentColor={accentColor}
                                                            progress={getMovieProgress(provider)}
                                                            onClick={() => onWebStream(movie.id, undefined, undefined, provider)}
                                                        />
                                                    ))}
                                                    {torrents.map((t: any, i: number) => (
                                                        <SourceCard
                                                            key={i}
                                                            title={t.title || t.quality}
                                                            subtitle="Source: P2P"
                                                            quality={t.quality}
                                                            size={t.size}
                                                            seeds={t.seeds}
                                                            progress={getMovieProgress(t.magnet)}
                                                            onClick={() => onStream({
                                                                magnet: t.magnet,
                                                                imdbId: details?.imdbId,
                                                                quality: t.quality,
                                                                availableStreams: torrents,
                                                                logoUrl: details?.logoUrl,
                                                                description: details?.description
                                                            })}
                                                        />
                                                    ))}
                                                </div>
                                            ) : (
                                                <p style={{ color: '#777', fontStyle: 'italic' }}>Searching for streams...</p>
                                            )
                                        )}
                                    </>
                                )}
                            </div>
                        </div>
                    </>
                )}
                </div>
            </div>
        </>
    );
};

export default DetailsPanel;
