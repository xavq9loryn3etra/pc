import Lottie from 'lottie-react';
import maintenanceAnimation from '../assets/maintenance.json';

interface MaintenanceOverlayProps {
    message?: string;
}

const MaintenanceOverlay: React.FC<MaintenanceOverlayProps> = ({ message }) => {
    return (
        <div style={{
            position: 'fixed',
            top: 0,
            left: 0,
            right: 0,
            bottom: 0,
            backgroundColor: '#000000',
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
                <Lottie animationData={maintenanceAnimation} loop={true} />
            </div>
            <h1 style={{ fontSize: '2.5rem', marginBottom: '1rem' }}>Under Maintenance</h1>
            <p style={{ fontSize: '1.2rem', color: '#aaa', maxWidth: '600px' }}>
                {message || "We are currently upgrading our servers to verify streams faster. We'll be back shortly!"}
            </p>
        </div>
    );
};

export default MaintenanceOverlay;
