# STARTUPOLY Event Runbook & Tech Runner Guide

> **Event Day Field Guide**  
> *Target Audience: Tech Runners, Game Masters, and Tournament Scorekeepers*  
> *Document Version: 1.0 (Production)*

---

## 1. System Overview & Roles

STARTUPOLY is a **physical board game** featuring a real-time, server-authoritative live scoreboard. 

- **Event Admin (Laptop)**: 1 operator per room operating on a laptop/desktop ($\ge 1024\text{ px}$). Authenticated with admin email/password. Records board transactions, controls the 50:00 match clock, resolves ties, and finalizes results.
- **Team Scoreboards (Phones)**: 1 phone per team (5–6 teams per match). Anonymous, strictly read-only display showing authoritative cash, company value (CV), clock, and owned businesses.
- **Open-ground operation**: No projector or shared screen is required. The admin laptop runs the control room, while each team uses its own phone for its private scoreboard.

---

## 2. Pre-Event Checklist (T−60 to T−15 min)

Complete this checklist at least 30 minutes before players enter the room:

- [ ] **Venue Wi-Fi & Hotspot Verification**: Connect the admin laptop to venue Wi-Fi. Verify low-latency connection (< 150 ms) to Supabase. Ensure an organizer's mobile 5G hotspot is on standby as immediate failover.
- [ ] **Admin Hardware**: Laptop plugged into AC mains power; display timeout disabled; external mouse connected for rapid data entry.
- [ ] **Projector Setup**: Connect laptop HDMI/USB-C to the room projector. Test display duplication or extended monitor at 1080p ($1920 \times 1080$).
- [ ] **Team PIN Cards Prepared**: Print or handwrite 6 team index cards with:
  - Team Slot Number (#1 to #6)
  - Team Name
  - 4-Digit Secret PIN (retrieved from the Admin Lobby view)
- [ ] **Run Production Health Check**:
  ```bash
  npx tsx scripts/verify-prod.ts --url=https://<your-project>.supabase.co --key=<anon-key>
  ```
  *Ensure all 6 permission and security checks pass.*
- [ ] **Paper Fallback Scoreboard**: Have 2 copies of the Paper Fallback Sheet (Section 5) and 2 pens on the scorer's table.

---

## 3. Per-Match Procedure (Step-by-Step)

### Step 1: Create Room & Configure Teams
1. Navigate to `/admin` and log in with your admin credentials.
2. Select team count: **5 Teams** or **6 Teams** (official tournament formats).
3. Confirm team names and distinct colors. Click **"CREATE TOURNAMENT ROOM"**.

### Step 2: Open Lobby & Project Room Code
1. Click **"OPEN LOBBY"**.
2. The large 6-character room code (e.g. `K9X2P4`) appears in the center card.
3. Switch projector display to show this lobby screen so all teams can see the code clearly from 3+ meters away.

### Step 3: Distribute Secret PINs
1. Look at the **"TEAM CONNECTIONS & SECRET PINS"** grid in the admin console.
2. Note each team's unique 4-digit PIN.
3. Hand each team captain their corresponding index card containing their slot, team name, and PIN.

### Step 4: Confirm All Teams Joined
1. Team captains open their phone browser and navigate to `/join`.
2. Captains input:
   - **Step 1**: 6-character Room Code.
   - **Step 2**: Select their team slot.
   - **Step 3**: Enter their secret 4-digit PIN.
3. In the admin console, watch the status pills update from `WAITING` (yellow) to `ACTIVE` (green pulse).
4. Verify all 5 or 6 teams show `CONNECTED`.
5. If a team accidentally claims the wrong slot, click **"RELEASE"** on that team's card and have them rejoin.

### Step 5: Start Match on Game Master's Signal
1. The Game Master gives the 3-2-1 countdown.
2. Click **"START GAME (50:00)"**. 
3. The authoritative countdown immediately starts on the server and synchronizes across the admin laptop and all team phones within 500 ms.

### Step 6: Record Live Board Transactions
During play, use the quick-action calculator dialogs at the bottom of the admin console for maximum entry speed:

| Event on Physical Board | Admin Action | Keyboard Shortcut / Flow |
|---|---|---|
| **Rent Payment** | Click `RENT (PAY)` | Select paying team, receiving team, and business. Auto-calculates rent based on business level. Click Confirm. |
| **Pass START Lap** | Click `PASS START` | Select team. Pre-fills ₹200 cash (+ ₹0, ₹250, or ₹500 CV bonus depending on business portfolio). Click Confirm. |
| **Acquire Business** | Click `BUY BIZ` | Select business (1 of 10) from catalog. Auto-charges initial cost and credits initial CV. |
| **Upgrade Business** | Click `UPGRADE` | Select owned business. Level 0 → 1 or Level 1 → 2. Deducts upgrade fee and increments CV. |
| **Crisis / Bonus Card** | Click `CARD` | Select `BONUS` or `CRISIS`. Select preset card amount or enter custom amount. |
| **Forced Sale** | Click `FORCED SALE` | Liquidates an owned business for 50% resale credit when team owes debt. |
| **Steal Talent** | Click `STEAL TALENT` | Target team loses ₹100; active team gains ₹100. |

*Team Selection Tip*: Press number keys `1`–`6` or Arrow keys on your laptop keyboard to immediately switch active teams without using the trackpad.

### Step 7: 50:00 GAME OVER
1. When the countdown reaches `00:00`, the server transitions the room to `TIME_EXPIRED`.
2. The UI flashes `GAME OVER` on all team phones.
3. The Game Master announces: *"Pencils and dice down! The match is over."*
4. All real-time phone dashboards freeze at match-end values.

### Step 8: Reconciliation Window (5 Minutes)
1. In `TIME_EXPIRED` mode, the admin console remains interactive for post-match adjustments.
2. **Mandatory Audit Note**: Any edit made during this window requires a brief explanatory note (e.g., *"Reconcile final dice roll rent"*).
3. If an edit is attempted without a note, the system prompts for one.

### Step 9: Tie-Break Entry (If Applicable)
The system automatically detects ties according to the official tournament tie-breaking sequence:
1. Highest Company Value (CV).
2. If CV is equal: Highest Cash.
3. If Cash is equal: Most Businesses Held.
4. If still tied: **30-Second Pitch** judged by Game Master.
   - If an unresolved tie exists, the **Finalize Panel** displays an amber tie-break selector.
   - Enter the Game Master's judged ranking order.
   - Click **"SAVE TIE-BREAK ORDER"**.

### Step 10: Finalize & Display Podium
1. Click **"FINALIZE MATCH"**.
2. The official results are written permanently to `final_results`.
3. The presentation podium reveals:
   - 🥇 **1st Place (Winner)** with golden animated trophy
   - 🥈 **2nd Place (Silver)**
   - 🥉 **3rd Place (Bronze)**
   - Full standings table with CV, Cash, and owned business breakdown.
4. The Game Master announces the podium from the admin laptop; teams can view their own final result on their phones.

### Step 11: Start Next Match
1. Click **"NEXT MATCH"** at the top right of the screen.
2. The completed match is securely archived under `/admin/history`.
3. Return to Step 1 for the subsequent match.

---

## 4. Troubleshooting & Incident Matrix

| Symptom | Probable Cause | Immediate Remediation |
|---|---|---|
| **Phone says "Code, team or PIN didn't match"** | Typo in 6-char code, wrong slot selected, or incorrect 4-digit PIN. | Verify code on projector. Check the team's PIN in the Admin Lobby grid. Ensure team didn't choose a slot already claimed by another phone. |
| **Phone captain closed browser or lost session** | Mobile Safari / Chrome auto-refreshed or closed tab. | Have captain reopen `/join`. Anonymous Supabase session persists in `localStorage`; captain re-enters code, slot, and PIN to re-link immediately. |
| **Admin laptop battery died or crashed** | Hardware or power failure. | Plug laptop into AC power. Re-open browser and log in at `/admin`. The system automatically redirects to `/admin/room/[id]` because all room state lives in PostgreSQL. No data is lost. |
| **Venue Wi-Fi drops completely** | Router/ISP failure. | 1. Admin turns on phone cellular hotspot.<br>2. Reconnect laptop to hotspot.<br>3. Admin console displays red `OFFLINE` banner until reconnected, then syncs live snapshot automatically. |
| **Wrong transaction amount entered** | Scorer typo during rapid entry. | 1. Select the affected team.<br>2. In the Cash or CV editor, type the corrected balance.<br>3. Provide an audit note describing the correction.<br>4. Click **UPDATE**. |
| **Version Mismatch / Conflict Dialog appears** | Two admins tried editing the same team simultaneously. | The Conflict Dialog shows: *"Server was modified by another operator"*. Click **"DISCARD MY CHANGES"** to inspect current values, then re-apply if appropriate. |

---

## 5. Emergency Paper Fallback Scoreboard Template

If a prolonged catastrophic power or network outage occurs, use this paper template:

```
=============================================================================================
                          STARTUPOLY OFFICIAL TOURNAMENT SCOREBOARD (PAPER)
Match ID: ______________   Date: ______________   Game Master: _____________________________
=============================================================================================
Slot | Team Name       | Start Cash | Cash Edits (+ / −) | Final Cash | Businesses | Final CV
---------------------------------------------------------------------------------------------
 #1  |                 |   ₹1,000   |                    |            |            |
---------------------------------------------------------------------------------------------
 #2  |                 |   ₹1,000   |                    |            |            |
---------------------------------------------------------------------------------------------
 #3  |                 |   ₹1,000   |                    |            |            |
---------------------------------------------------------------------------------------------
 #4  |                 |   ₹1,000   |                    |            |            |
---------------------------------------------------------------------------------------------
 #5  |                 |   ₹1,000   |                    |            |            |
---------------------------------------------------------------------------------------------
 #6  |                 |   ₹1,000   |                    |            |            |
=============================================================================================
Tie-Break Hierarchy: 1) Highest CV -> 2) Highest Cash -> 3) Most Businesses -> 4) 30s Pitch
Final Verified Winner: ___________________________   Signature: _____________________________
```

---
*End of Runbook.*
