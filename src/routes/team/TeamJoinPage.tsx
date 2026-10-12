import React, { useState } from 'react';
import { Link, useNavigate, useLocation } from 'react-router-dom';
import {
  PlainsBackground,
  WoodenSignboard,
  PixelInputSlots,
  WoodenActionButton,
  RoamingCharacter,
  PixelCoin,
} from '../../ui/pixel';
import { ErrorBanner, useToast, Skeleton } from '../../ui';
import { rpcGetLobby, rpcJoinTeam } from '../../data/rpc';
import { ensureAnonymousSession } from '../../data/client';
import { isNetworkError } from '../../lib/errors';

interface LobbyTeam {
  slot: number;
  name: string;
  color: string;
  claimed: boolean;
}

export const TeamJoinPage: React.FC = () => {
  const [roomCode, setRoomCode] = useState('');
  const [lobbyTeams, setLobbyTeams] = useState<LobbyTeam[]>([]);
  const [selectedSlot, setSelectedSlot] = useState<number | null>(null);
  const [pin, setPin] = useState('');

  const [isLoadingLobby, setIsLoadingLobby] = useState(false);
  const [isJoining, setIsJoining] = useState(false);
  const [isSuccess, setIsSuccess] = useState(false);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  const navigate = useNavigate();
  const location = useLocation();
  const { errorToast, successToast } = useToast();

  // Check if redirected with notice (e.g., organizer released slot)
  const redirectNotice = (location.state as { notice?: string })?.notice;

  // Safe alphabet filter (no 0, 1, I, O)
  const handleRoomCodeChange = (raw: string) => {
    const cleaned = raw.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g, '').slice(0, 6);
    setRoomCode(cleaned);
    setErrorMessage(null);

    // Auto-fetch lobby when 6 valid characters entered
    if (cleaned.length === 6) {
      fetchLobby(cleaned);
    } else {
      setLobbyTeams([]);
      setSelectedSlot(null);
    }
  };

  const fetchLobby = async (code: string) => {
    try {
      setIsLoadingLobby(true);
      setErrorMessage(null);
      const data = await rpcGetLobby(code);
      setLobbyTeams(data.teams);
      if (data.teams.length > 0 && selectedSlot === null) {
        setSelectedSlot(data.teams[0].slot);
      }
    } catch (err) {
      const message = isNetworkError(err)
        ? 'Unable to reach the match server. Check your connection and try again.'
        : "Code, team or PIN didn't match";
      setErrorMessage(message);
      setLobbyTeams([]);
      setSelectedSlot(null);
    } finally {
      setIsLoadingLobby(false);
    }
  };

  const handleJoin = async (e: React.FormEvent) => {
    e.preventDefault();

    if (roomCode.length !== 6) {
      setErrorMessage("Code, team or PIN didn't match");
      return;
    }

    if (selectedSlot === null) {
      setErrorMessage("Please select your team.");
      return;
    }

    if (pin.length !== 4) {
      setErrorMessage("Team PIN must be exactly 4 digits.");
      return;
    }

    try {
      setIsJoining(true);
      setErrorMessage(null);

      // Ensure anonymous session exists so auth.uid() is populated in Postgres
      await ensureAnonymousSession();

      // Call join_team RPC
      await rpcJoinTeam(roomCode, selectedSlot, pin);

      // Trigger game-like celebration
      setIsSuccess(true);
      successToast("Connected to team!");

      setTimeout(() => {
        navigate('/team');
      }, 600);
    } catch (err: any) {
      let message = "Code, team or PIN didn't match";
      if (err.code === 'TOO_MANY_ATTEMPTS') {
        message = 'Too many tries — wait a minute';
      } else if (err.code === 'TEAM_ALREADY_CLAIMED') {
        message = 'This team is already connected. Ask the organiser to release it before rejoining.';
      } else if (isNetworkError(err)) {
        message = 'Unable to reach the match server. Check your connection and try again.';
      }
      setErrorMessage(message);
      errorToast(message);
    } finally {
      setIsJoining(false);
    }
  };

  return (
    <PlainsBackground>
      {/* Top Navbar / World Map Signpost & Checkpoint Badge */}
      <header className="p-3 sm:p-4 flex items-center justify-between z-20">
        <Link
          to="/"
          className="inline-flex items-center gap-2 font-pixel text-xs bg-[#102040] text-[#FFCC00] px-3 sm:px-4 py-2 border-2 border-[#102040] shadow-[3px_3px_0px_#102040] hover:bg-[#22B14C] hover:text-white transition-transform active:translate-x-0.5 active:translate-y-0.5"
        >
          <span className="text-sm">🗺️</span>
          <span>WORLD MAP</span>
        </Link>
        <span className="inline-flex items-center gap-1.5 font-pixel text-[10px] sm:text-xs text-[#102040] bg-[#FFCC00] px-3 sm:px-4 py-1.5 border-2 border-[#102040] shadow-[3px_3px_0px_#102040] font-black tracking-wider">
          <span>🚩</span>
          <span>CHECKPOINT</span>
        </span>
      </header>

      {/* Main Single-Column Game World Scene */}
      <main className="flex-1 flex flex-col items-center justify-center p-3 sm:p-4 z-10 relative">
        {/* Redirect Notice Parchment */}
        {redirectNotice && (
          <div className="w-full max-w-md mb-3 bg-[#FFFBEB] border-3 border-[#102040] p-3 shadow-[4px_4px_0px_#102040]">
            <p className="font-mono text-xs text-[#92400E] font-bold text-center">
              ⚠ {redirectNotice}
            </p>
          </div>
        )}

        {/* Central Wooden Checkpoint Signboard */}
        <WoodenSignboard
          title="JOIN THE MATCH"
          subtitle="ENTER YOUR ROOM CODE"
          state={errorMessage ? 'shake' : isSuccess ? 'bounce' : 'idle'}
          maxWidth="max-w-md"
        >
          {/* Game Celebration State */}
          {isSuccess ? (
            <div className="py-8 flex flex-col items-center justify-center anim-match-found">
              <div className="flex gap-2 mb-3">
                <PixelCoin size={28} className="anim-coin-idle" />
                <PixelCoin size={32} className="anim-pop-coins" />
                <PixelCoin size={28} className="anim-coin-idle" />
              </div>
              <div className="bg-[#22B14C] text-white border-3 border-[#102040] px-4 py-2 shadow-[4px_4px_0px_#102040] text-center">
                <p className="font-pixel text-sm sm:text-base text-[#FFCC00]">
                  MATCH FOUND!
                </p>
                <p className="font-mono text-xs text-white mt-1">
                  Entering world...
                </p>
              </div>
            </div>
          ) : (
            <>
              {errorMessage && (
                <div className="mb-2">
                  <ErrorBanner message={errorMessage} />
                </div>
              )}

              <form onSubmit={handleJoin} className="flex flex-col gap-4">
                {/* Step 1: 6-Character Physical Block Slots */}
                <div>
                  <PixelInputSlots
                    value={roomCode}
                    onChange={handleRoomCodeChange}
                    disabled={isJoining}
                    hasError={Boolean(errorMessage)}
                  />

                  {isLoadingLobby && (
                    <div className="mt-2">
                      <Skeleton height={32} />
                    </div>
                  )}
                </div>

                {/* Step 2: Team Tiles (Embedded Wooden Badges) */}
                {lobbyTeams.length > 0 && (
                  <div className="flex flex-col gap-1.5 pt-1 border-t-2 border-[#102040]/20">
                    <label className="font-pixel text-[10px] sm:text-[11px] uppercase tracking-wider text-[#FFF5D6] drop-shadow-[1px_1px_0px_#102040]">
                      CHOOSE YOUR TEAM
                    </label>
                    <div className="grid grid-cols-2 gap-2">
                      {lobbyTeams.map((t) => {
                        const isSelected = selectedSlot === t.slot;

                        return (
                          <button
                            type="button"
                            key={t.slot}
                            onClick={() => setSelectedSlot(t.slot)}
                            className={`
                              min-h-[48px] p-2 text-left border-3 border-[#102040] cursor-pointer flex items-center justify-between gap-2
                              transition-transform duration-75 select-none
                              ${
                                isSelected
                                  ? 'bg-[#FFCC00] shadow-[3px_3px_0px_#102040] scale-[1.02]'
                                  : 'bg-[#FFFBEB] hover:bg-white shadow-[2px_2px_0px_#102040]'
                              }
                            `}
                          >
                            <div className="flex items-center gap-2 truncate">
                              <span
                                className="w-4 h-4 border-2 border-[#102040] flex-shrink-0"
                                style={{ backgroundColor: t.color }}
                              />
                              <div className="truncate">
                                <span className="font-pixel text-[10px] text-[#102040] block truncate font-bold">
                                  {t.name}
                                </span>
                                <span className="font-mono text-[9px] text-[#475569]">
                                  Slot #{t.slot}
                                </span>
                              </div>
                            </div>

                            {isSelected && (
                              <span className="font-pixel text-xs text-[#102040]">
                                ✓
                              </span>
                            )}
                          </button>
                        );
                      })}
                    </div>
                  </div>
                )}

                {/* Step 3: 4-Digit Secret PIN */}
                {lobbyTeams.length > 0 && (
                  <div className="pt-1 border-t-2 border-[#102040]/20">
                    <div className="flex items-center justify-between mb-1">
                      <label
                        htmlFor="secret-pin"
                        className="font-pixel text-[10px] sm:text-[11px] uppercase tracking-wider text-[#FFF5D6] drop-shadow-[1px_1px_0px_#102040]"
                      >
                        SECRET TEAM PIN
                      </label>
                      <span className="font-mono text-[10px] text-[#FFF5D6]/80">
                        4 Digits
                      </span>
                    </div>

                    <div className="relative">
                      <input
                        id="secret-pin"
                        aria-label="3. 4-Digit Secret PIN"
                        type="password"
                        inputMode="numeric"
                        pattern="[0-9]*"
                        maxLength={4}
                        required
                        placeholder="••••"
                        value={pin}
                        onChange={(e) => setPin(e.target.value.replace(/\D/g, '').slice(0, 4))}
                        disabled={isJoining}
                        className="w-full bg-[#FFFBEB] border-3 sm:border-4 border-[#102040] px-4 py-2.5 font-pixel text-center text-lg sm:text-xl text-[#102040] shadow-[inset_2px_2px_0px_rgba(0,0,0,0.2)] focus:outline-none focus:ring-2 focus:ring-[#FFCC00]"
                      />
                    </div>
                    <p className="font-mono text-[10px] text-[#FFFBEB] mt-1 text-center font-medium drop-shadow-[1px_1px_0px_#102040]">
                      Provided by your game organizer
                    </p>
                  </div>
                )}

                {/* Golden Wooden Plank Action Button */}
                <div className="pt-1">
                  <WoodenActionButton
                    type="submit"
                    variant="gold"
                    aria-label={lobbyTeams.length > 0 ? 'ENTER WORLD' : 'JOIN MATCH'}
                    disabled={
                      roomCode.length !== 6 ||
                      (lobbyTeams.length > 0 && (selectedSlot === null || pin.length !== 4)) ||
                      isJoining
                    }
                    isLoading={isJoining}
                  >
                    {lobbyTeams.length > 0 ? 'ENTER WORLD →' : 'JOIN MATCH →'}
                  </WoodenActionButton>
                </div>
              </form>
            </>
          )}
        </WoodenSignboard>

        {/* Pixel Mascot Poly Patrols The Ground (with "Let's play!" speech bubble) */}
        <div className="absolute bottom-0 right-4 sm:right-16 md:right-28 pointer-events-none">
          <RoamingCharacter
            size={52}
            bubbleText={isSuccess ? 'Lets Go!!' : "Let's play!"}
            isCheering={isSuccess}
          />
        </div>
      </main>
    </PlainsBackground>
  );
};
