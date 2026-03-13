# Dynamic Evolution Z - MP Fixes

Companion mod for [Dynamic Evolution Z](https://steamcommunity.com/sharedfiles/filedetails/?id=3676814360). Fixes 7 bugs that break DZ on dedicated servers and provides admin chat commands for managing the evolution system.

Does not modify any DZ files. All fixes are applied at runtime via function wrapping. Safe to add or remove at any time.

> **DZ Update Note**: Fixes 2, 3, 5, 6, 7, 12, 13, 14, 15 were fixed upstream in the DZ restructuring update. The companion mod's pressure system was also removed — DZ now has a native `DZ_Pressure.lua` that is fully integrated into the evolution and leader systems.

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
| `/dz diag` | Show server diagnostics (fix status, state values, backup info) |

## Active Server-Side Fixes (dz_persistence.lua)

### 1. ModData persistence loss
DZ stores state in `ModData.getOrCreate("DynamicZ_Global")` which returns an empty table after dedicated server restart. Fix: wraps `SaveGlobalState` to also write a backup file via `getFileWriter`. On startup, restores from backup if ModData is empty.

### 4. OnGameStart unreliable on dedicated servers
DZ uses `Events.OnGameStart.Add` which may not fire on dedicated servers. Fix: registers an `EveryOneMinute` fallback that runs fixup if `OnGameStart` was missed.

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

### 16. SyncVanillaKillCounter loses offline player kills
DZ's `SyncVanillaKillCounter` only sums online players' kills — offline players' kills disappear from the sum. Fix: replaces `SyncVanillaKillCounter` with a vanilla-truth sync. Each player's `getZombieKills()` is the source of truth — PZ serializes this to the player save file, so it persists across restarts. Per-player values are persisted to `DZChatCommands_PlayerKills.ini` so offline players' kills are retained. `totalKills = max(totalKills, vanillaSum)` preserves unattributed kills (fire, environmental).

### Admin debug access
DZ's debug system requires the sandbox `EnableDebugMode` setting. Fix: sets `DynamicZ.DebugEnabled = true` server-side at startup, propagated to clients via `buildStatePayload`. The existing admin check in `canUseDebugUI` ensures only admins see the overlay.

## Fixed Upstream (no longer in companion mod)

These fixes were removed because the DZ update addressed them natively:

| # | Bug | DZ Fix |
|---|-----|--------|
| 2 | worldEvolution never computed on startup | `RecalculateWorldEvolution()` called in `OnGameStart` |
| 3 | getWorldAgeDays on wrong object | Uses `getWorldAgeDaysSinceBegin()` |
| 5 | EveryOneSecond doesn't exist | Simulated via `OnTick` with `getTimestampMs` / tick fallback |
| 6 | OnMidnight doesn't exist | Called from `OnEveryDays()` |
| 7 | getNumActiveZombies doesn't exist | `getNumActiveZombiesSafe()` with fallback |
| 12 | getWorldAgeDaysSafe fallback drops TimeSinceApo | Primary path now uses `getWorldAgeDaysSinceBegin` (includes offset) |
| 13 | LeaderPulseInterval defaults to 180 | Config now sets `LeaderPulseInterval = 3` |
| 14 | GetZombieDebugId is nil | `DZ_Debug` exports it with onlineID/objectID/position chain |
| 15 | DebugTrackTick on non-existent EveryOneSecond | Called from `OnEveryOneSecond` via `OnTick` simulation |

The companion mod's **Activity Pressure System** (`dz_pressure.lua`) was also removed — DZ now has a native `DZ_Pressure.lua` with full integration into evolution bonuses, leader seed multipliers, and migration scoring.

## Client-Side Fixes

### Debug overlay (dz_debug_overlay_fix.lua)
Three stacked issues prevent the debug HUD from appearing on dedicated servers:

1. **Broken event registration**: `updateNearestZombieCache` is registered on non-existent `EveryOneSecond`. Fix: re-registered on `OnTick` with 1-second throttle via `getTimestampMs()`.

2. **Config gate**: `DynamicZ_Config.DebugOverlay = false` by default. `canShowOverlay()` checks this *before* the debug-enabled check, so the overlay never draws. Fix: overrides to `true` at load time (the admin + debugEnabled checks are sufficient gatekeeping).

3. **Chicken-and-egg state**: `onGameStart` checks `isClientDebugEnabled()` which is false on join (server hasn't sent state yet). It bails without requesting initial status. Fix: on first tick when player is admin, sends a status request to the server to bootstrap the state flow.

### Chat bridge (dz_chat.lua)
DZ's "slash commands" are not hooked to in-game chat — they only work from the Lua debug console. This mod wraps `ISChat.onCommandEntered` to intercept `/dz <subcommand>` and route through the existing `DynamicZ.Debug*` client API.

Server responses (`DebugInfo` and `DebugState`) are displayed in chat with deduplication: identical messages are suppressed within a 60-second window, and debug mode status only shows when it changes.

## Known Limitations

- **zombie.memory field**: PZ's Kahlua bridge only exposes Java methods, not instance fields. `IsoZombie.memory` (public int) is inaccessible from Lua. The memory buff in DZ's evolution system is effectively dead. The search fix (fix 8) provides a behavioral workaround via active pathfinding-based tracking instead of passive forget-time extension.

- **getZombieRuntimeId**: Uses `getObjectID()` which doesn't exist on `IsoZombie`. However, it tries `getOnlineID()` first which works in multiplayer, so this is not broken on dedicated servers.

## Files

```
42.0/
  media/lua/
    server/DZChatCommands/
      dz_persistence.lua     # 7 active server-side fixes + ForceSave/Diagnostics commands
    client/DZChatCommands/
      dz_chat.lua            # Chat command bridge (/dz <subcommand>)
      dz_debug_overlay_fix.lua  # Debug HUD overlay fixes
```

## Logging

All log output uses `[DZChatCommands]` prefix. Deduplication suppresses identical log lines within 60 seconds — changed messages print immediately, unchanged messages re-print after the window expires.
