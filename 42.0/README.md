# Dynamic Evolution Z - MP Fixes

Companion mod for [Dynamic Evolution Z](https://steamcommunity.com/sharedfiles/filedetails/?id=3676814360). Fixes the one remaining bug that breaks DZ follower movement on dedicated servers, adds idle follower re-pathing, and provides admin chat commands.

Does not modify any DZ files. All fixes are applied at runtime via function wrapping. Safe to add or remove at any time.

> **DZ Update Note**: DZ has natively fixed 17 of the original 18 bugs across multiple updates — including ambient wander (fix 10), cohesion drift (fix 17), and thump release (fix 18) which now use `tryPathToLocation` natively. The sole remaining fix is 11 (leader follower direction) where `applyFollowerBoost` still uses only dead `setLastHeardSound`. Kill data from the companion mod's previous per-player tracking file is automatically migrated into DZ's native file on first startup.

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
| `/dz forcesave` | Force save to ModData + DZ backup |
| `/dz diag` | Show server diagnostics (fix status, state values) |

## Active Server-Side Fixes (dz_persistence.lua)

### 11. Dead setLastHeardSound in leader influence (ESSENTIAL)
DZ's `ApplyLeaderInfluence` calls `applyFollowerBoost` (DZ_Leader:4998-5107) which uses `trySetLastHeardSound` for all 5 follower types: HUNTER (line 5044), FRENZY (lines 5055/5057), SHADOW (lines 5067/5072), SPLIT (line 5082), HIVE (line 5103). **Zero `tryPathToLocation` calls in this function.** This fix is the sole source of working follower pathing.

New STALKER/HOWLER leader types are safe: `ApplyLeaderInfluence` returns early at DZ_Leader:5130-5140 for these types, delegating to dedicated `runStalkerLeader`/`runHowlerLeader` functions that use native `tryPathToLocation`. Neither sets `leaderInfluence=true` via `applyFollowerBoost`, so our grid traversal finds no influenced followers and takes no action.

Fix: wraps `ApplyLeaderInfluence` to iterate influenced followers via grid traversal and call `pathToLocationF` with coordinates per leader type:
- **HUNTER/HIVE**: leader's target position
- **FRENZY/SHADOW**: leader's target position, or leader's own position as fallback
- **SPLIT**: 3-way flanking offset computed from follower position hash (replicates DZ's `computeSplitPoint` using `LeaderSplitFlankDistance`)
- **Migrating**: blended migration target (replicates DZ's blend formula from `applyMigrationDirective`)

Includes four layers of deduplication/protection:
- **Path dedup**: floor-based tile comparison via `needsNewPath()` against cached `fDZ._cmdLastPathX/Y/Z` skips redundant `pathToLocationF` when the computed target tile is unchanged.
- **FRENZY/SPLIT path preservation**: DZ's `applyFollowerBoost` calls `tryResetPath` on FRENZY (line 5059) and SPLIT (line 5093) followers, clearing their A* path (`path2=nil`). Since our replacement `pathToLocationF` is async, the zombie would stop dead until the new path arrives. Fix: saves `path2` references before calling the original, restores them after — the zombie keeps walking its old path until A* delivers the new one.
- **Multi-leader dedup**: when two leaders have overlapping radii, both iterate the same followers. Without dedup, a farther leader could override the closer leader's path, causing twitching. Fix: per-pulse `{zombieId → distSq}` tracking ensures only the closest leader's direction takes effect, mirroring DZ's `canLeaderClaimFollowerForPulse` (DZ_Leader:2778-2803).
- **Stutter prevention**: `pathToLocationF` always fires (keeping the A* target current), but animation variables (`bPathfind`/`bMoving`) are only set when the zombie is idle (`getPath2() == nil`). Walking zombies are already in PathFindState — `pathToLocationF` updates the target via `setData`, and `pfb2.update()` resubmits A* next frame while `updateWhileRunningPathfind` keeps the zombie moving.

### Idle follower re-path via OnZombieUpdate
The 3-second leader pulse paths followers to the player's position at pulse time. When the player moves, the zombie arrives at the stale position in 1-2s, completes its A* path, exits PathFindState, and goes idle waiting up to 3 seconds for the next pulse. Visible as stop-wait-repath stuttering at 5-7 tile distance.

Fix: registers `OnZombieUpdate` (fires per-frame per-zombie on the auth-owning client where DZ runs). Throttled to 300ms per zombie via `_cmdIdleCheckMs`. When an influenced follower has no active path (`path2 == nil`), immediately re-paths toward `zombie:getTarget()` — the player's CURRENT position. Includes a 2-tile proximity skip and clears the `needsNewPath` cache so the next pulse isn't deduped. Worst-case idle time drops from 3000ms to ~300ms.

Works independently of DZ's `CoreBatchProcessingEnabled` (default: true). DZ's batch processing replaces DZ's own `OnZombieUpdate` handler, but PZ engine fires the `OnZombieUpdate` event per-frame per-zombie regardless. Our handler is registered independently.

### Admin debug access
DZ's debug system requires the sandbox `EnableDebugMode` setting, and `DZ_Core` resets both `DebugEnabled` and `DebugEnabledOverride` during init. Fix: sets `DynamicZ.DebugEnabledOverride = true` — this is the highest priority in `IsDebugEnabled()`'s check chain (DZ_Debug.lua line 83-85) and survives DZ's init reset. The existing admin check in `canUseDebug` ensures only admins see the overlay.

### Kill data migration
On first startup after updating the companion mod, `migrateKillData()` reads `DZChatCommands_PlayerKills.ini` (the companion mod's previous per-player tracking file), merges any higher values into DZ's native `DynamicZ_PlayerKills.ini`, and triggers DZ's `SyncVanillaKillCounter` to update totals. This is a one-time operation — after migration, DZ's native kill tracking handles everything.

## Fixed Upstream (no longer in companion mod)

These fixes were removed because DZ addressed them natively:

| # | Bug | DZ Fix |
|---|-----|--------|
| 1 | ModData persistence loss on restart | `DZ_GlobalState` writes `DynamicZ_GlobalBackup.ini` natively |
| 2 | worldEvolution never computed on startup | `RecalculateWorldEvolution()` called in `OnGameStart` |
| 3 | getWorldAgeDays on wrong object | Uses `getWorldAgeDaysSinceBegin()` |
| 4 | OnGameStart unreliable on dedicated servers | `ensureStartupStateAvailable()` fallback in `OnEveryOneMinute` |
| 5 | EveryOneSecond doesn't exist | Simulated via `OnTick` with `getTimestampMs` / tick fallback |
| 6 | OnMidnight doesn't exist | Called from `OnEveryDays()` |
| 7 | getNumActiveZombies doesn't exist | `getNumActiveZombiesSafe()` with fallback |
| 8 | Dead setLastHeardSound in search-after-target-loss | `TryPathToLocation` natively (DZ_Evolution:723) |
| 9 | Dead setLastHeardSound in stage 4+ sense | `TryPathToLocation` natively (DZ_Evolution:810) |
| 10 | Dead setLastHeardSound in ambient wander | `tryAmbientPathWithFallback` natively (DZ_Leader:1446) |
| 12 | getWorldAgeDaysSafe fallback drops TimeSinceApo | Primary path now uses `getWorldAgeDaysSinceBegin` |
| 13 | LeaderPulseInterval defaults to 180 | Config now sets `LeaderPulseInterval = 3` |
| 14 | GetZombieDebugId is nil | `DZ_Debug` exports it (DZ_Debug:281) |
| 15 | DebugTrackTick on non-existent EveryOneSecond | Called from `OnTick` simulation |
| 16 | SyncVanillaKillCounter loses offline player kills | Native per-player file tracking |
| 17 | Dead setLastHeardSound in cohesion drift | `tryPathToLocation` + `tryPathToLocationFDirect` natively (DZ_Leader:3617-3619) with budget system |
| 18 | Dead setLastHeardSound in thump-release | `tryPathToLocation` natively in `reissueDirectiveAfterThumpRelease` (DZ_Leader:2425-2496) |

The companion mod's **Activity Pressure System** (`dz_pressure.lua`) was also removed in an earlier update — DZ now has a native `DZ_Pressure.lua` with full integration into evolution bonuses, leader seed multipliers, and migration scoring.

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

- **zombie.memory field**: PZ's Kahlua bridge only exposes Java methods, not instance fields. `IsoZombie.memory` (public int) is inaccessible from Lua. The memory buff in DZ's evolution system is effectively dead.

- **SPLIT dual bucket mismatch**: DZ has an internal inconsistency between `computeSplitPoint` (`(fx+fy*3)%3`) and `applyFollowerBoost` inline (`(fx+fy)%3`, line 5086). The companion mod replicates `computeSplitPoint` (the positioning function). This is a DZ-internal bug — the fix belongs upstream.

## Files

```
42.0/
  media/lua/
    server/DZChatCommands/
      dz_persistence.lua     # Fix 11 + idle repath + ForceSave/Diagnostics
    client/DZChatCommands/
      dz_chat.lua            # Chat command bridge (/dz <subcommand>)
      dz_debug_overlay_fix.lua  # Debug HUD overlay fixes
```

## Logging

All log output uses `[DZChatCommands]` prefix. Deduplication suppresses identical log lines within 60 seconds — changed messages print immediately, unchanged messages re-print after the window expires.
