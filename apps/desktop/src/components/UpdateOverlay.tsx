import React, { useState } from 'react';
import Lottie from 'lottie-react';
import updateAnimation from '../assets/update.json';

interface UpdateOverlayProps {
    message?: string;
}

const UpdateOverlay: React.FC<UpdateOverlayProps> = ({ message }) => {
    const [isHovered, setIsHovered] = useState(false);
    const defaultMessage = "A new version of the app is available. Please update to continue.";

    return (
        <div style={{
            position: 'fixed',
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            backgroundColor: '#000000', // Changed to match MaintenanceOverlay opaque background
            zIndex: 9999,
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'center',
            alignItems: 'center',
            color: '#fff',
            padding: '2rem',
            textAlign: 'center'
        }}>
            <div style={{ width: '200px', maxWidth: '100%', marginBottom: '2rem' }}>
                <Lottie animationData={updateAnimation} loop={true} />
            </div>
            <h1 style={{ fontSize: '2.5rem', marginBottom: '1rem', color: 'var(--primary-color)' }}>New Update Is In the Air!</h1>
            <p style={{ fontSize: '1.2rem', marginBottom: '2rem', maxWidth: '600px' }}>
                {message || defaultMessage}
            </p>

            <button
                onClick={() => {
                    const link = 'https://drive.google.com/drive/folders/1ftzQcKIUkB2sKwInoSdMG7-SH4rPf96i?usp=sharing';
                    if (window.electronAPI) {
                        window.electronAPI.openExternal(link);
                    } else {
                        window.open(link, '_blank');
                    }
                }}
                onMouseEnter={() => setIsHovered(true)}
                onMouseLeave={() => setIsHovered(false)}
                style={{
                    padding: '12px 30px',
                    fontSize: '1.1rem',
                    backgroundColor: 'var(--primary-color)',
                    color: 'black',
                    border: 'none',
                    borderRadius: '4px',
                    cursor: 'pointer',
                    fontWeight: 'bold',
                    marginTop: '1rem',
                    transition: 'all 0.2s ease',
                    transform: isHovered ? 'scale(1.02)' : 'scale(1)',
                    opacity: isHovered ? 0.9 : 1
                }}
            >
                Download Update
            </button>
        </div>
    );
};

export default UpdateOverlay;
