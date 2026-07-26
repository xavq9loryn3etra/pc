import React, { useState, useEffect, useRef, useCallback } from 'react';
import type { Movie } from '../data/movies';
import PosterCard from './PosterCard';

interface SearchScreenProps {
  onMovieClick: (movie: Movie) => void;
  onClose: () => void;
  watchHistory: any;
}

const SearchScreen: React.FC<SearchScreenProps> = ({ onMovieClick, onClose, watchHistory }) => {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<Movie[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const debounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  const mapMovies = (raw: any[]): Movie[] => raw.map((s: any) => ({
    id: s.id,
    title: s.title || s.name,
    posterUrl: s.image || (s.poster_path ? `https://image.tmdb.org/t/p/w500${s.poster_path}` : ''),
    year: s.year ? s.year.toString() : (s.release_date || s.first_air_date || '').split('-')[0],
    rating: s.rating || 'N/A',
    type: s.media_type === 'tv' ? 'tv' : 'movie',
    backdropUrl: s.backdrop || (s.backdrop_path ? `https://image.tmdb.org/t/p/w1280${s.backdrop_path}` : ''),
    description: s.description || s.overview || '',
    inCinemas: s.inCinemas || false,
    voteCount: s.voteCount || s.vote_count || 0,
  }));

  const performSearch = useCallback(async (q: string) => {
    if (!window.electronAPI) return;
    setIsLoading(true);
    setError(null);
    try {
      const raw = await window.electronAPI.searchMovies(q);
      const mapped = mapMovies(raw);
      setResults(mapped);
      if (mapped.length === 0) setError('No results found.');
    } catch {
      setError('Search failed. Please check your connection.');
    } finally {
      setIsLoading(false);
    }
  }, []);

  const onInputChange = (val: string) => {
    setQuery(val);
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (!val.trim()) {
      setResults([]);
      setError(null);
      setIsLoading(false);
      return;
    }
    debounceRef.current = setTimeout(() => {
      performSearch(val.trim());
    }, 500);
  };

  const getProgress = (movie: Movie): number | undefined => {
    if (!watchHistory) return undefined;
    const key = `${movie.id}_${movie.type}`;
    const entry = watchHistory[key];
    return entry && entry.duration > 0 ? entry.progress / entry.duration : undefined;
  };

  const renderBody = () => {
    if (isLoading) {
      return (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, gap: '1rem', color: 'rgba(255,255,255,0.5)' }}>
          <div style={{ width: '36px', height: '36px', border: '3px solid rgba(255,255,255,0.1)', borderTopColor: 'var(--primary-color)', borderRadius: '50%', animation: 'spin 0.8s linear infinite' }} />
          <span>Searching...</span>
        </div>
      );
    }
    if (!query.trim()) {
      return (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, gap: '16px' }}>
          <svg width="80" height="80" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.2" style={{ color: 'rgba(255,255,255,0.08)' }}>
            <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
          <p style={{ color: 'rgba(255,255,255,0.2)', fontSize: '1rem', margin: 0 }}>Find your next favorite.</p>
        </div>
      );
    }
    if (error) {
      return (
        <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', flex: 1, gap: '16px' }}>
          <svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" style={{ color: 'rgba(255,255,255,0.3)' }}>
            <circle cx="12" cy="12" r="10" /><line x1="12" y1="8" x2="12" y2="12" /><line x1="12" y1="16" x2="12.01" y2="16" />
          </svg>
          <p style={{ color: 'rgba(255,255,255,0.4)', fontSize: '1rem', margin: 0 }}>{error}</p>
        </div>
      );
    }
    return (
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(160px, 1fr))', gap: '1.25rem', padding: '0 4rem 4rem' }}>
        {results.map(movie => (
          <PosterCard key={movie.id} movie={movie} onPlay={() => onMovieClick(movie)} progress={getProgress(movie)} />
        ))}
      </div>
    );
  };

  return (
    <div style={{ display: 'flex', flexDirection: 'column', minHeight: '100vh', backgroundColor: '#000000' }}>
      {/* Fixed Search Header */}
      <div style={{
        position: 'fixed',
        top: 0,
        width: '100%',
        padding: '20px 4rem',
        background: 'linear-gradient(to bottom, rgba(0,0,0,0.9) 10%, transparent)',
        backdropFilter: 'blur(12px)',
        zIndex: 100,
        display: 'flex',
        alignItems: 'center',
        gap: '1.25rem',
        boxSizing: 'border-box',
      }}>
        {/* Back Button */}
        <button
          onClick={onClose}
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'center',
            background: 'rgba(255, 255, 255, 0.08)',
            border: '1px solid rgba(255, 255, 255, 0.1)',
            borderRadius: '50%',
            width: '42px', height: '42px',
            color: 'white',
            cursor: 'pointer',
            transition: 'all 0.2s ease',
          }}
          onMouseEnter={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.15)'}
          onMouseLeave={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.08)'}
          title="Back"
        >
          <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
            <line x1="19" y1="12" x2="5" y2="12"></line>
            <polyline points="12 19 5 12 12 5"></polyline>
          </svg>
        </button>

        {/* Search Bar */}
        <div style={{
          display: 'flex', alignItems: 'center',
          flex: 1,
          background: 'rgba(255, 255, 255, 0.08)',
          backdropFilter: 'blur(12px)',
          border: '1px solid rgba(255, 255, 255, 0.12)',
          borderRadius: '30px', // Beautiful pill shape matching input radiuses
          padding: '0 20px',
          height: '46px',
          transition: 'all 0.2s ease',
        }}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ color: 'rgba(255,255,255,0.5)', marginRight: '12px', flexShrink: 0 }}>
            <circle cx="11" cy="11" r="8" /><line x1="21" y1="21" x2="16.65" y2="16.65" />
          </svg>
          <input
            ref={inputRef}
            type="text"
            placeholder="Search movies and TV shows..."
            value={query}
            onChange={e => onInputChange(e.target.value)}
            style={{ background: 'transparent', border: 'none', color: 'white', width: '100%', outline: 'none', fontSize: '1.05rem', fontFamily: 'Outfit, system-ui, sans-serif', fontWeight: 400 }}
          />
          {query.length > 0 && (
            <button onClick={() => { setQuery(''); setResults([]); setError(null); inputRef.current?.focus(); }} style={{ background: 'none', border: 'none', color: 'rgba(255,255,255,0.4)', cursor: 'pointer', padding: '4px', display: 'flex', alignItems: 'center', borderRadius: '50%' }} title="Clear">
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" /></svg>
            </button>
          )}
        </div>
      </div>

      {/* Results area */}
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', paddingTop: '110px' }}>{renderBody()}</div>
      <style>{`@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }`}</style>
    </div>
  );
};

export default SearchScreen;