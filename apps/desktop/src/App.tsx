import { useState, useEffect, useRef } from 'react';
import { fetchAndActivate, getValue } from "firebase/remote-config";
import { logEvent } from "firebase/analytics";
import semver from "semver";

import { analytics, remoteConfig } from "./firebase";
import packageJson from "../package.json";
import UpdateOverlay from "./components/UpdateOverlay";
import MaintenanceOverlay from "./components/MaintenanceOverlay";

import Hero from './components/Hero';
import VideoPlayer from './components/VideoPlayer';
import WebPlayer, { type WebProvider } from './components/WebPlayer';
import PosterCard from './components/PosterCard';
import SearchScreen from './components/SearchScreen';
import type { Movie } from './data/movies';
import type { PlayStreamOptions, StreamOption } from './types/stream';
import logo from './assets/logo.svg';
import './index.css';


// ... (imports remain similar, will need DetailsPanel)
import DetailsPanel from './components/DetailsPanel';
import SplashScreen from './components/SplashScreen';
// Custom hook for drag-to-scroll behavior
function useDragScroll() {
  const ref = useRef<HTMLDivElement>(null);
  const [isDown, setIsDown] = useState(false);
  const [startX, setStartX] = useState(0);
  const [scrollLeft, setScrollLeft] = useState(0);
  const [hasDragged, setHasDragged] = useState(false);

  const onMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return; // only left click
    const el = ref.current;
    if (!el) return;
    setIsDown(true);
    setHasDragged(false);
    setStartX(e.pageX - el.offsetLeft);
    setScrollLeft(el.scrollLeft);
  };

  const onMouseLeave = () => {
    setIsDown(false);
  };

  const onMouseUp = () => {
    setIsDown(false);
  };

  const onMouseMove = (e: React.MouseEvent) => {
    if (!isDown) return;
    const el = ref.current;
    if (!el) return;
    e.preventDefault();
    const x = e.pageX - el.offsetLeft;
    const walk = (x - startX) * 1.5;
    if (Math.abs(x - startX) > 5) {
      setHasDragged(true);
    }
    el.scrollLeft = scrollLeft - walk;
  };

  const onClickCapture = (e: React.MouseEvent) => {
    if (hasDragged) {
      e.stopPropagation();
      e.preventDefault();
      setHasDragged(false);
    }
  };

  return {
    ref,
    props: {
      onMouseDown,
      onMouseLeave,
      onMouseUp,
      onMouseMove,
      onClickCapture,
      style: {
        cursor: isDown ? 'grabbing' : 'grab',
        userSelect: 'none' as const,
        scrollBehavior: isDown ? ('auto' as const) : ('smooth' as const)
      }
    }
  };
}

function App() {
  const trendingScroll = useDragScroll();
  const continueScroll = useDragScroll();
  const topRatedScroll = useDragScroll();
  // Remote Config State
  const [isUpdateRequired, setIsUpdateRequired] = useState(false);
  const [isMaintenanceMode, setIsMaintenanceMode] = useState(false);
  const [maintenanceMessage, setMaintenanceMessage] = useState("");
  const [updateMessage, setUpdateMessage] = useState("");

  const [trendingMovies, setTrendingMovies] = useState<Movie[]>([]);
  const [continueWatching, setContinueWatching] = useState<Movie[]>([]);
  const [topRatedMovies, setTopRatedMovies] = useState<Movie[]>([]);
  const [heroMovies, setHeroMovies] = useState<Movie[]>([]);

  const [showSearch, setShowSearch] = useState(false);

  // Favorites State
  const [showFavorites, setShowFavorites] = useState(false);
  const [favorites, setFavorites] = useState<Movie[]>([]);

  // Splash Screen State
  const [showSplash, setShowSplash] = useState(true);
  const [dataLoaded, setDataLoaded] = useState(false);

  const [streamUrl, setStreamUrl] = useState<string | null>(null);
  const [webStreamParams, setWebStreamParams] = useState<{ tmdbId: string, season?: number, episode?: number, provider?: WebProvider } | null>(null);
  const [playbackParams, setPlaybackParams] = useState<{ tmdbId: string, season?: number, episode?: number, magnet?: string, imdbId?: string, quality?: string, availableStreams?: StreamOption[], seasons?: any[], logoUrl?: string, description?: string } | null>(null);
  const [loading, setLoading] = useState(false);
  const [loadingMessage, setLoadingMessage] = useState("");
  const [showBackupModal, setShowBackupModal] = useState(false);


  // Side Panel State
  const [selectedMovie, setSelectedMovie] = useState<Movie | null>(null);
  const [isPanelOpen, setIsPanelOpen] = useState(false);
  const [watchHistory, setWatchHistory] = useState<any>(null);

  // Initialize Firebase & Check Config
  useEffect(() => {
    // 1. Log App Open
    logEvent(analytics, 'app_open');

    // 2. Fetch Remote Config
    const checkConfig = async () => {
      try {
        await fetchAndActivate(remoteConfig);

        // Check Maintenance
        const maintenance = getValue(remoteConfig, "maintenance_mode_enabled").asBoolean();
        const msg = getValue(remoteConfig, "maintenance_message").asString();

        if (maintenance) {
          setIsMaintenanceMode(true);
          setMaintenanceMessage(msg);
          // If maintenance is on, we can optionally stop loading other data, 
          // but usually it's better to just overlay.
        }

        // Check Version
        const minVersion = getValue(remoteConfig, "min_required_version").asString();
        const currentVersion = packageJson.version;

        if (semver.lt(currentVersion, minVersion)) {
          const updateMsg = getValue(remoteConfig, "update_required_message").asString();
          setUpdateMessage(updateMsg);
          console.warn(`Update required! Current: ${currentVersion}, Min: ${minVersion}`);
          setIsUpdateRequired(true);
        }

      } catch (err) {
        console.error("Failed to fetch remote config:", err);
      }
    };

    checkConfig();
  }, []);

  useEffect(() => {
    async function fetchContent() {
      if (!window.electronAPI) return;

      try {
        // 1. Fetch Trending FIRST (Hero + Rows)
        const trendingRaw = await window.electronAPI.getTrending();
        const trendingMovies = mapMovies(trendingRaw);

        if (trendingMovies.length > 0) {
          // Pick a random featured movie from the top 10 trending (same as Flutter client),
          // so the hero changes each time the app is opened instead of always being #1.
          const randomIndex = Math.floor(Math.random() * Math.min(trendingMovies.length, 10));
          const featured = trendingMovies[randomIndex];
          const rest = trendingMovies.filter((_, i) => i !== randomIndex);
          setHeroMovies([featured, ...rest].slice(0, 5));

          // Top Rated is trending reversed (same as Flutter client)
          const topRated = trendingMovies.slice().reverse();

          setTrendingMovies(trendingMovies);
          setTopRatedMovies(topRated);
        }

        // 2. Fetch History
        const history = await (window.electronAPI as any).getWatchHistory();
        console.log("Loaded Watch History:", history);
        setWatchHistory(history);

      } catch (e) {
        console.error("Failed to fetch content:", e);
      } finally {
        setDataLoaded(true);
      }
    }
    fetchContent();
  }, []);

  const handleRemoveFromHistory = async (movie: Movie) => {
    if (!window.electronAPI) return;
    try {
      await window.electronAPI.removeWatchProgress(movie.id.toString());
      const history = await window.electronAPI.getWatchHistory();
      setWatchHistory(history);
    } catch (e) { console.error(e); }
  };

  useEffect(() => {
    if (!watchHistory || !window.electronAPI) return;

    async function loadContinueWatching() {
      const candidates: any[] = [];

      // Movies
      if (watchHistory.movies) {
        Object.entries(watchHistory.movies).forEach(([id, data]: [string, any]) => {
          candidates.push({ id, ...data, type: 'movie' });
        });
      }

      // Shows
      if (watchHistory.shows) {
        Object.entries(watchHistory.shows).forEach(([id, eps]: [string, any]) => {
          // Find latest watched ep
          let latestVal = 0;
          let latestEpKey: string | null = null;
          let latestEp: any = null;
          Object.entries(eps || {}).forEach(([epKey, progress]: [string, any]) => {
            if (progress.lastWatched > latestVal) {
              latestVal = progress.lastWatched;
              latestEpKey = epKey;
              latestEp = progress;
            }
          });

          if (latestEp && latestEpKey) {
            const match = (latestEpKey as string).match(/s(\d+)e(\d+)/i);
            const season = match ? parseInt(match[1]) : undefined;
            const episode = match ? parseInt(match[2]) : undefined;
            candidates.push({ 
              id, 
              ...latestEp, 
              type: 'tv',
              season,
              episode
            });
          }
        });
      }

      candidates.sort((a, b) => b.lastWatched - a.lastWatched);
      const top = candidates;

      if (top.length === 0) {
        setContinueWatching([]);
        return;
      }

      // Fetch details
      const movies = await Promise.all(top.map(async (c) => {
        try {
          const d = await window.electronAPI.getMovieDetails(c.id, c.type);
          return {
            id: d.id,
            title: d.title || d.name,
            posterUrl: d.image,
            year: d.year ? d.year.toString() : (d.release_date || d.first_air_date || '').split('-')[0],
            rating: d.rating || 'N/A',
            type: c.type,
            backdropUrl: d.backdrop,
            description: d.description,
            inCinemas: d.inCinemas,
            voteCount: d.voteCount || 0,
            season: c.season,
            episode: c.episode
          } as Movie;
        } catch (e) { return null; }
      }));

      const validMovies = movies.filter(Boolean) as Movie[];

      if (validMovies.length > 0) {
        setContinueWatching(validMovies);
      } else {
        setContinueWatching([]);
      }
    }
    loadContinueWatching();
  }, [watchHistory]);

  const mapMovies = (raw: any[]): Movie[] => {
    return raw.map((s: any) => ({
      id: s.id,
      title: s.title,
      year: s.year,
      posterUrl: s.image,
      rating: s.rating || 'N/A',
      voteCount: s.voteCount,
      description: "",
      backdropUrl: s.backdrop || s.image,
      inCinemas: s.inCinemas,
      type: s.type,
    }));
  };

  const getProgress = (movie: Movie): number => {
    if (!watchHistory) return 0;

    // Handle TV Shows
    if (movie.type === 'tv') {
      if (!watchHistory.shows) return 0;
      const show = watchHistory.shows[movie.id.toString()];
      if (!show) return 0;

      // Find most recently watched episode
      let lastWatched = 0;
      let progress = 0;
      let duration = 0;

      Object.values(show).forEach((ep: any) => {
        if (ep.lastWatched > lastWatched) {
          lastWatched = ep.lastWatched;
          progress = ep.progress;
          duration = ep.duration;
        }
      });

      if (duration > 0) return (progress / duration) * 100;
      return 0;
    }

    // Handle Movies
    if (watchHistory.movies) {
      const entry = watchHistory.movies[movie.id.toString()];
      if (entry && entry.duration) return (entry.progress / entry.duration) * 100;
    }

    return 0;
  };




  // OPEN PANEL on Poster Click instead of immediate play (optional, or separate button?)
  // User said "When an movie item is clicked ... it should open a side panel"
  const handlePosterClick = (movie: Movie) => {
    setSelectedMovie(movie);
    setIsPanelOpen(true);
  };

  const handleMoreInfoClick = (movie: Movie) => {
    setSelectedMovie(movie);
    setIsPanelOpen(true);
  };

  const startStream = async ({ magnet, season, episode, imdbId, quality, availableStreams, seasons, logoUrl, description }: PlayStreamOptions) => {
    setLoading(true);
    setLoadingMessage("Buffering stream... (this may take a few seconds)");

    // Set ID for history tracking
    const targetMovie = selectedMovie;
    if (targetMovie) {
      setPlaybackParams({ tmdbId: targetMovie.id.toString(), season, episode, magnet, imdbId, quality, availableStreams, seasons, logoUrl, description });
    }

    try {
      const { url } = await window.electronAPI.startStream(magnet);
      setStreamUrl(url);
    } catch (err) {
      console.error("Stream failed:", err);
      alert("Failed to start stream.");
    } finally {
      setLoading(false);
      setLoadingMessage("");
    }
  };

  const handleClosePlayer = async () => {
    setStreamUrl(null);
    setWebStreamParams(null);
    setPlaybackParams(null);
    if (window.electronAPI) {
      await window.electronAPI.stopStream();
      // Refetch history to update UI immediately
      const history = await window.electronAPI.getWatchHistory();
      setWatchHistory(history);
    }
  };

  const handleWebStream = (tmdbId: string, season?: number, episode?: number, provider: WebProvider = 'vidking') => {
    setWebStreamParams({ tmdbId, season, episode, provider });
    // Keep panel open underneath
  };

  const handleWebPlayerClose = async () => {
    setWebStreamParams(null);
    if (window.electronAPI) {
      // Refresh history to show progress immediately
      const history = await window.electronAPI.getWatchHistory();
      setWatchHistory(history);
    }
  };

  if (isUpdateRequired) {
    return <UpdateOverlay message={updateMessage} />;
  }

  if (isMaintenanceMode) {
    return <MaintenanceOverlay message={maintenanceMessage} />;
  }

  return (
    <div className="App">

      {showSplash && !isUpdateRequired && !isMaintenanceMode && (
        <SplashScreen
          isReady={dataLoaded}
          onComplete={() => setShowSplash(false)}
        />
      )}

      {/* ... QualityModal and Loading Overlay ... */}


      {/* Loading Overlay ... */}
      {loading && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.9)',
          display: 'flex', flexDirection: 'column', justifyContent: 'center', alignItems: 'center', zIndex: 9999
        }}>
          {/* ... spinner code ... */}
          <div style={{
            width: '50px', height: '50px',
            border: '4px solid var(--primary-color)', borderTopColor: 'transparent',
            borderRadius: '50%', animation: 'spin 1s linear infinite'
          }} />
          <p style={{ marginTop: '1rem', color: '#fff' }}>{loadingMessage}</p>
          {/* ... cancel button code ... */}
          <button
            onClick={async () => {
              setLoading(false);
              setLoadingMessage("");
              if (window.electronAPI) await window.electronAPI.stopStream();
            }}
            style={{
              marginTop: '2rem', padding: '8px 24px', background: 'transparent', border: '1px solid #666', color: '#ccc', borderRadius: '4px', cursor: 'pointer'
            }}
          >
            Cancel
          </button>
          <style>{`@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }`}</style>
        </div>
      )}

      {streamUrl && (
        <VideoPlayer
          url={streamUrl}
          onClose={handleClosePlayer}
          onWebStream={(id, s, e, p) => {
            handleClosePlayer(); // Close current player first
            setWebStreamParams({ tmdbId: id, season: s, episode: e, provider: p });
          }}
          tmdbId={playbackParams?.tmdbId}
          season={playbackParams?.season}
          episode={playbackParams?.episode}
          magnet={playbackParams?.magnet}
          imdbId={playbackParams?.imdbId}
          title={selectedMovie?.title}
          movieType={selectedMovie?.type}
          logoUrl={playbackParams?.logoUrl || selectedMovie?.logoUrl}
          description={playbackParams?.description || selectedMovie?.description}
          quality={playbackParams?.quality}
          availableStreams={playbackParams?.availableStreams}
          seasons={playbackParams?.seasons}
        />
      )}

      {webStreamParams && (
        <WebPlayer
          tmdbId={webStreamParams.tmdbId}
          season={webStreamParams.season}
          episode={webStreamParams.episode}
          provider={webStreamParams.provider}
          onClose={handleWebPlayerClose}
        />
      )}

      <div style={{ display: (streamUrl || webStreamParams) ? 'none' : 'block' }}>
        {/* ... Nav Bar ... */}
        {!showSearch && !showFavorites && (
          <div style={{
            position: 'fixed', top: 0, width: '100%', padding: '20px 4rem',
            background: 'linear-gradient(to bottom, rgba(0,0,0,0.9) 10%, transparent)',
            zIndex: 100, display: 'flex', alignItems: 'center', justifyContent: 'space-between', boxSizing: 'border-box'
          }}>
          <div style={{ display: 'flex', alignItems: 'center' }}>
            {/* Click Logo to reset view */}
            <div style={{ marginRight: '2rem', cursor: 'pointer' }} 
              onClick={() => { setShowSearch(false); setShowFavorites(false); setIsPanelOpen(false); }}
            >
              <img src={logo} alt="Popcorn" style={{ height: '40px', objectFit: 'contain' }} />
            </div>
          </div>


          <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
            {/* Search Button */}
            <button
              onClick={() => { setShowSearch(true); setShowFavorites(false); }}
              style={{
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: showSearch ? 'rgba(255, 255, 255, 0.15)' : 'rgba(255, 255, 255, 0.08)',
                backdropFilter: 'blur(12px)',
                border: '1px solid rgba(255, 255, 255, 0.1)',
                borderRadius: '8px',
                padding: '0',
                width: '42px', height: '42px',
                cursor: 'pointer',
                transition: 'all 0.3s ease',
                boxShadow: '0 4px 30px rgba(0, 0, 0, 0.1)',
                color: showSearch ? 'var(--primary-color)' : 'white',
              }}
              onMouseEnter={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.12)'}
              onMouseLeave={e => e.currentTarget.style.background = showSearch ? 'rgba(255, 255, 255, 0.15)' : 'rgba(255, 255, 255, 0.08)'}
              title="Search"
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <circle cx="11" cy="11" r="8" />
                <line x1="21" y1="21" x2="16.65" y2="16.65" />
              </svg>
            </button>

            {/* Favorites Button */}
            <button
              onClick={async () => {
                if (showFavorites) {
                  setShowFavorites(false);
                } else {
                  setShowFavorites(true);
                  setShowSearch(false);
                  if (window.electronAPI) {
                    try {
                      const favs = await window.electronAPI.getFavorites();
                      setFavorites(Object.values(favs));
                    } catch (e) { console.error(e); }
                  }
                }
              }}
              style={{
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: 'rgba(255, 255, 255, 0.08)',
                backdropFilter: 'blur(12px)',
                border: '1px solid rgba(255, 255, 255, 0.1)',
                borderRadius: '8px',
                padding: '0',
                width: '42px', height: '42px',
                cursor: 'pointer',
                transition: 'all 0.3s ease',
                boxShadow: '0 4px 30px rgba(0, 0, 0, 0.1)',
                color: showFavorites ? 'var(--primary-color)' : 'white',
              }}
              onMouseEnter={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.12)'}
              onMouseLeave={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.08)'}
              title="Favorites"
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill={showFavorites ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
                <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path>
              </svg>
            </button>

            {/* Backup & Restore Button */}
            <button
              onClick={() => setShowBackupModal(true)}
              style={{
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                background: 'rgba(255, 255, 255, 0.08)',
                backdropFilter: 'blur(12px)',
                border: '1px solid rgba(255, 255, 255, 0.1)',
                borderRadius: '8px',
                padding: '0',
                width: '42px', height: '42px',
                cursor: 'pointer',
                transition: 'all 0.3s ease',
                boxShadow: '0 4px 30px rgba(0, 0, 0, 0.1)',
                color: 'white',
              }}
              onMouseEnter={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.12)'}
              onMouseLeave={e => e.currentTarget.style.background = 'rgba(255, 255, 255, 0.08)'}
              title="Backup & Restore"
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21.5 2v6h-6M21.34 15.57a10 10 0 1 1-.57-8.38l5.67-5.67"/>
              </svg>
            </button>
          </div>
        </div>
      )}

        {/* Side Panel */}
        <DetailsPanel
          movie={selectedMovie}
          isOpen={isPanelOpen}
          onClose={async () => {
            setIsPanelOpen(false);
            if (showFavorites && window.electronAPI) {
              try {
                const favs = await window.electronAPI.getFavorites();
                setFavorites(Object.values(favs));
              } catch (e) { console.error(e); }
            }
          }}
          onStream={startStream}
          onWebStream={handleWebStream}
          watchHistory={watchHistory}
        />

        {showSearch ? (
          <SearchScreen
            onMovieClick={handlePosterClick}
            onClose={() => setShowSearch(false)}
            watchHistory={watchHistory}
          />
        ) : showFavorites ? (
          <>
            {/* Dedicated Favorites Header */}
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
              gap: '20px',
              boxSizing: 'border-box',
            }}>
              {/* Back Button */}
              <button
                onClick={() => setShowFavorites(false)}
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

              {/* Title 'My List' */}
              <h2 style={{ fontSize: '1.8rem', fontWeight: 700, margin: 0, color: 'white' }}>
                My List
              </h2>
            </div>

            <div style={{ paddingTop: '110px', paddingLeft: '4rem', paddingRight: '4rem', minHeight: '80vh' }}>
              <div style={{ display: 'flex', flexWrap: 'wrap', gap: '2rem', marginTop: '2rem', justifyContent: favorites.length > 0 ? 'flex-start' : 'center', alignItems: favorites.length > 0 ? 'flex-start' : 'center', minHeight: favorites.length > 0 ? 'auto' : '50vh' }}>
                {favorites.length > 0 ? favorites.map(movie => (
                  <PosterCard key={movie.id} movie={movie} onPlay={() => handlePosterClick(movie)} progress={getProgress(movie)} />
                )) : (
                  <p style={{ color: '#777', fontSize: '1.1rem', marginTop: '2rem' }}>You haven't added any favorites yet.</p>
                )}
              </div>
            </div>
          </>
        ) : (
          <>
            {heroMovies.length > 0 && (
              <Hero
                movies={heroMovies}
                onMoreInfo={handleMoreInfoClick}
                isPaused={isPanelOpen} // Pause Main Hero if panel is open
              />
            )}

            <div style={{ padding: '20px 0', marginTop: '-150px', position: 'relative', zIndex: 20 }}>
              {trendingMovies.length > 0 && (
                <div style={{ padding: '0 4rem', marginBottom: '3rem' }}>
                  <h3 style={{ marginBottom: '1rem', fontSize: '1.4rem' }}>Trending This Week</h3>
                  <div 
                    ref={trendingScroll.ref}
                    {...trendingScroll.props}
                    style={{
                      display: 'flex', gap: '1rem', overflowX: 'auto', padding: '20px 20px',
                      ...trendingScroll.props.style
                    }} 
                    className="hide-scrollbar"
                  >
                    {trendingMovies.map((movie) => (
                      <PosterCard
                        key={movie.id}
                        movie={movie}
                        onPlay={() => handlePosterClick(movie)}
                        progress={getProgress(movie)}
                      />
                    ))}
                  </div>
                </div>
              )}

              {continueWatching.length > 0 && (
                <div style={{ padding: '0 4rem', marginBottom: '3rem' }}>
                  <h3 style={{ marginBottom: '1rem', fontSize: '1.4rem' }}>Continue Watching</h3>
                  <div 
                    ref={continueScroll.ref}
                    {...continueScroll.props}
                    style={{
                      display: 'flex', gap: '1rem', overflowX: 'auto', padding: '20px 20px',
                      ...continueScroll.props.style
                    }} 
                    className="hide-scrollbar"
                  >
                    {continueWatching.map((movie) => (
                      <PosterCard
                        key={movie.id}
                        movie={movie}
                        onPlay={() => handlePosterClick(movie)}
                        progress={getProgress(movie)}
                        onRemove={handleRemoveFromHistory}
                      />
                    ))}
                  </div>
                </div>
              )}

              {topRatedMovies.length > 0 && (
                <div style={{ padding: '0 4rem', marginBottom: '3rem' }}>
                  <h3 style={{ marginBottom: '1rem', fontSize: '1.4rem' }}>Top Rated</h3>
                  <div 
                    ref={topRatedScroll.ref}
                    {...topRatedScroll.props}
                    style={{
                      display: 'flex', gap: '1rem', overflowX: 'auto', padding: '20px 20px',
                      ...topRatedScroll.props.style
                    }} 
                    className="hide-scrollbar"
                  >
                    {topRatedMovies.map((movie) => (
                      <PosterCard
                        key={movie.id}
                        movie={movie}
                        onPlay={() => handlePosterClick(movie)}
                        progress={getProgress(movie)}
                      />
                    ))}
                  </div>
                </div>
              )}
            </div>
          </>
        )}
      </div>
      {showBackupModal && (
        <div style={{
          position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.85)',
          display: 'flex', justifyContent: 'center', alignItems: 'center', zIndex: 10000,
          backdropFilter: 'blur(8px)'
        }}>
          <div style={{
            background: '#000000', border: '1px solid #333', borderRadius: '12px',
            padding: '2rem', maxWidth: '450px', width: '90%', textAlign: 'center',
            boxShadow: '0 20px 40px rgba(0,0,0,0.6)', color: 'white',
            animation: 'modalSlideIn 0.3s cubic-bezier(0.2, 0.8, 0.2, 1) forwards'
          }}>
            <h2 style={{ marginTop: 0, marginBottom: '1rem', fontSize: '1.5rem', fontWeight: 600 }}>Backup & Restore</h2>
            <p style={{ color: '#aaa', fontSize: '0.95rem', lineHeight: '1.5', marginBottom: '2rem' }}>
              Export your watch history, resume progress, and favorites to a JSON backup file, or import them from a previously saved backup.
            </p>
            <div style={{ display: 'flex', flexDirection: 'column', gap: '12px' }}>
              <button
                onClick={async () => {
                  setShowBackupModal(false);
                  setLoading(true);
                  setLoadingMessage("Exporting backup...");
                  try {
                    const success = await window.electronAPI.exportBackup();
                    if (success) {
                      alert("Backup exported successfully!");
                    } else {
                      alert("Backup export cancelled or failed.");
                    }
                  } catch (e) {
                    console.error(e);
                    alert("Failed to export backup.");
                  } finally {
                    setLoading(false);
                    setLoadingMessage("");
                  }
                }}
                style={{
                  background: 'var(--primary-color, #b5966e)', color: '#000',
                  padding: '12px', border: 'none', borderRadius: '8px', cursor: 'pointer',
                  fontWeight: 'bold', fontSize: '1rem', transition: 'all 0.2s'
                }}
              >
                Export Backup
              </button>
              <button
                onClick={async () => {
                  setShowBackupModal(false);
                  setLoading(true);
                  setLoadingMessage("Importing backup...");
                  try {
                    const success = await window.electronAPI.importBackup();
                    if (success) {
                      alert("Backup imported successfully! Reloading history...");
                      // Fetch watch history and favorites again to update the UI
                      const history = await window.electronAPI.getWatchHistory();
                      setWatchHistory(history);
                      if (showFavorites) {
                        const favs = await window.electronAPI.getFavorites();
                        setFavorites(Object.values(favs));
                      }
                    } else {
                      alert("Backup import cancelled or failed.");
                    }
                  } catch (e) {
                    console.error(e);
                    alert("Failed to import backup.");
                  } finally {
                    setLoading(false);
                    setLoadingMessage("");
                  }
                }}
                style={{
                  background: '#2a2a2a', color: '#fff',
                  padding: '12px', border: '1px solid #444', borderRadius: '8px', cursor: 'pointer',
                  fontWeight: 'bold', fontSize: '1rem', transition: 'all 0.2s'
                }}
                onMouseEnter={e => e.currentTarget.style.background = '#333'}
                onMouseLeave={e => e.currentTarget.style.background = '#2a2a2a'}
              >
                Import Backup
              </button>
              <button
                onClick={() => setShowBackupModal(false)}
                style={{
                  background: 'transparent', color: '#888',
                  padding: '8px', border: 'none', cursor: 'pointer',
                  fontSize: '0.9rem', marginTop: '8px'
                }}
                onMouseEnter={e => e.currentTarget.style.color = '#fff'}
                onMouseLeave={e => e.currentTarget.style.color = '#888'}
              >
                Cancel
              </button>
            </div>
          </div>
          <style>{`
            @keyframes modalSlideIn {
              from { opacity: 0; transform: scale(0.9) translateY(20px); }
              to { opacity: 1; transform: scale(1) translateY(0); }
            }
          `}</style>
        </div>
      )}
    </div>
  );
}

export default App;
