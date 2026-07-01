import React from 'react';
import type { Movie } from '../data/movies';
import placeholder from '../assets/placeholder.png';

interface PosterCardProps {
    movie: Movie;
    onPlay: (movie: Movie) => void;
    onRemove?: (movie: Movie) => void;
    progress?: number;
}

const PosterCard: React.FC<PosterCardProps> = ({ movie, onPlay, onRemove, progress }) => {
    return (
        <div
            onClick={() => onPlay(movie)}
            title={movie.title}
            style={{
                position: 'relative',
                minWidth: '200px',
                height: '300px',
                borderRadius: '8px',
                overflow: 'hidden',
                cursor: 'pointer',
                transition: 'transform 0.3s ease',
            }}
            className="poster-card"
        >
            <img
                src={movie.posterUrl || placeholder}
                alt={movie.title}
                style={{ width: '100%', height: '100%', objectFit: 'cover' }}
                loading="lazy"
            />

            {/* Floating Progress Bar Pill */}
            {progress !== undefined && progress > 0 && (
                <div style={{
                    position: 'absolute', bottom: '8px', left: '12px', right: '12px',
                    height: '6px', background: 'rgba(0,0,0,0.6)', borderRadius: '4px',
                    zIndex: 15, overflow: 'hidden', border: '1px solid rgba(255,255,255,0.1)'
                }}>
                    <div style={{
                        height: '100%', width: `${progress}%`,
                        background: 'var(--primary-color)', borderRadius: '4px'
                    }} />
                </div>
            )}

            {/* Episode Badge Floating Pill (S1 E1) */}
            {movie.type === 'tv' && movie.season !== undefined && movie.episode !== undefined && (
                <div style={{
                    position: 'absolute',
                    bottom: (progress !== undefined && progress > 0) ? '20px' : '8px',
                    right: '12px',
                    background: 'rgba(0,0,0,0.85)',
                    color: 'white',
                    fontSize: '0.65rem',
                    fontWeight: 'bold',
                    padding: '2px 6px',
                    borderRadius: '4px',
                    border: '1px solid rgba(255,255,255,0.2)',
                    zIndex: 16,
                    boxShadow: '0 2px 4px rgba(0,0,0,0.5)',
                    pointerEvents: 'none'
                }}>
                    S{movie.season} E{movie.episode}
                </div>
            )}

            {/* In Cinemas Badge - Always Visible */}
            {movie.inCinemas && (
                <div style={{
                    position: 'absolute', top: '10px', right: '10px',
                    background: 'var(--primary-color)', color: 'black', fontSize: '0.65rem', fontWeight: 'bold',
                    padding: '3px 6px', borderRadius: '4px', textTransform: 'uppercase',
                    zIndex: 20, boxShadow: '0 2px 4px rgba(0,0,0,0.5)'
                }}>
                    In Cinemas
                </div>
            )}

            {/* Remove Button - Outside Overlay */}
            {onRemove && (
                <div
                    className="remove-btn"
                    onClick={(e) => {
                        e.stopPropagation();
                        onRemove(movie);
                    }}
                    style={{
                        position: 'absolute', top: '5px', right: '5px',
                        background: 'rgba(0,0,0,0.7)', color: 'white',
                        border: '1px solid rgba(255,255,255,0.5)', borderRadius: '50%',
                        width: '30px', height: '30px', alignItems: 'center', justifyContent: 'center',
                        cursor: 'pointer', zIndex: 50, fontSize: '1.2rem', lineHeight: 1, paddingBottom: '2px',
                        boxShadow: '0 2px 4px rgba(0,0,0,0.5)'
                    }}
                    title="Remove from history"
                >
                    ×
                </div>
            )}

            <div className="poster-overlay" style={{
                position: 'absolute', inset: 0,
                background: 'linear-gradient(to top, rgba(0,0,0,0.9) 0%, transparent 60%)',
                opacity: 0, transition: 'opacity 0.2s',
                display: 'flex', flexDirection: 'column', justifyContent: 'flex-end', padding: '1rem',
                zIndex: 10
            }}>
                <h3 style={{ fontSize: '1rem', marginBottom: '0.2rem' }}>{movie.title}</h3>
                <div style={{ fontSize: '0.8rem', color: '#ccc' }}>
                    {movie.year} • {movie.rating}
                </div>

                <div style={{
                    marginTop: '0.5rem', display: 'flex', alignItems: 'center', gap: '0.5rem'
                }}>
                    <button style={{
                        background: movie.inCinemas ? '#555' : 'white',
                        color: movie.inCinemas ? '#aaa' : 'black',
                        borderRadius: '50%',
                        width: '30px', height: '30px', display: 'flex', alignItems: 'center', justifyContent: 'center',
                        padding: 0, border: 'none', cursor: movie.inCinemas ? 'not-allowed' : 'pointer'
                    }}>
                        {movie.inCinemas ? (
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"></rect><path d="M7 11V7a5 5 0 0 1 10 0v4"></path></svg>
                        ) : '▶'}
                    </button>
                    {movie.inCinemas && <span style={{ fontSize: '0.75rem', color: '#aaa', fontStyle: 'italic' }}>Only in Theaters</span>}
                </div>
            </div>

            <style>{`
        .poster-card:hover { transform: scale(1.05); z-index: 10; }
        .poster-card:hover .poster-overlay { opacity: 1; }
        .remove-btn { display: none; }
        .poster-card:hover .remove-btn { display: flex; }
      `}</style>
        </div>
    );
};

export default PosterCard;
