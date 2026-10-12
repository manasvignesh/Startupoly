import React from 'react';
import { Link } from 'react-router-dom';
import { RulesSection } from './RulesSection';

export const RulesPage: React.FC = () => (
  <div className="min-h-screen bg-[#102040]">
    <header className="sticky top-0 z-30 flex items-center justify-between gap-4 bg-[#102040] border-b-4 border-[#181512] px-4 py-3">
      <Link to="/" className="font-pixel text-[10px] text-[#FFCC00] hover:text-white">
        ← STARTUPOLY
      </Link>
      <span className="font-pixel text-[10px] text-[#FFFBEB]">FIELD GUIDE</span>
    </header>
    <RulesSection />
  </div>
);
