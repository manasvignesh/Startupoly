import React, { useState } from 'react';

const boardSpaces = [
  'START',
  'Open',
  'Open',
  'Open',
  'Open',
  'Open',
  'ACTION B',
  'Open',
  'Open',
  'Open',
  'Open',
  'Open',
  'ACTION C',
  'Open',
  'Open',
  'Open',
  'Open',
  'Open',
  'ACTION D',
  'Open',
  'Open',
  'Open',
  'Open',
  'Open',
];

const businesses = [
  ['EdTech', '₹200', '+150 CV'],
  ['SaaS', '₹300', '+180 CV'],
  ['E-Commerce', '₹300', '+180 CV'],
  ['FinTech', '₹400', '+200 CV'],
  ['HealthTech', '₹400', '+200 CV'],
  ['AI / DeepTech', '₹500', '+250 CV'],
  ['DevTools / Infrastructure', '₹300', '+190 CV'],
  ['Cybersecurity', '₹400', '+220 CV'],
  ['CleanTech / Energy', '₹500', '+240 CV'],
  ['Robotics & IoT', '₹500', '+250 CV'],
];

const bonusCards = [
  ['1', 'Startup Grant', '+₹300 cash'],
  ['2', 'Viral Growth', '+300 CV'],
  ['3', 'Government Incentive', '+₹200 cash + 200 CV'],
  ['4', 'Premium Deal', 'Cash equal to the cost of the most expensive owned business'],
  ['5', 'Founder Bonus', '₹100 × businesses owned'],
  ['6', 'Lucky Break', 'Roll again for a cash reward; it does not move the token'],
];

const crisisCards = [
  ['1', 'Tax Raid', '−₹300 cash'],
  ['2', 'Market Crash', '−300 CV'],
  ['3', 'Legal Trouble', '−₹200 cash and −200 CV'],
  ['4', 'Burn Rate Spike', '−₹100 cash × businesses owned'],
  ['5', 'Bad PR', '−200 CV and −₹100 cash'],
  ['6', 'Investor Pullout', '−₹500 cash'],
];

const teamColors = ['#E52521', '#0099FF', '#22C55E', '#FFCC00', '#A855F7', '#EC4899'];

const ruleGroups = [
  {
    title: 'The objective',
    icon: '★',
    body: 'Build the most valuable startup portfolio before the 50-minute gameplay clock ends. Every team starts with ₹1,000 cash, 0 Company Value and 0 businesses.',
  },
  {
    title: 'How a turn works',
    icon: '↻',
    body: 'Teams act in strict round-robin order. Roll one die, move exactly that number, and resolve the landing before the next roll. A 6 grants an extra roll. Three 6s in one turn cancel the entire turn and reverse its effects.',
  },
  {
    title: 'START and growth',
    icon: '↗',
    body: 'Passing or landing on START completes a lap and awards +₹200 cash. Growth bonuses reward portfolios: 2 businesses give +200 CV; 3 businesses give +500 CV total.',
  },
  {
    title: 'Ownership and upgrades',
    icon: '◆',
    body: 'A team can own a maximum of 3 businesses. Each business can move from Base to Upgrade 1 to Upgrade 2. Upgrades increase both the rent paid by visitors and the CV received by the owner.',
  },
  {
    title: 'Forced sales and bankruptcy',
    icon: '!',
    body: 'When a team cannot pay, all available cash is used first. The team chooses businesses to sell to the Bank at their original purchase cost. Upgrade value is lost, but earned CV is never removed. A team with no businesses left and an unpaid balance is bankrupt.',
  },
  {
    title: 'Winning the match',
    icon: '♛',
    body: 'When the clock reaches 00:00, all movement stops immediately. The highest Company Value wins. Ties are broken by higher cash, then more businesses, then a 30-second pitch judged by the Game Master.',
  },
];

export const RulesSection: React.FC = () => {
  const [activeGroup, setActiveGroup] = useState(0);

  return (
    <section id="rules" className="relative z-20 bg-[#102040] border-y-[6px] border-[#181512] text-[#FFFBEB] px-4 py-12 sm:py-16 scroll-mt-4">
      <div className="max-w-6xl mx-auto">
        <div className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-5 mb-8">
          <div>
            <p className="font-pixel text-[10px] text-[#FFCC00] tracking-widest mb-3">PLAYER FIELD GUIDE</p>
            <h2 className="font-pixel text-xl sm:text-3xl leading-relaxed">HOW TO PLAY STARTUPOLY</h2>
            <p className="font-mono text-sm text-[#CBD5E1] mt-3 max-w-2xl leading-relaxed">
              One physical board. Six possible teams. Fifty minutes to build a portfolio that survives the market.
            </p>
          </div>
          <a href="#top" className="font-pixel text-[10px] text-[#FFCC00] hover:text-white border-2 border-[#FFCC00] px-3 py-2 shadow-[3px_3px_0_#000]">BACK TO TOP ↑</a>
        </div>

        <div className="grid lg:grid-cols-[0.9fr_1.1fr] gap-6 items-start">
          <div className="flex flex-col gap-3">
            {ruleGroups.map((group, index) => (
              <button
                type="button"
                key={group.title}
                onClick={() => setActiveGroup(index)}
                className={`text-left border-3 border-[#181512] px-4 py-3 shadow-[4px_4px_0_#000] transition-transform hover:-translate-y-0.5 ${activeGroup === index ? 'bg-[#FFCC00] text-[#102040]' : 'bg-[#1E3A5F] text-[#FFFBEB]'}`}
              >
                <span className="font-pixel text-xs">{group.icon} {group.title}</span>
              </button>
            ))}
            <div className="bg-[#22B14C] text-white border-3 border-[#181512] px-4 py-3 shadow-[4px_4px_0_#000]">
              <p className="font-pixel text-[10px]">MATCH FORMAT</p>
              <p className="font-mono text-xs mt-2 leading-relaxed">5 min setup · 50 min gameplay · 5 min reset</p>
              <p className="font-mono text-xs mt-1 leading-relaxed">5–6 teams · 4–5 players per team</p>
            </div>
          </div>

          <div className="bg-[#FFFBEB] text-[#102040] border-4 border-[#181512] shadow-[7px_7px_0_#000] p-5 sm:p-7 min-h-[190px]">
            <p className="font-pixel text-[10px] text-[#B84418] mb-4">RULE {String(activeGroup + 1).padStart(2, '0')}</p>
            <h3 className="font-pixel text-base sm:text-lg leading-relaxed">{ruleGroups[activeGroup].title}</h3>
            <p className="font-mono text-sm leading-7 mt-5">{ruleGroups[activeGroup].body}</p>
          </div>
        </div>

        <div className="mt-10 grid lg:grid-cols-2 gap-6">
          <div className="bg-[#1E3A5F] border-4 border-[#181512] shadow-[6px_6px_0_#000] p-4 sm:p-5">
            <div className="flex items-center justify-between gap-3 mb-4">
              <div>
                <p className="font-pixel text-[10px] text-[#FFCC00]">PHYSICAL BOARD</p>
                <p className="font-mono text-xs text-[#CBD5E1] mt-2">The real board will be installed at the event.</p>
              </div>
              <span className="font-pixel text-[9px] bg-[#FFCC00] text-[#102040] px-2 py-1">DESIGN PENDING</span>
            </div>
            <div className="relative border-3 border-dashed border-[#FFCC00] bg-[#102040] p-3 sm:p-5">
              <div className="absolute inset-3 sm:inset-5 border-2 border-[#22B14C]/60 pointer-events-none" />
              <div className="grid grid-cols-4 sm:grid-cols-6 gap-1.5 sm:gap-2 relative">
                {boardSpaces.map((space, index) => (
                  <div
                    key={`${space}-${index}`}
                    className={`min-h-12 sm:min-h-16 border-2 border-[#FFFBEB]/70 p-1.5 flex flex-col justify-between ${space === 'START' ? 'bg-[#22B14C] text-white' : space.startsWith('ACTION') ? 'bg-[#E6631F] text-white' : 'bg-[#1E3A5F] text-[#FFFBEB]'}`}
                  >
                    <span className="font-mono text-[9px] opacity-80">{String(index + 1).padStart(2, '0')}</span>
                    <span className="font-pixel text-[8px] leading-3">{space}</span>
                  </div>
                ))}
              </div>
              <div className="mt-4 text-center border-2 border-[#FFCC00] bg-[#102040] py-2">
                <span className="font-pixel text-[9px] text-[#FFCC00]">FINAL BOARD ARTWORK WILL REPLACE THIS PLACEHOLDER</span>
              </div>
            </div>
          </div>

          <div className="bg-[#FFFBEB] text-[#102040] border-4 border-[#181512] shadow-[6px_6px_0_#000] p-4 sm:p-5">
            <p className="font-pixel text-[10px] text-[#B84418]">THE STARTUP MARKET</p>
            <p className="font-mono text-xs mt-2 mb-4">Buy, upgrade, earn CV and survive rent.</p>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
              {businesses.map(([name, cost, cv]) => (
                <div key={name} className="border-2 border-[#102040]/25 bg-white px-3 py-2">
                  <p className="font-pixel text-[9px] leading-4">{name}</p>
                  <p className="font-mono text-xs text-[#B84418] mt-1">{cost} · {cv}</p>
                </div>
              ))}
            </div>
          </div>
        </div>

        <div className="mt-6 grid lg:grid-cols-2 gap-6">
          <div className="bg-[#22B14C] text-white border-4 border-[#181512] shadow-[6px_6px_0_#000] p-4 sm:p-5">
            <p className="font-pixel text-[10px]">BONUS CARDS</p>
            <div className="mt-4 flex flex-col gap-2">
              {bonusCards.map(([number, name, effect]) => (
                <div key={number} className="flex gap-3 items-start border-b border-white/25 pb-2">
                  <span className="font-pixel text-xs bg-[#FFCC00] text-[#102040] px-1.5 py-1">{number}</span>
                  <div><p className="font-pixel text-[9px]">{name}</p><p className="font-mono text-[11px] mt-1">{effect}</p></div>
                </div>
              ))}
            </div>
          </div>
          <div className="bg-[#B84418] text-white border-4 border-[#181512] shadow-[6px_6px_0_#000] p-4 sm:p-5">
            <p className="font-pixel text-[10px]">CRISIS CARDS</p>
            <div className="mt-4 flex flex-col gap-2">
              {crisisCards.map(([number, name, effect]) => (
                <div key={number} className="flex gap-3 items-start border-b border-white/25 pb-2">
                  <span className="font-pixel text-xs bg-[#FFCC00] text-[#102040] px-1.5 py-1">{number}</span>
                  <div><p className="font-pixel text-[9px]">{name}</p><p className="font-mono text-[11px] mt-1">{effect}</p></div>
                </div>
              ))}
            </div>
          </div>
        </div>

        <div className="mt-6 bg-[#FFCC00] text-[#102040] border-4 border-[#181512] shadow-[6px_6px_0_#000] p-4 sm:p-5">
          <p className="font-pixel text-[10px]">TEAM COLORS · TEMPORARY EVENT ASSIGNMENTS</p>
          <div className="flex flex-wrap gap-3 mt-4">
            {teamColors.map((color, index) => (
              <div key={color} className="flex items-center gap-2 font-mono text-xs">
                <span className="w-5 h-5 border-2 border-[#102040]" style={{ backgroundColor: color }} />
                TEAM {index + 1}
              </div>
            ))}
          </div>
          <p className="font-mono text-xs mt-4">These basic colors are placeholders and can be replaced after the final event identity is approved.</p>
        </div>
      </div>
    </section>
  );
};
