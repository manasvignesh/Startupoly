import React, { useState, useEffect } from 'react';
import {
  ArcadeLink,
} from '../../ui';
import {
  PixelCoin,
  PixelPhoneIcon,
  PixelTerminalIcon,
  PixelGrassTuft,
  PixelFlower,
  StartupolyLogo,
} from '../../ui/pixel';
import { usePageVisibility } from '../../lib/usePageVisibility';
import { useFirstVisit } from '../../lib/useFirstVisit';
import { PixelWorld } from './PixelWorld';
import { LiveIndicator } from './LiveIndicator';
import { FloatingPlatforms } from './FloatingPlatforms';
import { DistantHillsAndCastle } from './DistantHillsAndCastle';
import { SkyLayer } from './SkyLayer';
import { TapCoinBurst } from './TapCoinBurst';
import { GameIntroOverlay } from './intro/GameIntroOverlay';
import { RulesSection } from './RulesSection';

export const LandingPage: React.FC = () => {
  const { isFirstVisit, markSeen } = useFirstVisit();
  const [showIntro, setShowIntro] = useState<boolean>(true);
  const [activeCta, setActiveCta] = useState<'join' | 'admin' | null>(null);

  // Check prefers-reduced-motion
  const isReducedMotion =
    typeof window !== 'undefined' &&
    window.matchMedia?.('(prefers-reduced-motion: reduce)').matches;

  // Synchronize document pause state with tab visibility
  usePageVisibility();

  // Safety fallback to mark entrance animation seen
  useEffect(() => {
    if (isFirstVisit) {
      const timer = setTimeout(() => {
        markSeen();
      }, 1200);
      return () => clearTimeout(timer);
    }
  }, [isFirstVisit, markSeen]);

  const handleEntranceEnd = () => {
    if (isFirstVisit) {
      markSeen();
    }
  };

  return (
    <div
      data-cta={activeCta || undefined}
      id="top" className="min-h-screen nes-sky-gradient flex flex-col justify-between relative overflow-x-hidden selection:bg-[#FFCC00] selection:text-[#102040] anim-scene-transition"
    >
      {/* ======================================================================= */}
      {/* RETRO GAME OPENING INTRO CINEMATIC (Overlay)                           */}
      {/* ======================================================================= */}
      {showIntro && (
        <GameIntroOverlay onComplete={() => setShowIntro(false)} />
      )}

      <a
        href="#rules"
        className="absolute top-3 right-3 sm:top-5 sm:right-5 z-30 font-pixel text-[9px] sm:text-[10px] text-[#102040] bg-[#FFCC00] border-2 border-[#102040] px-2.5 py-2 shadow-[3px_3px_0_#102040] hover:bg-white transition-colors"
      >
        RULES ↓
      </a>

      {/* ======================================================================= */}
      {/* LAYER 0: Upper Sky Moving Clouds Atmosphere                             */}
      {/* ======================================================================= */}
      <SkyLayer />

      {/* ======================================================================= */}
      {/* LAYER 1: Distant Hills & Castle Silhouette Layer                         */}
      {/* ======================================================================= */}
      <DistantHillsAndCastle />

      {/* ======================================================================= */}
      {/* LAYER 2: Upper Floating Platforms (Question block, coins, critter)       */}
      {/* ======================================================================= */}
      <FloatingPlatforms />

      {/* ======================================================================= */}
      {/* LAYER 3: Main Title Screen UI (Logo, Status, Headline, Signboards)       */}
      {/* ======================================================================= */}
      <div className="flex-1 flex flex-col justify-center pt-[max(1rem,env(safe-area-inset-top))] sm:pt-2 md:pt-4 lg:pt-5 pb-1 sm:pb-2 relative z-10">
        {/* NES Sky Header */}
        <header className="relative pb-2 sm:pb-3 md:pb-4 px-4 text-center z-10">
          {/* Level 1: Wordmark Logo */}
          <div className={`flex flex-col items-center select-none text-center mb-1.5 sm:mb-2 ${isFirstVisit ? 'anim-entrance-logo' : ''}`}>
            <div className="relative inline-flex items-center gap-2 sm:gap-3">
              <PixelCoin
                size={22}
                className={`anim-coin-idle shrink-0 ${isFirstVisit ? 'anim-boot-coin-settle' : ''}`}
                ariaHidden={true}
              />
              <h1 className="relative inline-flex items-center justify-center">
                <StartupolyLogo size="responsive" />
              </h1>
              <PixelCoin
                size={22}
                className={`anim-coin-idle shrink-0 ${isFirstVisit ? 'anim-boot-coin-settle' : ''}`}
                ariaHidden={true}
              />
            </div>

            {/* Level 2: Subtitle Badge */}
            <div className="mt-1 sm:mt-1.5 inline-flex items-center gap-1 sm:gap-2 px-2.5 py-0.5 bg-[#102040] border-2 border-[#FFCC00] rounded-sm shadow-[2px_2px_0px_#B84418]">
              <span className="font-pixel text-[8px] sm:text-[9px] md:text-[10px] text-[#FFFBEB] tracking-widest font-bold">
                ★{' '}
                <span className={isFirstVisit ? 'anim-entrance-word-1' : ''}>DREAM</span>{' '}
                ·{' '}
                <span className={isFirstVisit ? 'anim-entrance-word-2' : ''}>BUILD</span>{' '}
                ·{' '}
                <span className={isFirstVisit ? 'anim-entrance-word-3' : ''}>GROW</span>{' '}
                ★
              </span>
            </div>

            {/* Live Indicator (Compact Game HUD status with boot sequence entrance) */}
            <div className="mt-1.5 sm:mt-2">
              <LiveIndicator isFirstVisit={isFirstVisit} />
            </div>
          </div>

          {/* Level 3: Hero Headline */}
          <div className={`mt-1.5 sm:mt-2 text-center max-w-lg mx-auto px-2 ${isFirstVisit ? 'anim-entrance-tagline' : ''}`}>
            <p className="font-pixel text-[11px] sm:text-xs md:text-sm text-[#FFFBEB] uppercase tracking-wider drop-shadow-[2px_2px_0px_#102040] leading-snug">
              THE BOARD IS PHYSICAL.
              <br className="sm:hidden" /> THE SCORE IS LIVE.
            </p>
          </div>
        </header>

        {/* Main Portals Grid (Level 4 Primary Checkpoints) */}
        <main className="relative max-w-3xl w-full mx-auto px-4 py-0.5 flex flex-col justify-center z-10">
          <div className="grid grid-cols-1 sm:grid-cols-[1.15fr_0.85fr] gap-4 sm:gap-5 md:gap-6 items-end justify-items-center">
            {/* ================================================================= */}
            {/* PRIMARY HERO CTA: TEAM PHONE (Wooden Checkpoint Signboard)       */}
            {/* ================================================================= */}
            <div className={`relative flex flex-col items-center w-full max-w-[360px] ${isFirstVisit ? 'anim-card-arrival-phone' : ''}`}>
              {/* Phase 4: One-time section entrance coin accent on primary card arrival */}
              {isFirstVisit && !isReducedMotion && (
                <div
                  data-testid="section-entrance-coin"
                  className="absolute -top-3.5 right-3 pointer-events-none z-30 anim-section-coin-accent"
                  aria-hidden="true"
                >
                  <PixelCoin size={16} />
                </div>
              )}
              <div
                onPointerEnter={() => setActiveCta('join')}
                onPointerLeave={() => setActiveCta(null)}
                className="group relative w-full bg-[#D78B30] border-[4px] border-[#181512] shadow-[6px_6px_0px_#102040] hover:shadow-[8px_8px_0px_#102040] hover:-translate-y-1 transition-all duration-100 ease-out p-3 sm:p-3.5 flex flex-col justify-between items-center text-center rounded-sm select-none"
              >
                {/* Left edge wood grain shadow */}
                <div className="absolute top-0 bottom-0 left-0 w-2.5 bg-[#B86B1E] border-r-2 border-[#8A4810] pointer-events-none" />
                {/* Right edge wood grain shadow */}
                <div className="absolute top-0 bottom-0 right-0 w-2.5 bg-[#8A4810] border-l-2 border-[#5C2E0A] pointer-events-none" />
                {/* Bottom wood shadow */}
                <div className="absolute bottom-0 left-0 right-0 h-2.5 bg-[#8A4810] border-t-2 border-[#5C2E0A] pointer-events-none" />
                {/* Top wood highlight */}
                <div className="absolute top-0 left-0 right-0 h-2 bg-[#F3B05A] pointer-events-none" />

                {/* Top-Left Green Ivy / Leaves Cluster */}
                <div className="absolute -top-3.5 -left-3.5 pointer-events-none z-20 flex flex-col">
                  <div className="flex">
                    <div className="w-3.5 h-3.5 bg-[#22C55E] border-2 border-[#181512] rounded-sm -rotate-12" />
                    <div className="w-3 h-3 bg-[#16A34A] border-2 border-[#181512] rounded-sm -ml-1.5 mt-1" />
                  </div>
                  <div className="flex -mt-1 ml-1">
                    <div className="w-3.5 h-3.5 bg-[#15803D] border-2 border-[#181512] rounded-sm" />
                    <div className="w-2.5 h-2.5 bg-[#22C55E] border border-[#181512] rounded-sm -ml-1" />
                  </div>
                </div>

                {/* Inner Cream/Parchment Face */}
                <div className="relative w-full bg-[#FFF5D6] border-[3px] border-[#9E5D1D] shadow-inner pt-3 pb-3 px-3 sm:px-4 flex flex-col items-center justify-between gap-3 rounded-none z-10">
                  {/* 4 Corner Silver Rivets with Screws */}
                  <div className="absolute top-1.5 left-1.5 w-2.5 h-2.5 rounded-full bg-[#CBD5E1] border border-[#181512] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1.5 h-0.5 bg-[#181512]" />
                  </div>
                  <div className="absolute top-1.5 right-1.5 w-2.5 h-2.5 rounded-full bg-[#CBD5E1] border border-[#181512] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1.5 h-0.5 bg-[#181512]" />
                  </div>
                  <div className="absolute bottom-1.5 left-1.5 w-2.5 h-2.5 rounded-full bg-[#CBD5E1] border border-[#181512] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1.5 h-0.5 bg-[#181512]" />
                  </div>
                  <div className="absolute bottom-1.5 right-1.5 w-2.5 h-2.5 rounded-full bg-[#CBD5E1] border border-[#181512] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1.5 h-0.5 bg-[#181512]" />
                  </div>

                  {/* Icon & Title */}
                  <div className="flex flex-col items-center text-center gap-1.5 pt-0.5">
                    <div className="shrink-0 group-hover:scale-110 transition-transform duration-100">
                      <PixelPhoneIcon size={42} />
                    </div>
                    <h2 className="font-pixel text-xs sm:text-sm text-[#181512] uppercase tracking-wider font-extrabold">
                      TEAM PHONE
                    </h2>
                  </div>

                  {/* High-Affordance 3D Pressable Button: JOIN MATCH */}
                  <ArcadeLink
                    to="/join"
                    variant="secondary"
                    size="md"
                    fullWidth
                    ctaType="join"
                    onFocus={() => setActiveCta('join')}
                    onBlur={() => setActiveCta(null)}
                    className="!bg-[#FFCC00] hover:!bg-[#FFB800] !border-[3px] !border-[#181512] !text-[#181512] font-black tracking-wider text-xs sm:text-sm py-2 sm:py-2.5 shadow-[0_4px_0_#B8860B,3px_4px_0_#181512] hover:shadow-[0_5px_0_#B8860B,4px_5px_0_#181512] active:translate-y-1 active:shadow-[0_0px_0_#B8860B,1px_1px_0_#181512] motion-reduce:active:translate-y-0 motion-reduce:hover:translate-y-0 transition-all"
                  >
                    JOIN MATCH
                  </ArcadeLink>
                </div>
              </div>

              {/* Sturdy Wooden Timber Support Posts (Planted into ground) */}
              <div className="hidden sm:flex justify-between w-4/5 px-4 -mt-1 pointer-events-none z-0">
                <div className="w-8 h-8 bg-[#A1551E] border-x-[3px] border-b-[3px] border-[#181512] flex flex-col justify-around py-1">
                  <div className="w-full h-0.5 bg-[#6E3811]" />
                  <div className="w-full h-0.5 bg-[#6E3811]" />
                </div>
                <div className="w-8 h-8 bg-[#A1551E] border-x-[3px] border-b-[3px] border-[#181512] flex flex-col justify-around py-1">
                  <div className="w-full h-0.5 bg-[#6E3811]" />
                  <div className="w-full h-0.5 bg-[#6E3811]" />
                </div>
              </div>
            </div>

            {/* ================================================================= */}
            {/* SECONDARY UTILITY CTA: EVENT ADMIN (Subordinate Castle Console)    */}
            {/* ================================================================= */}
            <div
              onAnimationEnd={handleEntranceEnd}
              className={`flex flex-col items-center w-full max-w-[280px] opacity-90 hover:opacity-100 transition-opacity ${isFirstVisit ? 'anim-card-arrival-admin' : ''}`}
            >
              {/* Castle Battlements & Compact Waving Flag Header */}
              <div className="hidden sm:flex justify-between items-end w-full px-1 -mb-1 z-10 pointer-events-none">
                {/* 5 Compact Castle Merlons */}
                <div className="flex gap-1">
                  <div className="w-3.5 h-3 bg-[#64748B] border-t-2 border-x-2 border-[#181E28]" />
                  <div className="w-3.5 h-3 bg-[#64748B] border-t-2 border-x-2 border-[#181E28]" />
                  <div className="w-3.5 h-3 bg-[#64748B] border-t-2 border-x-2 border-[#181E28]" />
                  <div className="w-3.5 h-3 bg-[#64748B] border-t-2 border-x-2 border-[#181E28]" />
                  <div className="w-3.5 h-3 bg-[#64748B] border-t-2 border-x-2 border-[#181E28]" />
                </div>
                {/* Compact Waving Flag on Pole */}
                <div className="flex items-start -mb-0.5 mr-0.5">
                  <div className="w-1 h-6 bg-[#181E28] shrink-0 rounded-t-sm" />
                  <svg
                    width="20"
                    height="12"
                    viewBox="0 0 24 16"
                    fill="none"
                    className="anim-flag-flutter origin-left -ml-0.5"
                  >
                    <path d="M0 0 L24 8 L0 16 Z" fill="#94A3B8" stroke="#181E28" strokeWidth="2" />
                    <path d="M0 2 L18 8 L0 10 Z" fill="#CBD5E1" />
                  </svg>
                </div>
              </div>

              <div
                onPointerEnter={() => setActiveCta('admin')}
                onPointerLeave={() => setActiveCta(null)}
                className="group relative w-full bg-[#475569] border-[3px] border-[#181E28] shadow-[4px_4px_0px_#102040] hover:shadow-[6px_6px_0px_#102040] hover:-translate-y-0.5 transition-all duration-100 ease-out p-2 sm:p-2.5 flex flex-col justify-between items-center text-center rounded-sm select-none"
              >
                {/* Left stone highlight */}
                <div className="absolute top-0 bottom-0 left-0 w-2 bg-[#64748B] border-r border-[#334155] pointer-events-none" />
                {/* Right stone shadow */}
                <div className="absolute top-0 bottom-0 right-0 w-2 bg-[#334155] border-l border-[#1E293B] pointer-events-none" />
                {/* Top stone highlight */}
                <div className="absolute top-0 left-0 right-0 h-1.5 bg-[#94A3B8] pointer-events-none" />
                {/* Bottom stone shadow */}
                <div className="absolute bottom-0 left-0 right-0 h-1.5 bg-[#1E293B] pointer-events-none" />

                {/* Inner Slate Face */}
                <div className="relative w-full bg-[#E2E8F0] border-2 border-[#64748B] shadow-inner pt-2 pb-2 px-2 sm:px-3 flex flex-col items-center justify-between gap-2 rounded-none z-10">
                  {/* 4 Corner Silver Rivets with Screws */}
                  <div className="absolute top-1.5 left-1.5 w-2 h-2 rounded-full bg-[#CBD5E1] border border-[#181E28] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1 h-0.5 bg-[#181E28]" />
                  </div>
                  <div className="absolute top-1.5 right-1.5 w-2 h-2 rounded-full bg-[#CBD5E1] border border-[#181E28] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1 h-0.5 bg-[#181E28]" />
                  </div>
                  <div className="absolute bottom-1.5 left-1.5 w-2 h-2 rounded-full bg-[#CBD5E1] border border-[#181E28] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1 h-0.5 bg-[#181E28]" />
                  </div>
                  <div className="absolute bottom-1.5 right-1.5 w-2 h-2 rounded-full bg-[#CBD5E1] border border-[#181E28] shadow-[1px_1px_0px_#475569] flex items-center justify-center">
                    <div className="w-1 h-0.5 bg-[#181E28]" />
                  </div>

                  {/* Icon & Title */}
                  <div className="flex flex-col items-center text-center gap-1 pt-0.5">
                    <div className="shrink-0 group-hover:scale-105 transition-transform duration-100">
                      <PixelTerminalIcon size={32} />
                    </div>
                    <h2 className="font-pixel text-[10px] sm:text-xs text-[#334155] uppercase tracking-wider font-bold">
                      EVENT ADMIN
                    </h2>
                  </div>

                  {/* Subordinate Secondary Button: ADMIN CONSOLE */}
                  <ArcadeLink
                    to="/admin"
                    variant="primary"
                    size="sm"
                    fullWidth
                    ctaType="admin"
                    onFocus={() => setActiveCta('admin')}
                    onBlur={() => setActiveCta(null)}
                    className="!bg-[#334155] hover:!bg-[#1E293B] !border-2 !border-[#181E28] !text-[#F1F5F9] font-bold text-[10px] sm:text-xs py-1.5 shadow-[0_2px_0_#0F172A,2px_2px_0_#181E28] hover:-translate-y-[1px] hover:shadow-[0_3px_0_#0F172A,2px_3px_0_#181E28] active:translate-y-0.5 active:shadow-[0_1px_0_#0F172A,1px_1px_0_#181E28] motion-reduce:active:translate-y-0 motion-reduce:hover:translate-y-0 transition-all"
                  >
                    ADMIN CONSOLE
                  </ArcadeLink>
                </div>
              </div>

              {/* Stone Pillar Support Posts (Planted into ground) */}
              <div className="hidden sm:flex justify-between w-4/5 px-4 -mt-1 pointer-events-none z-0">
                <div className="w-6 h-8 bg-[#475569] border-x-2 border-b-2 border-[#181E28] flex flex-col justify-around py-1">
                  <div className="w-full h-0.5 bg-[#1E293B]" />
                  <div className="w-full h-0.5 bg-[#1E293B]" />
                </div>
                <div className="w-6 h-8 bg-[#475569] border-x-2 border-b-2 border-[#181E28] flex flex-col justify-around py-1">
                  <div className="w-full h-0.5 bg-[#1E293B]" />
                  <div className="w-full h-0.5 bg-[#1E293B]" />
                </div>
              </div>
            </div>
          </div>

          {/* ================================================================= */}
          {/* Grounded 16-Bit Stage Platform (Chunky Brick/Dirt Foundation)     */}
          {/* ================================================================= */}
          <div className={`hidden sm:flex flex-col items-center w-full -mt-0.5 pointer-events-none select-none ${isFirstVisit ? 'anim-stage-arrival' : ''}`}>
            {/* Top Grass Strip with Wildflowers & Tuft Decor */}
            <div className="w-full h-4 sm:h-5 bg-[#22C55E] border-x-[3px] border-t-[3px] border-[#181512] relative flex items-center justify-around px-4 sm:px-8 shadow-sm">
              {/* Grass drops hanging into dirt */}
              <div className="absolute -bottom-1.5 left-12 w-2.5 h-1.5 bg-[#22C55E] border-b-2 border-x-2 border-[#181512]" />
              <div className="absolute -bottom-2 left-36 w-3 h-2 bg-[#22C55E] border-b-2 border-x-2 border-[#181512]" />
              <div className="absolute -bottom-1.5 left-64 w-2 h-1.5 bg-[#22C55E] border-b-2 border-x-2 border-[#181512]" />
              <div className="absolute -bottom-2 right-40 w-3 h-2 bg-[#22C55E] border-b-2 border-x-2 border-[#181512]" />
              <div className="absolute -bottom-1.5 right-16 w-2.5 h-1.5 bg-[#22C55E] border-b-2 border-x-2 border-[#181512]" />

              <div className="flex items-center gap-0.5 -mt-3.5">
                <PixelGrassTuft size={18} variant={1} />
                <PixelFlower size={18} variant={1} />
              </div>
              <div className="flex items-center gap-0.5 -mt-3.5">
                <PixelFlower size={18} variant={2} />
                <PixelGrassTuft size={18} variant={2} />
              </div>
              <div className="flex items-center gap-0.5 -mt-3.5">
                <PixelGrassTuft size={18} variant={1} />
                <PixelFlower size={18} variant={1} />
              </div>
              <div className="flex items-center gap-0.5 -mt-3.5">
                <PixelFlower size={18} variant={2} />
                <PixelGrassTuft size={18} variant={2} />
              </div>
              <div className="flex items-center gap-0.5 -mt-3.5">
                <PixelGrassTuft size={18} variant={1} />
                <PixelFlower size={18} variant={1} />
              </div>
            </div>

            {/* Chunky Earthy Brick / Dirt Platform Foundation Tier */}
            <div className="w-full h-8 sm:h-9 bg-[#B84418] border-x-[3px] border-b-[3px] border-[#181512] relative overflow-hidden flex flex-col justify-between py-1">
              {/* Brick Mortar Lines */}
              <div className="w-full h-0.5 bg-[#102040] opacity-40" />
              <div className="w-full h-0.5 bg-[#102040] opacity-40" />

              {/* Dirt Speckles */}
              <div className="absolute top-1 left-8 w-2 h-1 bg-[#8B2500]" />
              <div className="absolute bottom-1.5 left-24 w-2 h-1 bg-[#FF8C00]" />
              <div className="absolute top-2 left-48 w-1.5 h-1.5 bg-[#8B2500]" />
              <div className="absolute bottom-1 right-32 w-2 h-1 bg-[#FF8C00]" />
              <div className="absolute top-1.5 right-12 w-2 h-1 bg-[#8B2500]" />
            </div>

            {/* Bottom Hanging Roots / Pillar Footings */}
            <div className="flex justify-around w-4/5 -mt-0.5">
              <div className="w-3.5 h-2.5 bg-[#8B2500] border-b-2 border-x-2 border-[#181512]" />
              <div className="w-4 h-3 bg-[#8B2500] border-b-2 border-x-2 border-[#181512]" />
              <div className="w-3 h-2 bg-[#8B2500] border-b-2 border-x-2 border-[#181512]" />
              <div className="w-4 h-3 bg-[#8B2500] border-b-2 border-x-2 border-[#181512]" />
              <div className="w-3.5 h-2.5 bg-[#8B2500] border-b-2 border-x-2 border-[#181512]" />
            </div>
          </div>
        </main>
      </div>

      <RulesSection />

      {/* ======================================================================= */}
      {/* Tap / Touch Easter Egg Bursts (Phase 4)                                 */}
      {/* ======================================================================= */}
      <TapCoinBurst isBooting={isFirstVisit} />

      {/* ======================================================================= */}
      {/* LAYER 4: Living Pixel World Ground & Scene                              */}
      {/* ======================================================================= */}
      <PixelWorld isIntroActive={showIntro} />
    </div>
  );
};
