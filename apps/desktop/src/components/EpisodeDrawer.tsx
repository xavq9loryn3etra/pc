import React, { useState, useRef, useEffect } from 'react';
import placeholder from '../assets/placeholder.png';

const SLIDE_DURATION = 320;

interface EpisodeDrawerProps {
    episodes: any[];
    seasons?: any[];
    title: string;
    logoUrl?: string;
    posterUrl?: string;
    browsingSeason: number;
    playingSeason: number;
    playingEpisode: number;
    loading: boolean;
    getEpisodeProgress: (season: number, episodeNumber: number) => number;
    onSeasonChange: (seasonNumber: number) => void;
    onEpisodeTap: (episodeNumber: number) => void;
    onClose: () => void;
}

function isEpisodeFuture(airDate?: string): { future: boolean; formatted?: string } {
    if (!airDate) return { future: false };
    const date = new Date(airDate);
    if (isNaN(date.getTime())) return { future: false };
    if (date > new Date()) {
        return { future: true, formatted: date.toLocaleDateString('en-GB') };
    }
    return { future: false };
}

// Full-screen dark backdrop + slide-up panel with a scrollable episode grid (desktop-sized, unlike Flutter's mobile horizontal rail).
const EpisodeDrawer: React.FC<EpisodeDrawerProps> = ({
    episodes, seasons, title, logoUrl, posterUrl, browsingSeason, playingSeason, playingEpisode,
    loading, getEpisodeProgress, onSeasonChange, onEpisodeTap, onClose
}) => {
    const [isSeasonMenuOpen, setIsSeasonMenuOpen] = useState(false);
    const seasonMenuRef = useRef<HTMLDivElement>(null);

    // Slide up on mount, slide down on dismiss (transition-based so it can run in both directions).
    const [mounted, setMounted] = useState(false);
    const [closing, setClosing] = useState(false);

    useEffect(() => {
        const id = requestAnimationFrame(() => setMounted(true));
        return () => cancelAnimationFrame(id);
    }, []);

    const dismiss = () => {
        setClosing(true);
        setMounted(false);
        setTimeout(onClose, SLIDE_DURATION);
    };

    return (
        <div
            style={{
                position: 'fixed', inset: 0, zIndex: 1100, display: 'flex', flexDirection: 'column',
                background: mounted ? 'rgba(0,0,0,0.85)' : 'rgba(0,0,0,0)',
                transition: `background-color ${SLIDE_DURATION}ms ease`,
                pointerEvents: closing ? 'none' : 'auto'
            }}
            onClick={dismiss}
        >
            <div
                onClick={e => e.stopPropagation()}
                style={{
                    display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0,
                    transform: mounted ? 'translateY(0)' : 'translateY(100%)',
                    transition: `transform ${SLIDE_DURATION}ms cubic-bezier(0.2, 0.8, 0.2, 1)`
                }}
            >
                {/* Header */}
                <div style={{ display: 'flex', alignItems: 'center', padding: '28px 40px', flexShrink: 0, gap: '20px' }}>
                    {logoUrl ? (
                        <img src={logoUrl} alt={title} style={{ height: '64px', width: '150px', objectFit: 'contain', objectPosition: 'left' }} />
                    ) : (
                        <img src={posterUrl || placeholder} alt={title} style={{ width: '64px', height: '64px', borderRadius: '8px', objectFit: 'cover' }} />
                    )}

                    <div style={{ flex: 1, minWidth: 0 }}>
                        <div style={{ color: 'white', fontSize: '30px', fontWeight: 700, letterSpacing: '-0.5px', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>{title}</div>
                        <div style={{ color: 'rgba(255,255,255,0.6)', fontSize: '17px', marginTop: '2px' }}>Season {browsingSeason}</div>
                    </div>

                    {seasons && seasons.length > 0 && (
                        <div ref={seasonMenuRef} style={{ position: 'relative' }}>
                            <button
                                onClick={() => setIsSeasonMenuOpen(!isSeasonMenuOpen)}
                                style={{
                                    background: 'rgba(255,255,255,0.08)', border: 'none', borderRadius: '8px',
                                    padding: '10px 16px', display: 'flex', alignItems: 'center', gap: '6px', cursor: 'pointer'
                                }}
                            >
                                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="white" strokeWidth="2"><polygon points="12 2 2 7 12 12 22 7 12 2"></polygon><polyline points="2 17 12 22 22 17"></polyline><polyline points="2 12 12 17 22 12"></polyline></svg>
                                <span style={{ color: 'white', fontSize: '15px', fontWeight: 600 }}>Season {browsingSeason}</span>
                                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.5)" strokeWidth="2"><polyline points="6 9 12 15 18 9"></polyline></svg>
                            </button>

                            {isSeasonMenuOpen && (
                                <div style={{
                                    position: 'absolute', top: '100%', right: 0, marginTop: '8px',
                                    background: '#1a1a1a', border: '1px solid rgba(255,255,255,0.1)', borderRadius: '10px',
                                    minWidth: '170px', maxHeight: '300px', overflowY: 'auto', zIndex: 10,
                                    boxShadow: '0 10px 40px rgba(0,0,0,0.5)'
                                }}>
                                    {seasons.filter((s: any) => s.season_number > 0).map((s: any) => (
                                        <button
                                            key={s.season_number}
                                            onClick={() => { onSeasonChange(s.season_number); setIsSeasonMenuOpen(false); }}
                                            style={{
                                                display: 'block', width: '100%', textAlign: 'left', padding: '11px 16px', border: 'none',
                                                background: s.season_number === browsingSeason ? 'rgba(181,150,110,0.12)' : 'transparent',
                                                color: s.season_number === browsingSeason ? 'var(--primary-color)' : 'white',
                                                fontWeight: s.season_number === browsingSeason ? 700 : 500,
                                                fontSize: '16px', cursor: 'pointer'
                                            }}
                                        >
                                            Season {s.season_number}
                                        </button>
                                    ))}
                                </div>
                            )}
                        </div>
                    )}

                    <button onClick={dismiss} style={{ background: 'transparent', border: 'none', color: 'white', cursor: 'pointer', display: 'flex', padding: '4px' }}>
                        <svg width="34" height="34" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                    </button>
                </div>

                {/* Episode Grid */}
                <div style={{
                    flex: 1, minHeight: 0, overflowY: 'auto', padding: '8px 40px 40px',
                    display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(300px, 1fr))',
                    gap: '32px 24px', alignContent: 'start'
                }}>
                    {loading ? (
                        <p style={{ color: '#777', fontStyle: 'italic', fontSize: '16px' }}>Loading episodes...</p>
                    ) : episodes.length === 0 ? (
                        <p style={{ color: '#777', fontStyle: 'italic', fontSize: '16px' }}>No episodes available.</p>
                    ) : (
                        episodes.map((ep: any) => {
                            const isCurrent = browsingSeason === playingSeason && ep.episode_number === playingEpisode;
                            const progress = getEpisodeProgress(browsingSeason, ep.episode_number);
                            const isWatched = progress > 95;
                            const { future: isFuture, formatted } = isEpisodeFuture(ep.air_date);
                            const clickable = !isFuture && !isCurrent;

                            return (
                                <div
                                    key={ep.id}
                                    onClick={() => clickable && onEpisodeTap(ep.episode_number)}
                                    style={{ cursor: clickable ? 'pointer' : 'default' }}
                                >
                                    <div style={{
                                        position: 'relative', width: '100%', aspectRatio: '16 / 9', borderRadius: '16px', overflow: 'hidden',
                                        border: isCurrent ? '3px solid var(--primary-color)' : '1px solid rgba(255,255,255,0.1)',
                                        boxShadow: '0 5px 10px rgba(0,0,0,0.3)',
                                        backgroundColor: '#000'
                                    }}>
                                        <img
                                            src={ep.still_path || placeholder}
                                            alt={ep.name}
                                            style={{ width: '100%', height: '100%', objectFit: 'cover', opacity: isWatched ? 0.4 : (isFuture ? 0.4 : 1) }}
                                        />
                                        <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                                            {isFuture ? (
                                                <svg width="38" height="38" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.6)" strokeWidth="2"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0110 0v4"></path></svg>
                                            ) : isWatched ? (
                                                <svg width="38" height="38" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.6)" strokeWidth="2"><path d="M22 11.08V12a10 10 0 11-5.93-9.14"></path><polyline points="22 4 12 14.01 9 11.01"></polyline></svg>
                                            ) : !isCurrent ? (
                                                <div style={{ width: '60px', height: '60px', borderRadius: '50%', background: 'rgba(0,0,0,0.6)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                                                    <svg width="28" height="28" viewBox="0 0 24 24" fill="white"><path d="M8 5v14l11-7z" /></svg>
                                                </div>
                                            ) : null}
                                        </div>
                                        {progress > 0 && (
                                            <div style={{ position: 'absolute', bottom: '8px', left: '14px', right: '14px', height: '5px', borderRadius: '4px', background: 'rgba(0,0,0,0.5)' }}>
                                                <div style={{ height: '100%', borderRadius: '4px', width: `${Math.min(progress, 100)}%`, background: isCurrent ? 'var(--primary-color)' : 'rgba(255,255,255,0.7)' }} />
                                            </div>
                                        )}
                                    </div>

                                    <div style={{
                                        marginTop: '14px', fontSize: '18px',
                                        fontWeight: isCurrent ? 700 : 600,
                                        color: isCurrent ? 'white' : (isWatched || isFuture) ? 'rgba(255,255,255,0.38)' : 'rgba(255,255,255,0.9)',
                                        display: '-webkit-box', WebkitLineClamp: 2, WebkitBoxOrient: 'vertical', overflow: 'hidden'
                                    }}>
                                        {ep.episode_number}. {ep.name}
                                    </div>

                                    {isCurrent ? (
                                        <div style={{ marginTop: '6px', display: 'flex', alignItems: 'center', gap: '8px' }}>
                                            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="var(--primary-color)" strokeWidth="2"><line x1="4" y1="21" x2="4" y2="14"></line><line x1="4" y1="10" x2="4" y2="3"></line><line x1="12" y1="21" x2="12" y2="12"></line><line x1="12" y1="8" x2="12" y2="3"></line><line x1="20" y1="21" x2="20" y2="16"></line><line x1="20" y1="12" x2="20" y2="3"></line></svg>
                                            <span style={{ color: 'var(--primary-color)', fontSize: '13px', fontWeight: 700, letterSpacing: '1px' }}>NOW PLAYING</span>
                                        </div>
                                    ) : isFuture && formatted ? (
                                        <div style={{ marginTop: '6px', display: 'flex', alignItems: 'center', gap: '8px' }}>
                                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="rgba(255,255,255,0.54)" strokeWidth="2"><rect x="3" y="4" width="18" height="18" rx="2" ry="2"></rect><line x1="16" y1="2" x2="16" y2="6"></line><line x1="8" y1="2" x2="8" y2="6"></line><line x1="3" y1="10" x2="21" y2="10"></line></svg>
                                            <span style={{ color: 'rgba(255,255,255,0.54)', fontSize: '13px', fontWeight: 600 }}>Available on: {formatted}</span>
                                        </div>
                                    ) : null}
                                </div>
                            );
                        })
                    )}
                </div>
            </div>
        </div>
    );
};

export default EpisodeDrawer;
