import React, { useEffect, useState } from 'react';
import { Link, Navigate } from 'react-router-dom';
import { useAuth } from '../../data/auth';
import { supabase } from '../../data/client';
import { PixelButton, PixelBrickTile, Modal, PixelLoader, ErrorBanner } from '../../ui';
import { CreateRoomView } from './CreateRoomView';

export const AdminDashboardPage: React.FC = () => {
  const { user, logout } = useAuth();
  const [checkingActiveRoom, setCheckingActiveRoom] = useState(true);
  const [activeRoomId, setActiveRoomId] = useState<string | null>(null);
  const [logoutConfirmOpen, setLogoutConfirmOpen] = useState(false);
  const [roomCheckError, setRoomCheckError] = useState<string | null>(null);
  const [checkAttempt, setCheckAttempt] = useState(0);

  useEffect(() => {
    let isMounted = true;
    async function checkCurrentRoom() {
      try {
        const { data, error } = await supabase
          .from('rooms')
          .select('id, status')
          .neq('status', 'FINALIZED')
          .order('created_at', { ascending: false })
          .limit(1)
          .maybeSingle();

        if (error) {
          throw error;
        }
        if (data?.id && isMounted) {
          setActiveRoomId(data.id);
        }
      } catch (err) {
        console.warn('Failed to check active room:', err);
        if (isMounted) {
          setRoomCheckError('Unable to verify the current match room. Check the connection before creating another room.');
        }
      } finally {
        if (isMounted) {
          setCheckingActiveRoom(false);
        }
      }
    }

    checkCurrentRoom();
    return () => {
      isMounted = false;
    };
  }, [checkAttempt]);

  if (checkingActiveRoom) {
    return <PixelLoader label="CHECKING MATCH STATE..." delayMs={0} />;
  }

  // If a non-finalized room already exists, redirect directly to its control console
  if (activeRoomId) {
    return <Navigate to={`/admin/room/${activeRoomId}`} replace />;
  }

  return (
    <div className="min-h-screen bg-nes-sky flex flex-col justify-between">
      {/* Admin Top Navigation */}
      <header className="bg-nes-navy text-white border-b-4 border-nes-navy px-4 py-3 flex items-center justify-between shadow-[0_4px_0px_#102040]">
        <div className="flex items-center gap-3">
          <span className="font-pixel text-sm text-nes-gold">STARTUPOLY</span>
          <span className="hidden sm:inline font-mono text-xs text-nes-gray border-l-2 border-white/20 pl-3">
            ADMIN CONSOLE
          </span>
        </div>

        <div className="flex items-center gap-3">
          <span className="hidden md:inline font-mono text-xs text-[#94A3B8]">
            {user?.email}
          </span>
          <Link to="/admin/history">
            <PixelButton variant="ghost" size="sm">
              HISTORY
            </PixelButton>
          </Link>
          <PixelButton variant="danger" size="sm" onClick={() => setLogoutConfirmOpen(true)}>
            LOGOUT
          </PixelButton>
        </div>
      </header>

      {/* Responsive width notice for small devices (< 1024px) */}
      <div className="lg:hidden bg-nes-gold text-nes-navy px-4 py-2 text-center border-b-4 border-nes-navy shadow-[0_2px_0px_#102040]">
        <p className="font-pixel text-[11px] leading-relaxed">
          💻 Use a laptop for the admin console. Full operations grid is optimized for screens ≥ 1024px.
        </p>
      </div>

      {/* Main Container: Create Room View */}
      <main className="flex-1 max-w-5xl w-full mx-auto p-4 sm:p-6 lg:p-8 flex flex-col gap-6">
        {roomCheckError ? (
          <ErrorBanner
            message={roomCheckError}
            onRetry={() => {
              setRoomCheckError(null);
              setCheckingActiveRoom(true);
              setCheckAttempt((attempt) => attempt + 1);
            }}
          />
        ) : (
          <CreateRoomView />
        )}
      </main>

      {/* Brick Ground Base */}
      <PixelBrickTile hasGrass={true} className="h-8" />

      {/* Logout confirm — requires explicit confirmation before calling logout() */}
      <Modal
        isOpen={logoutConfirmOpen}
        onClose={() => setLogoutConfirmOpen(false)}
        title="CONFIRM LOGOUT"
        maxWidth="sm"
        footer={
          <>
            <PixelButton variant="ghost" size="sm" onClick={() => setLogoutConfirmOpen(false)}>
              CANCEL
            </PixelButton>
            <PixelButton
              variant="danger"
              size="sm"
              onClick={async () => {
                setLogoutConfirmOpen(false);
                await logout();
              }}
            >
              LOG OUT
            </PixelButton>
          </>
        }
      >
        <p className="font-mono text-sm text-nes-navy">
          Are you sure you want to log out of the admin console?
        </p>
      </Modal>
    </div>
  );
};
