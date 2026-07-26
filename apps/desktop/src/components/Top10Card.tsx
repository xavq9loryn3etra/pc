import React from 'react';
import type { Movie } from '../data/movies';
import placeholder from '../assets/placeholder.png';

interface Top10CardProps {
    movie: Movie;
    rank: number;
    onPlay: () => void;
}

const Top10Card: React.FC<Top10CardProps> = ({ movie, rank, onPlay }) => {
    return (
        <div
            onClick={onPlay}
            title={movie.title}
            className="top-10-card"
            style={{
                display: 'flex',
                alignItems: 'baseline',
                minWidth: '340px', // Scaled up: ~120px Number + 200px Poster + gap
                position: 'relative',
                cursor: 'pointer',
                transition: 'transform 0.2s',
                marginRight: '1rem',
                marginLeft: rank === 1 ? '10px' : '0'
            }}
            onMouseEnter={e => e.currentTarget.style.transform = 'scale(1.05)'}
            onMouseLeave={e => e.currentTarget.style.transform = 'scale(1)'}
        >
            {/* Big Number using SVG for cleaner stroke */}
            <div style={{
                position: 'relative',
                right: '-35px', // More overlap
                zIndex: 0,
                height: '280px', // Scaled up
                display: 'flex',
                alignItems: 'flex-end'
            }}>
                <svg width="140" height="280" viewBox="0 0 100 150" style={{ overflow: 'visible' }}>
                    <text
                        x="50%" y="150"
                        textAnchor="middle"
                        fill="black"
                        stroke="#595959"
                        strokeWidth="4"
                        fontSize="200" // Bigger font
                        fontWeight="900"
                        fontFamily="Impact, sans-serif"
                    >
                        {rank}
                    </text>
                </svg>
            </div>

            {/* Poster */}
            <div style={{
                minWidth: '200px', // Match standard card width
                height: '300px', // Match standard card height
                borderRadius: '8px',
                overflow: 'hidden',
                zIndex: 1,
                boxShadow: '0 4px 15px rgba(0,0,0,0.5)',
                backgroundColor: '#222'
            }}>
                <img
                    src={movie.posterUrl || placeholder}
                    alt={movie.title}
                    style={{ width: '100%', height: '100%', objectFit: 'cover' }}
                />

                {/* In Cinemas Badge */}
                {movie.inCinemas && (
                    <div style={{
                        position: 'absolute', top: '10px', right: '10px',
                        background: 'var(--primary-color)', color: 'black', fontSize: '0.65rem', fontWeight: 'bold',
                        padding: '3px 6px', borderRadius: '4px', textTransform: 'uppercase',
                        zIndex: 5, boxShadow: '0 2px 4px rgba(0,0,0,0.5)'
                    }}>
                        In Cinemas
                    </div>
                )}
            </div>
        </div>
    );
};

export default Top10Card;
