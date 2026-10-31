import React, { useMemo, useState } from 'react';
import { BOARD_SPACES, BoardSpace, getBoardSpace, TOTAL_BOARD_SPACES } from '../../../domain/board';
import { AdminRoomSnapshot } from '../../../data/rpc';
import { OFFICIAL_BUSINESSES, RENT_TABLE } from '../../../domain/economy';
import { PixelBusinessIcon, PixelCloudFluffy, PixelCoin, PixelHill, PixelPipe, PixelQuestionBlock, PixelStar, StartupolyLogo } from '../../../ui/pixel';
import './LiveBoardPanel.css';

type Team = AdminRoomSnapshot['teams'][number];

const spaceColors: Record<BoardSpace['type'], string> = {
  START: 'var(--color-board-start)', BUSINESS: 'var(--color-board-business)',
  BONUS: 'var(--color-board-bonus)', CRISIS: 'var(--color-board-crisis)',
  WILDCARD: 'var(--color-board-wildcard)', ACTION_B: 'var(--color-board-action-b)',
  ACTION_C: 'var(--color-board-action-c)', ACTION_D: 'var(--color-board-action-d)',
};

function BoardIcon({ space }: { space: BoardSpace }) {
  if (space.type === 'BUSINESS') return <PixelBusinessIcon businessKey={space.businessKey ?? ''} size={32} />;
  if (space.type === 'BONUS') return <PixelStar size={32} />;
  if (space.type === 'WILDCARD') return <PixelQuestionBlock size={30} />;
  const symbols: Record<string, string> = { START: '⚑', CRISIS: '!', ACTION_B: '♬', ACTION_C: '⚡', ACTION_D: '⇄' };
  return <span className="live-board__symbol">{symbols[space.type]}</span>;
}

function positionInGrid(index: number) {
  if (index <= 6) return { row: 6, column: index };
  if (index <= 12) return { row: 12 - index, column: 6 };
  if (index <= 18) return { row: 0, column: 18 - index };
  return { row: index - 18, column: 0 };
}

export interface LiveBoardPanelProps {
  teams: AdminRoomSnapshot['teams'];
  events: AdminRoomSnapshot['events'];
  selectedTeamId: string;
  disabled?: boolean;
  onSelectTeam: (teamId: string) => void;
  onMoveTeam: (team: Team, steps: number) => Promise<void>;
  onResolveSpace: (space: BoardSpace) => void;
}

/** Organizer-only companion to the physical board: persistent token positions and turn context. */
export const LiveBoardPanel: React.FC<LiveBoardPanelProps> = ({
  teams,
  events,
  selectedTeamId,
  disabled = false,
  onSelectTeam,
  onMoveTeam,
  onResolveSpace,
}) => {
  const [steps, setSteps] = useState(1);
  const [isMoving, setIsMoving] = useState(false);
  const selectedTeam = teams.find((team) => team.id === selectedTeamId) ?? teams[0];
  const selectedSpace = getBoardSpace(selectedTeam?.board_position ?? 0);

  // Map each space index to teams currently positioned on it
  const teamsAtSpace = useMemo(
    () =>
      BOARD_SPACES.reduce<Record<number, Team[]>>((bySpace, space) => {
        bySpace[space.index] = teams.filter((team) => (team.board_position ?? 0) === space.index);
        return bySpace;
      }, {}),
    [teams]
  );

  // Map each businessKey to its owning team and business details
  const businessOwnershipMap = useMemo(() => {
    const map = new Map<string, { team: Team; level: number; cost: number; name: string }>();
    for (const team of teams) {
      for (const biz of team.businesses || []) {
        map.set(biz.business_key, {
          team,
          level: biz.level,
          cost: biz.cost,
          name: biz.name,
        });
      }
    }
    return map;
  }, [teams]);

  const recentMoves = events.filter((event) => event.type === 'TEAM_MOVED').slice(0, 4);

  // Target preview for dice roll
  const currentPos = selectedTeam?.board_position ?? 0;
  const targetPos = (currentPos + steps) % TOTAL_BOARD_SPACES;
  const targetSpace = getBoardSpace(targetPos);
  const willPassOrLandStart = (currentPos + steps) >= TOTAL_BOARD_SPACES;

  // Selected space ownership context
  const selectedBizKey = selectedSpace.type === 'BUSINESS' ? selectedSpace.businessKey : null;
  const selectedOwnerInfo = selectedBizKey ? businessOwnershipMap.get(selectedBizKey) : null;
  const isOpponentOwned = Boolean(selectedOwnerInfo && selectedTeam && selectedOwnerInfo.team.id !== selectedTeam.id);
  const isSelfOwned = Boolean(selectedOwnerInfo && selectedTeam && selectedOwnerInfo.team.id === selectedTeam.id);
  const catalogBiz = selectedBizKey ? OFFICIAL_BUSINESSES.find((b) => b.key === selectedBizKey) : null;

  // Compute exact rent for selected space if owned
  const selectedRentValues = selectedOwnerInfo
    ? RENT_TABLE[selectedOwnerInfo.cost] || [
        Math.round(selectedOwnerInfo.cost * 0.5),
        Math.round(selectedOwnerInfo.cost * 0.75),
        selectedOwnerInfo.cost,
      ]
    : [0, 0, 0];
  const selectedRentAmount = selectedOwnerInfo ? selectedRentValues[selectedOwnerInfo.level] ?? selectedRentValues[0] : 0;

  const handleMove = async () => {
    if (!selectedTeam) return;
    try {
      setIsMoving(true);
      await onMoveTeam(selectedTeam, steps);
    } catch {
      // The console owns mutation feedback. Avoid an unhandled event-promise
      // rejection after it has already presented the organiser with the result.
    } finally {
      setIsMoving(false);
    }
  };

  return (
    <section aria-label="Live board tracker" className="border-4 border-brand-navy bg-brand-white shadow-pixel p-3 sm:p-4">
      <div className="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between sm:gap-3 mb-3">
        <div>
          <h2 className="font-pixel text-sm sm:text-base uppercase text-brand-navy">Live Board Tracker</h2>
          <p className="font-mono text-[11px] text-neutral-600">Admin only · mirrors the physical board · positions persist after refresh</p>
        </div>
        <span className="self-start sm:self-auto font-pixel text-[9px] uppercase bg-brand-navy text-brand-gold px-2 py-1 border border-brand-navy">
          {selectedTeam ? `TURN: ${selectedTeam.name}` : 'SELECT A TEAM'}
        </span>
      </div>

      <div className="grid items-start justify-center gap-5 xl:grid-cols-[minmax(560px,760px)_minmax(320px,360px)] xl:gap-7">
        <div className="live-board relative aspect-square w-full min-w-0 mx-auto overflow-hidden">
          <div className="live-board__scene" aria-hidden="true">
            <PixelCloudFluffy size={70} className="live-board__cloud live-board__cloud--one" />
            <PixelCloudFluffy size={52} className="live-board__cloud live-board__cloud--two" />
            <PixelCloudFluffy size={42} className="live-board__cloud live-board__cloud--three" />
            <PixelHill size={140} className="live-board__hill live-board__hill--one" />
            <PixelHill size={110} className="live-board__hill live-board__hill--two" />
            <PixelPipe size={48} className="live-board__pipe" />
            <PixelCoin size={25} className="live-board__coin" />
            <PixelStar size={20} className="live-board__star" />
            <div className="live-board__logo"><StartupolyLogo size="responsive" glow={false} /></div>
            <span className="live-board__scene-caption">THE GAME IS ON</span>
            <div className="live-board__ground" />
          </div>

          <div className="live-board__grid relative z-10 grid h-full w-full grid-cols-7 grid-rows-7">
            {BOARD_SPACES.map((space) => {
              const position = positionInGrid(space.index);
              const occupants = teamsAtSpace[space.index] ?? [];
              const isSelectedSpace = selectedSpace.index === space.index;
              const ownerInfo = space.businessKey ? businessOwnershipMap.get(space.businessKey) : null;
              const isOwned = Boolean(ownerInfo);

              const cellClass = `live-board__tile relative min-w-0 text-left ${
                isSelectedSpace ? 'live-board__tile--selected' : ''
              } ${isOwned ? 'live-board__tile--owned' : ''}`;

              const cellStyle: React.CSSProperties = {
                gridRowStart: position.row + 1,
                gridColumnStart: position.column + 1,
                backgroundColor: spaceColors[space.type],
                ...(isOwned && ownerInfo ? { borderColor: ownerInfo.team.color } : {}),
              };

              const tooltip = isOwned && ownerInfo
                ? `#${space.index} ${space.name}: [OWNED by ${ownerInfo.team.name} (T${ownerInfo.team.slot}) · Level ${ownerInfo.level}/2]`
                : `#${space.index} ${space.name}: ${space.description}`;

              const cellContent = (
                <>
                  {/* Ownership Marker Badge */}
                  {isOwned && ownerInfo && (
                    <span
                      className="live-board__owner-badge"
                      style={{ backgroundColor: ownerInfo.team.color }}
                      title={`Owned by ${ownerInfo.team.name} (T${ownerInfo.team.slot}) · Level ${ownerInfo.level}`}
                    >
                      ★ T{ownerInfo.team.slot}
                      {ownerInfo.level > 0 && <span className="opacity-90">·L{ownerInfo.level}</span>}
                    </span>
                  )}

                  <span className="live-board__number">{String(space.index).padStart(2, '0')}</span>
                  <span aria-hidden="true" className="live-board__icon"><BoardIcon space={space} /></span>
                  <span className="live-board__label">{space.name}</span>
                  {occupants.length > 0 && (
                    <span className="live-board__tokens">
                      {occupants.map((team) => (
                        <span
                          key={team.id}
                          title={team.name}
                          className={`live-board__token ${team.id === selectedTeamId ? 'live-board__token--selected' : ''}`}
                          style={{ backgroundColor: team.color }}
                        >{team.slot}</span>
                      ))}
                    </span>
                  )}
                </>
              );

              return occupants.length > 0 ? (
                <button
                  key={space.index}
                  type="button"
                  title={tooltip}
                  aria-label={`Select token on ${space.name}`}
                  onClick={() => onSelectTeam(occupants[0].id)}
                  className={`${cellClass} cursor-pointer`}
                  style={cellStyle}
                >
                  {cellContent}
                </button>
              ) : (
                <div key={space.index} title={tooltip} className={cellClass} style={cellStyle}>
                  {cellContent}
                </div>
              );
            })}
          </div>
        </div>

        <aside className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-1">
          {/* 1. Selected Team Selector */}
          <div className="border-2 border-brand-navy bg-brand-cream p-3">
            <span className="font-pixel text-[10px] uppercase text-neutral-600">Selected team</span>
            <select
              aria-label="Select team for board move"
              value={selectedTeam?.id ?? ''}
              onChange={(event) => onSelectTeam(event.target.value)}
              className="mt-1 w-full border-2 border-brand-navy bg-white px-2 py-2 font-pixel text-xs text-brand-navy"
            >
              {teams.map((team) => <option key={team.id} value={team.id}>#{team.slot} · {team.name}</option>)}
            </select>
            {selectedTeam && (
              <div className="mt-3 flex items-center gap-2">
                <span className="w-4 h-4 rounded-full border-2 border-brand-navy" style={{ backgroundColor: selectedTeam.color }} />
                <span className="font-pixel text-[11px] text-brand-navy truncate">ON #{selectedSpace.index}: {selectedSpace.name}</span>
              </div>
            )}
          </div>

          {/* 2. Dice Roll & Movement Controller */}
          <div className="border-2 border-brand-navy bg-brand-navy p-3 text-white">
            <div className="flex items-center justify-between">
              <label htmlFor="board-roll" className="font-pixel text-[10px] uppercase text-brand-gold block">Dice roll</label>
              {willPassOrLandStart && (
                <span className="font-pixel text-[9px] text-brand-gold bg-brand-gold/20 border border-brand-gold/60 px-1.5 py-0.5">
                  +₹200 START REWARD!
                </span>
              )}
            </div>

            <div className="mt-2 flex gap-2">
              <select
                id="board-roll"
                value={steps}
                onChange={(event) => setSteps(Number(event.target.value))}
                disabled={disabled || isMoving}
                className="w-16 bg-white border-2 border-brand-gold text-brand-navy font-pixel text-sm px-2 py-2"
              >
                {[1, 2, 3, 4, 5, 6].map((roll) => <option key={roll} value={roll}>{roll}</option>)}
              </select>
              <button
                type="button"
                onClick={handleMove}
                disabled={disabled || isMoving || !selectedTeam || selectedTeam.is_bankrupt}
                className="flex-1 font-pixel text-xs uppercase bg-brand-gold text-brand-navy border-2 border-brand-gold px-3 py-2 shadow-pixel-sm hover:bg-brand-white disabled:opacity-50 disabled:cursor-not-allowed font-bold"
              >
                {isMoving ? 'MOVING…' : willPassOrLandStart ? 'MOVE (+₹200 REWARD)' : 'MOVE TOKEN'}
              </button>
            </div>

            <div className="mt-2 text-[10px] font-mono text-neutral-300">
              Target: <strong className="text-brand-gold">#{targetSpace.index} {targetSpace.name}</strong>
            </div>
          </div>

          {/* 3. Landing Space Details & Direct Rent/Purchase Actions */}
          <div className="border-2 border-brand-navy bg-white p-3">
            <span className="font-pixel text-[10px] uppercase text-neutral-600">Landing space</span>
            <h3 className="font-pixel text-sm text-brand-navy mt-1">#{selectedSpace.index} · {selectedSpace.name}</h3>
            <p className="font-mono text-[11px] leading-snug text-neutral-700 mt-1">{selectedSpace.description}</p>

            {/* Case A: Property Owned by Opponent Team (Rent Due!) */}
            {isOpponentOwned && selectedOwnerInfo && (
              <div className="mt-2.5 p-2 bg-brand-red/10 border-2 border-brand-red flex flex-col gap-1">
                <div className="flex items-center gap-1.5 font-pixel text-[11px] font-black uppercase text-brand-red">
                  <span>⚠️</span> RENT DUE TO {selectedOwnerInfo.team.name.toUpperCase()}!
                </div>
                <div className="font-mono text-xs font-black text-brand-navy">
                  Must pay ₹{selectedRentAmount.toLocaleString('en-IN')} to {selectedOwnerInfo.team.name}
                </div>
                <div className="font-mono text-[10px] text-neutral-600">
                  {selectedSpace.name} · Level {selectedOwnerInfo.level}/2 ({selectedOwnerInfo.level === 0 ? 'Base' : `Upgraded L${selectedOwnerInfo.level}`})
                </div>
              </div>
            )}

            {/* Case B: Property Owned by Current Team */}
            {isSelfOwned && selectedOwnerInfo && (
              <div className="mt-2.5 p-2 bg-brand-gold/20 border-2 border-brand-gold flex flex-col gap-0.5">
                <div className="font-pixel text-[10px] font-bold uppercase text-brand-navy flex items-center gap-1">
                  <span>🏠</span> OWNED BY {selectedTeam.name.toUpperCase()}
                </div>
                <div className="font-mono text-[11px] text-neutral-700">
                  Current Level: {selectedOwnerInfo.level}/2 · Opponents pay ₹{selectedRentAmount.toLocaleString('en-IN')} rent
                </div>
              </div>
            )}

            {/* Case C: Unowned Business */}
            {!selectedOwnerInfo && selectedBizKey && catalogBiz && (
              <div className="mt-2.5 p-2 bg-brand-green/10 border-2 border-brand-green flex flex-col gap-0.5">
                <div className="font-pixel text-[10px] font-bold uppercase text-brand-green flex items-center gap-1">
                  <span>🟢</span> UNOWNED PROPERTY
                </div>
                <div className="font-mono text-[11px] text-neutral-700">
                  Available for purchase: ₹{catalogBiz.cost.toLocaleString('en-IN')}
                </div>
              </div>
            )}

            {/* Space Action Button */}
            <button
              type="button"
              aria-label="RESOLVE THIS SPACE"
              onClick={() => onResolveSpace(selectedSpace)}
              disabled={Boolean(disabled || !selectedTeam || selectedTeam.is_bankrupt || (isSelfOwned && selectedOwnerInfo ? selectedOwnerInfo.level >= 2 : false))}
              className={`mt-3 w-full font-pixel text-[10px] uppercase border-2 border-brand-navy px-2 py-2 shadow-pixel-sm cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed font-bold ${
                isOpponentOwned
                  ? 'bg-brand-red text-white hover:bg-interactive-red-hover'
                  : isSelfOwned
                  ? 'bg-brand-gold text-brand-navy hover:bg-brand-white'
                  : selectedBizKey
                  ? 'bg-brand-green text-white hover:bg-interactive-green-hover'
                  : 'bg-brand-navy text-brand-gold hover:bg-neutral-800'
              }`}
            >
              {isOpponentOwned && selectedOwnerInfo
                ? `⚡ PAY RENT (₹${selectedRentAmount.toLocaleString('en-IN')} TO ${selectedOwnerInfo.team.name}) →`
                : isSelfOwned && selectedOwnerInfo
                ? selectedOwnerInfo.level >= 2
                  ? '★ MAX LEVEL REACHED (2/2)'
                  : `⭐ UPGRADE PROPERTY (L${selectedOwnerInfo.level} → L${selectedOwnerInfo.level + 1}) →`
                : selectedBizKey && catalogBiz
                ? `🛒 BUY ${selectedSpace.name.toUpperCase()} (₹${catalogBiz.cost}) →`
                : 'RESOLVE THIS SPACE →'}
            </button>
          </div>

          {/* 4. Recent Movement Audit Trail */}
          <div className="border-2 border-brand-navy bg-brand-cream p-3">
            <span className="font-pixel text-[10px] uppercase text-neutral-600">Recent movement</span>
            <ol className="mt-2 flex flex-col gap-1.5">
              {recentMoves.length === 0 ? (
                <li className="font-mono text-[11px] text-neutral-500">No tokens moved yet.</li>
              ) : recentMoves.map((event) => {
                const team = teams.find((entry) => entry.id === event.team_id);
                const destination = getBoardSpace(event.new?.board_position ?? 0);
                return (
                  <li key={event.id} className="font-mono text-[11px] text-brand-navy flex gap-1.5">
                    <span className="mt-0.5 w-2.5 h-2.5 rounded-full border border-brand-navy shrink-0" style={{ backgroundColor: team?.color ?? 'var(--color-neutral-400)' }} />
                    <span><strong>{team?.name ?? 'Team'}</strong> → #{destination.index} {destination.name}</span>
                  </li>
                );
              })}
            </ol>
          </div>
        </aside>
      </div>
    </section>
  );
};
