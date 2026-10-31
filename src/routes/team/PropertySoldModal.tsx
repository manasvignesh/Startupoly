import React, { useEffect, useState } from 'react';
import { PropertySoldEvent } from '../../data/broadcast';
import { PixelBusinessIcon, PixelCoin, PixelSparkle, PixelStar, PixelTrophy } from '../../ui/pixel';
import { RENT_TABLE } from '../../domain/economy';

export interface PropertySoldModalProps {
  event: PropertySoldEvent | null;
  onDismiss: () => void;
}

export const PropertySoldModal: React.FC<PropertySoldModalProps> = ({ event, onDismiss }) => {
  const [progress, setProgress] = useState(100);

  useEffect(() => {
    if (!event) return;

    setProgress(100);
    const duration = 6000;
    const interval = 50;
    const step = (interval / duration) * 100;

    const intervalTimer = setInterval(() => {
      setProgress((prev) => Math.max(0, prev - step));
    }, interval);

    const timeoutTimer = setTimeout(() => {
      onDismiss();
    }, duration);

    return () => {
      clearInterval(intervalTimer);
      clearTimeout(timeoutTimer);
    };
  }, [event, onDismiss]);

  if (!event) return null;

  const rentValues = RENT_TABLE[event.cost] || [
    Math.round(event.cost * 0.5),
    Math.round(event.cost * 0.75),
    event.cost,
  ];

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label="Property Purchased Announcement"
      className="fixed inset-0 z-50 flex items-center justify-center p-3 sm:p-4 bg-navy-950/85 backdrop-blur-md animate-in fade-in duration-300 select-none overflow-hidden"
      onClick={onDismiss}
    >
      {/* Dynamic Golden Radiant Sunburst Ray Disk */}
      <div
        aria-hidden="true"
        className="anim-deed-halo pointer-events-none absolute w-[480px] h-[480px] sm:w-[620px] sm:h-[620px] rounded-full opacity-35"
        style={{
          background:
            'radial-gradient(circle, rgba(255,215,0,0.55) 0%, rgba(245,158,11,0.25) 45%, transparent 70%)',
        }}
      />

      {/* Floating 3D Celebratory Sparkles & Coins */}
      <div className="absolute top-10 left-6 sm:left-20 anim-deed-particle pointer-events-none" style={{ animationDelay: '0s' }}>
        <PixelSparkle size={32} />
      </div>
      <div className="absolute top-16 right-8 sm:right-24 anim-deed-particle pointer-events-none" style={{ animationDelay: '0.4s' }}>
        <PixelCoin size={36} />
      </div>
      <div className="absolute bottom-16 left-8 sm:left-24 anim-deed-particle pointer-events-none" style={{ animationDelay: '0.8s' }}>
        <PixelStar size={34} />
      </div>
      <div className="absolute bottom-12 right-6 sm:right-20 anim-deed-particle pointer-events-none" style={{ animationDelay: '1.2s' }}>
        <PixelTrophy size={36} />
      </div>

      {/* 3D Unfolding Title Deed Card Entrance */}
      <div className="anim-deed-unfold w-full max-w-[340px] sm:max-w-[380px] z-10" onClick={(e) => e.stopPropagation()}>
        {/* Hover / Levitation Float Wrapper */}
        <div className="anim-deed-float relative w-full bg-brand-cream border-4 border-brand-navy ring-4 ring-brand-gold/80 shadow-[0_16px_48px_rgba(0,0,0,0.7),0_0_30px_rgba(255,204,0,0.4)] text-center flex flex-col items-center overflow-hidden p-3 sm:p-4 gap-2.5">
          {/* Continuous Prismatic Rainbow Holographic Foil Sweeping Shine */}
          <div
            aria-hidden="true"
            className="anim-deed-shine pointer-events-none absolute inset-0 z-30"
            style={{
              background:
                'linear-gradient(115deg, transparent 15%, rgba(255,255,255,0.4) 30%, rgba(255,215,0,0.85) 45%, rgba(0,255,255,0.7) 50%, rgba(255,105,180,0.7) 55%, rgba(255,255,255,0.85) 65%, transparent 85%)',
            }}
          />

          {/* Ornate Gold Corner Studs */}
          <span className="absolute top-1 left-1.5 text-brand-gold text-[10px] select-none pointer-events-none font-bold">✦</span>
          <span className="absolute top-1 right-1.5 text-brand-gold text-[10px] select-none pointer-events-none font-bold">✦</span>
          <span className="absolute bottom-1 left-1.5 text-brand-gold text-[10px] select-none pointer-events-none font-bold">✦</span>
          <span className="absolute bottom-1 right-1.5 text-brand-gold text-[10px] select-none pointer-events-none font-bold">✦</span>

          {/* Card Header Strip: Monopoly Title Deed Style */}
          <div
            className="w-full py-2 px-3 border-2 border-brand-navy shadow-pixel-sm flex flex-col items-center gap-0.5 text-white relative overflow-hidden"
            style={{ backgroundColor: event.teamColor || 'var(--color-navy-base)' }}
          >
            {/* Subtle inner gold accent line */}
            <div className="absolute inset-x-0 top-0 h-[2px] bg-brand-gold/60" />
            <div className="flex items-center gap-1.5">
              <span className="text-brand-gold text-[10px]">★</span>
              <span className="font-pixel text-[9px] uppercase tracking-widest text-brand-gold drop-shadow-[1px_1px_0px_rgba(0,0,0,0.8)]">
                STARTUPOLY TITLE DEED
              </span>
              <span className="text-brand-gold text-[10px]">★</span>
            </div>
            <h2 className="font-pixel text-base sm:text-lg font-black uppercase tracking-wider text-white drop-shadow-[2px_2px_0px_rgba(0,0,0,0.9)]">
              {event.businessName}
            </h2>
          </div>

          {/* Center Art Frame with Pixel Business Icon */}
          <div className="relative my-1 flex items-center justify-center w-24 h-24 sm:w-28 sm:h-28 bg-brand-white border-3 border-brand-navy shadow-pixel-sm rounded-sm">
            {/* Soft radial inner glow */}
            <div
              className="absolute inset-0 opacity-25 pointer-events-none"
              style={{
                background:
                  'radial-gradient(circle, var(--color-brand-gold) 0%, transparent 75%)',
              }}
            />

            <PixelBusinessIcon businessKey={event.businessKey} size={72} />

            {/* Red SOLD Rubber Stamp Slam Effect */}
            <div className="anim-deed-stamp absolute -bottom-2 -right-3 rotate-[-12deg] bg-brand-red text-white font-pixel text-xs sm:text-sm font-black px-2.5 py-1 border-2 border-brand-navy shadow-[2px_2px_0px_rgba(0,0,0,0.6)] tracking-widest uppercase z-20">
              SOLD!
            </div>
          </div>

          {/* Prominent Announcement Banner */}
          <div className="w-full bg-brand-navy text-brand-gold border-2 border-brand-gold py-2 px-2 shadow-pixel-sm flex flex-col items-center gap-0.5">
            <span className="font-pixel text-[11px] sm:text-xs font-black uppercase tracking-wide text-white drop-shadow-[1px_1px_0px_rgba(0,0,0,0.8)] flex items-center gap-1">
              🏆 {event.teamName.toUpperCase()} BOUGHT THIS! 🏆
            </span>
            <span className="font-mono text-[10px] text-brand-gold font-bold">
              Purchase Price: ₹{event.cost.toLocaleString('en-IN')}
            </span>
          </div>

          {/* Monopoly-Style Rent Schedule Table */}
          <div className="w-full bg-brand-white/90 border-2 border-brand-navy p-2 shadow-pixel-xs font-mono text-[11px]">
            <div className="flex items-center justify-between py-0.5 border-b border-neutral-200">
              <span className="text-neutral-600 font-medium">Base Rent</span>
              <span className="font-bold text-brand-navy">
                ₹{rentValues[0].toLocaleString('en-IN')}
              </span>
            </div>
            <div className="flex items-center justify-between py-0.5 border-b border-neutral-200">
              <span className="text-neutral-600 font-medium">With 1 Upgrade</span>
              <span className="font-bold text-brand-navy">
                ₹{rentValues[1].toLocaleString('en-IN')}
              </span>
            </div>
            <div className="flex items-center justify-between py-0.5">
              <span className="text-neutral-600 font-medium">With 2 Upgrades (Max)</span>
              <span className="font-bold text-brand-navy">
                ₹{rentValues[2].toLocaleString('en-IN')}
              </span>
            </div>
          </div>

          {/* Auto-Dismiss Countdown Bar */}
          <div className="w-full h-1.5 bg-neutral-200 border border-brand-navy overflow-hidden">
            <div
              className="h-full bg-brand-green transition-all duration-75 ease-linear"
              style={{ width: `${progress}%` }}
            />
          </div>

          {/* Dismiss Button */}
          <button
            type="button"
            onClick={onDismiss}
            className="w-full font-pixel text-[10px] uppercase py-1.5 bg-brand-navy text-brand-gold border-2 border-brand-navy shadow-pixel-sm hover:bg-brand-red hover:text-white transition-colors cursor-pointer active:translate-y-0.5"
          >
            [ TAP TO DISMISS ]
          </button>
        </div>
      </div>
    </div>
  );
};
