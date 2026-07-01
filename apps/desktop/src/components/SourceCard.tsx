import React, { useState } from 'react';

interface SourceCardProps {
    title: string;
    subtitle?: string;
    quality?: string;
    size?: string;
    seeds?: number;
    accentColor?: string;
    progress?: number;
    onClick: () => void;
}

const Badge: React.FC<{ bg: string; color: string; children: React.ReactNode }> = ({ bg, color, children }) => (
    <span style={{
        padding: '4px 8px',
        borderRadius: '6px',
        background: bg,
        color,
        fontWeight: 900,
        fontSize: '11px'
    }}>
        {children}
    </span>
);

// Mirrors the Flutter app's TorrentQualitySelectorSheet card (quality badge, size badge,
// seeders, release name, source label) — reused for both movie & episode sources.
const SourceCard: React.FC<SourceCardProps> = ({ title, subtitle, quality, size, seeds, accentColor, progress, onClick }) => {
    const [hovered, setHovered] = useState(false);
    const hasBadgeRow = !!quality || !!size || typeof seeds === 'number';

    return (
        <div
            onClick={onClick}
            onMouseEnter={() => setHovered(true)}
            onMouseLeave={() => setHovered(false)}
            style={{
                background: hovered ? 'rgba(255,255,255,0.06)' : 'rgba(255,255,255,0.03)',
                border: '1px solid rgba(255,255,255,0.05)',
                borderRadius: '12px',
                padding: '16px',
                cursor: 'pointer',
                position: 'relative',
                overflow: 'hidden',
                transition: 'background 0.2s',
                width: '100%',
                boxSizing: 'border-box',
                textAlign: 'left'
            }}
        >
            {hasBadgeRow && (
                <div style={{ display: 'flex', alignItems: 'center', gap: '8px', marginBottom: '12px' }}>
                    {quality && (
                        <Badge bg={quality === '4K' ? 'rgba(255,193,7,0.15)' : 'rgba(181,150,110,0.15)'} color={quality === '4K' ? '#ffc107' : 'var(--primary-color)'}>
                            {quality}
                        </Badge>
                    )}
                    {size && <Badge bg="rgba(255,255,255,0.08)" color="rgba(255,255,255,0.7)">{size}</Badge>}
                    <div style={{ flex: 1 }} />
                    {typeof seeds === 'number' && (
                        <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#4caf50" strokeWidth="2"><polyline points="22 12 18 12 15 21 9 3 6 12 2 12"></polyline></svg>
                            <span style={{ color: '#4caf50', fontWeight: 'bold', fontSize: '11px' }}>{seeds} seeds</span>
                        </div>
                    )}
                </div>
            )}

            <div style={{
                color: accentColor || 'white',
                fontWeight: accentColor ? 'bold' : 500,
                fontSize: accentColor ? '14px' : '13px',
                lineHeight: 1.3,
                marginBottom: subtitle ? '8px' : 0,
                display: '-webkit-box',
                WebkitLineClamp: 2,
                WebkitBoxOrient: 'vertical',
                overflow: 'hidden'
            }}>
                {title}
            </div>

            {subtitle && (
                <div style={{ color: 'rgba(255,255,255,0.3)', fontSize: '11px' }}>{subtitle}</div>
            )}

            {typeof progress === 'number' && progress > 0 && (
                <div style={{ position: 'absolute', bottom: 0, left: 0, right: 0, height: '4px', background: 'rgba(0,0,0,0.4)' }}>
                    <div style={{ height: '100%', width: `${progress}%`, background: 'var(--primary-color)' }} />
                </div>
            )}
        </div>
    );
};

export default SourceCard;
