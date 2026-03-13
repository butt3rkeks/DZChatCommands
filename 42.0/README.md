# Dynamic Evolution Z - MP Fixes

Companion mod for [Dynamic Evolution Z](https://steamcommunity.com/sharedfiles/filedetails/?id=3676814360). Fixes 15 bugs that break DZ on dedicated servers, adds an activity pressure system, and provides admin chat commands for managing the evolution system.

Does not modify any DZ files. All fixes are applied at runtime via function wrapping. Safe to add or remove at any time.

## Requirements

- Project Zomboid Build 42
- Dynamic Evolution Z (must load before this mod)

## Chat Commands

Type `/dz help` in-game chat. All commands require admin access.

| Command | Description |
|---------|-------------|
| `/dz status` | Show world evolution %, leaders, kills |
| `/dz debug <on\|off>` | Toggle debug overlay |
| `/dz inspect` | Inspect nearest zombie |
| `/dz untrack` | Stop tracking a zombie |
| `/dz setevo <0-1>` | Set world evolution value |
| `/dz addkills <n>` | Add kills to global counter |
| `/dz setstage <0-4>` | Set nearest zombie's evolution stage |
| `/dz makeleader [type]` | Promote nearest zombie to leader (HIVE/HUNTER/FRENZY/SHADOW/SPLIT) |
| `/dz forcepulse` | Force all leaders to pulse immediately |
| `/dz reset` | Reset all DZ state |
| `/dz forcesave` | Force backup write to file |
| `/dz pressure` | Show activity pressure heat map |
| `/dz diag` | Show server diagnostics (fix status, state values, backup info) |

## Server-Side Fixes (dz_persistence.lua)

### 1. ModData persistence loss
DZ stores state in `ModData.getOrCreate("DynamicZ_Global")` which returns an empty table after dedicated server restart. Fix: wraps `SaveGlobalState` to also write a backup file via `getFileWriter`. On startup, restores from backup if ModData is empty.

### 2. worldEvolution never computed on startup
`RecalculateWorldEvolution` is never called at server start, so world evolution stays at 0 until a zombie dies or midnight passes. Fix: computes correct evolution during startup fixup.

### 3. getWorldAgeDays on wrong object
DZ calls `gameTime:getWorldAgeDays()` but that method is on `IsoWorld`, not `GameTime`. Result is always 0 days. Fix: uses `getWorldAgeHours()/24` with the sandbox `TimeSinceApo` offset added.

### 4. OnGameStart unreliable on dedicated servers
DZ uses `Events.OnGameStart.Add` which may not fire on dedicated servers. Fix: registers an `EveryOneMinute` fallback that runs fixup if `OnGameStart` was missed.

### 5. EveryOneSecond does not exist
DZ registers `AdvanceLeaderTick` on `EveryOneSecond`. This event does not exist in PZ's `LuaEventManager` — only `EveryOneMinute` and `EveryTenMinutes` exist. The registration silently fails, so `pulseId` stays 0 and `TryLeaderPulse` always early-returns. Fix: registers on `OnTick` with `ticks % 10 == 0` (server runs at 10 FPS, so this fires once per real second).

### 6. OnMidnight does not exist
DZ registers `RecalculateWorldEvolution` on `OnMidnight` which does not exist in PZ. World evolution never recalculates during play. Fix: registers on `EveryDays` (fires at in-game day rollover).

### 7. getNumActiveZombies does not exist in B42
DZ calls `getNumActiveZombies()` to determine max leaders. This global was removed in Build 42. Auto-seeding never triggers and max leaders is capped at 1. Fix: polyfill using `getCell():getZombieList():size()`.

### 8. Dead setLastHeardSound in search-after-target-loss
DZ's `applyPersistenceAndSearch` calls `setLastHeardSound(x,y,z)` when an evolved zombie loses sight of its target. The zombie should search the player's last known position, but `setLastHeardSound` is dead code in B42 — the `lastHeardSound` field is written but never read by any game system (14 references: 7 writes, 1 reset, 0 reads).

Fix: wraps `ApplyStageEvolutionBuffs` to detect target loss and call `pathToLocationF` (A* pathfinding via `PathFindBehavior2`/`PolygonalMap2`, which works on dedicated servers). Enhanced with player ID tracking: stores the targeted player's `onlineID` while the zombie has a target, then uses `getPlayerByOnlineID` (O(1) HashMap lookup) after target loss to path toward the player's *current* position. Re-paths every 3 seconds for the duration of DZ's search window. Falls back to static last-known position if the player disconnected.

### 9. Dead setLastHeardSound in stage 4+ sense
DZ's `applyStage4Sense` calls dead `setLastHeardSound` when a stage 4+ zombie senses a nearby player without line of sight. The zombie should investigate but never moves. Fix: extends the `ApplyStageEvolutionBuffs` wrapper to replicate `findNearestPlayer` and call `pathToLocationF` to the detected player's position.

### 10. Dead setLastHeardSound in ambient wander
DZ's `TryAmbientWander` calls dead `setLastHeardSound` to make idle evolved zombies wander toward computed targets (influenced by nearby player presence and reactive kill signals). Fix: wraps `TryAmbientWander` to read stored target coords from modData and call `pathToLocationF`.

### 11. Dead setLastHeardSound in leader influence
DZ's `ApplyLeaderInfluence` calls dead `setLastHeardSound` to direct followers toward the leader's target, leader's position, or migration waypoints. Fix: wraps `ApplyLeaderInfluence` to iterate influenced followers and call `pathToLocationF` with coordinates per leader type:
- **HUNTER/FRENZY/SHADOW/HIVE**: leader's target position or leader's own position
- **SPLIT**: 3-way flanking offset computed from follower position hash (replicates DZ's `computeSplitPoint` using `LeaderSplitFlankDistance`)
- **Migrating**: blended migration target coordinates

### 12. getWorldAgeDaysSafe fallback drops timeSinceApo
DZ's `getWorldAgeDaysSafe()` (local in `DZ_GlobalState.lua`) has a fallback that uses `getWorldAgeHours()/24` without adding the `TimeSinceApo` sandbox offset. Since it's a local function, it can't be patched directly. Fix: replaces the entire `RecalculateWorldEvolution` function with one using the corrected `getWorldAgeDays()`.

### 13. LeaderPulseInterval defaults to 180 seconds
DZ's `AdvanceLeaderTick` uses `Config.LeaderPulseInterval` with a hardcoded fallback of 180. Since `LeaderPulseInterval` is not in DZ's default sandbox config, the fallback always applies: pulses fire every 3 minutes. Leaders only act during pulses, making the entire leader system extremely sluggish. Fix: replaces `AdvanceLeaderTick` with fallback interval of 3 (pulse every 3 seconds).

### 14. GetZombieDebugId is nil
DZ's `getZombieDebugId` (local in `DZ_Leader.lua`) checks `DynamicZ.GetZombieDebugId` first, then falls back to position strings `"P:x:y:z"`. By default `GetZombieDebugId` is nil, so all debug logging uses ambiguous position strings. Fix: sets `GetZombieDebugId` to try `getOnlineID()` → `getID()` → position.

### 15. DebugTrackTick on non-existent EveryOneSecond
DZ registers `DebugTrackTick` on `EveryOneSecond` (`DZ_Debug.lua:1501`). The server-side zombie tracking feature (admin inspect/track with diff-snapshots) never ticks. Fix: calls `DebugTrackTick()` from the `OnTick` handler alongside `AdvanceLeaderTick`. `DebugTrackTick` has its own internal time-based throttle.

### Admin debug access
DZ's debug system requires the sandbox `EnableDebugMode` setting. Fix: sets `DynamicZ.DebugEnabled = true` server-side at startup, which propagates to clients via `buildStatePayload`. The existing admin check in `canUseDebugUI` ensures only admins see the overlay and can use debug commands.

## Activity Pressure System (dz_pressure.lua)

Adds per-chunk "pressure" that builds when players remain in an area. Pressure influences three DZ systems: leader migration targeting, evolution speed, and leader auto-seed rate.

### How pressure accumulates

Pressure is tracked per chunk using DZ's own chunk coordinate system (`Config.MigrationChunkSize`, default 10 tiles). Every game-minute, each online player's chunk plus its immediate Manhattan-distance neighbors gain pressure at a rate of `1/720` per minute (~12 game-hours to reach max 1.0). Chunks without a player present decay at `1/1440` per minute (~24 game-hours from full to zero). Chunks below 0.001 are purged to save memory. Data is persisted to `DZChatCommands_Pressure.ini` every 10 game-minutes.

### Migration influence

Integrated into the `installLeaderFix` wrapper in dz_persistence.lua. Two cases:

- **Case A (redirect)**: When DZ starts a migration on its own, the wrapper calls `findBestPressureTarget(leader, currentScore)` to check if any high-pressure chunk scores higher than DZ's chosen target. If so, the migration target is overridden. This uses an extended scan radius: at max pressure, leaders can be attracted from up to 30 chunks (300 tiles) away, linearly interpolated from DZ's own 2-4 chunk radius at lower pressure.

- **Case B (initiate)**: When DZ's `evaluateMigrationTargetChunk` returns nil (no chunk passes its density/kill gates), the wrapper checks pressure-only targets. If a high-pressure chunk exists and DZ's preconditions are met (migration enabled, sufficient worldEvolution, leaderStage >= 1, enough followers, cooldown expired), the wrapper starts the migration itself by setting the same ModData fields that DZ's `startLeaderMigration` uses. Follower collection piggybacks on the existing grid traversal to avoid duplicate iteration.

Pressure score formula: `MIGRATION_PRESSURE_WEIGHT * pressure` (0 to 10 at max). This competes directly with DZ's `killWeight * recentKills + densityWeight * headroom` (typically 5-15 range).

### Evolution acceleration

Wraps `DynamicZ.TryAddEvolutionPoints`. After the original adds its base 1.0 point, adds a pressure bonus: `pressure * EVO_PRESSURE_MULTIPLIER` (default 1.0, so at max pressure zombies gain evo points at 2x rate). Uses a fractional accumulator (`_pressureEvoRemainder`) identical to DZ's `evoPointRemainder` pattern. Only applies when DZ's own guards pass (evolution enabled, `CanProcessZombie`, active chunk, target within 10 tiles).

### Leader auto-seed scaling

Wraps `DynamicZ.TryAutoSeedLeaders`. Temporarily inflates `DynamicZ_Config.LeaderAutoSeedMinPercent` based on average pressure across all tracked chunks. At max average pressure, the desired leader count is multiplied by `SEED_PRESSURE_MAX_MULTIPLIER` (default 5x). Original value is always restored after the call, even on error.

### Chat command

`/dz pressure` shows the pressure heat map: tracked chunk count, max/avg pressure, top 10 highest-pressure chunks, and current effect strengths (evo bonus, migration weight, seed multiplier).

## Client-Side Fixes

### Debug overlay (dz_debug_overlay_fix.lua)
Three stacked issues prevent the debug HUD from appearing on dedicated servers:

1. **Broken event registration**: `updateNearestZombieCache` is registered on non-existent `EveryOneSecond`. Fix: re-registered on `OnTick` with 1-second throttle via `getTimestampMs()`.

2. **Config gate**: `DynamicZ_Config.DebugOverlay = false` by default. `canShowOverlay()` checks this *before* the debug-enabled check, so the overlay never draws. Fix: overrides to `true` at load time (the admin + debugEnabled checks are sufficient gatekeeping).

3. **Chicken-and-egg state**: `onGameStart` checks `isClientDebugEnabled()` which is false on join (server hasn't sent state yet). It bails without requesting initial status. Fix: on first tick when player is admin, sends a status request to the server to bootstrap the state flow.

### Chat bridge (dz_chat.lua)
DZ's "slash commands" (`/dz_debug on`, etc.) are not hooked to in-game chat — they only work from the Lua debug console via `DynamicZ.DebugCommand()`. This mod wraps `ISChat.onCommandEntered` to intercept `/dz <subcommand>` and route through the existing `DynamicZ.Debug*` client API.

Server responses (`DebugInfo` and `DebugState`) are displayed in chat with deduplication: identical messages are suppressed within a 60-second window, and debug mode status only shows when it changes.

## Known Limitations

- **zombie.memory field**: PZ's Kahlua bridge only exposes Java methods, not instance fields. `IsoZombie.memory` (public int) is inaccessible from Lua. The memory buff in DZ's evolution system is effectively dead. The search fix (fix 8) provides a behavioral workaround via active pathfinding-based tracking instead of passive forget-time extension.

- **getZombieRuntimeId**: Uses `getObjectID()` which doesn't exist on `IsoZombie`. However, it tries `getOnlineID()` first which works in multiplayer, so this is not broken on dedicated servers. Fix 14 improves the final fallback chain.

## Files

```
42.0/
  media/lua/
    server/DZChatCommands/
      dz_persistence.lua     # All 15 server-side fixes + ForceSave/Diagnostics commands
      dz_pressure.lua        # Activity pressure system (heat map, migration/evo/seed hooks)
    client/DZChatCommands/
      dz_chat.lua            # Chat command bridge (/dz <subcommand>)
      dz_debug_overlay_fix.lua  # Debug HUD overlay fixes
```

## Logging

All log output uses `[DZChatCommands]` prefix. Deduplication suppresses identical log lines within 60 seconds — changed messages print immediately, unchanged messages re-print after the window expires.
