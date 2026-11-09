# Zipper

This folder is the addon and the git repo. It lives in the Warcraft Forever install. The game loads this path, not a random worktree, unless that worktree is what `Interface/AddOns/Zipper` points at.

The README is the player page. `.context/todo.md` is the unfinished list. Do not start the next item on that list unless Tyler asks.

## Look up the API before you guess

WoW API lookup is the `wow-api` server in the repo-root `.mcp.json`. That file is the shared project config: Claude Code reads it, and Grok reads it too. Codex does not. Codex only loads `.codex/config.toml`, and Grok does not scan that. Do not add a `.grok/`, `.codex/`, or `.cursor/` copy of this server.

`mise` has to be on `PATH`. `mise exec` is what puts Node in front of `npx`. On this machine that is linuxbrew's mise. A user-level Grok `config.toml` entry named `wow-api` outranks `.mcp.json`, so leave the committed file as the portable definition and do not delete someone's global entry to "make the project file win."

Grok skips `.mcp.json` after the Claude import marker is set. If `wow-api` is missing in a Grok session and it is not in the user `config.toml` either, that marker is why.

The server's default flavor is live. This client is Forever: product `wowf`, interface 16001, flavor `forever`. Pass `flavor: "forever"` on every lookup. Call `detect_wow_install` or `resolve_flavor` when the install is unclear. Fetch the tool schema with `search_tool` before `use_tool`.

The generated API index is incomplete. `GetNumGroupMembers`, `GetNumSubgroupMembers`, `IsInGroup`, `IsInRaid`, and `GetRaidRosterInfo` are missing from the index and present in Blizzard's Forever Lua. `C_EncodingUtil.SerializeCBOR` and `SerializeJSON` exist on this client too. "No results" is not proof a function is absent. Search the Forever UI source before inventing a replacement or dropping an event.

`GetNumGroupMembers()` includes the player. `party1`–`party4` do not. `raid1`–`raidN` do.

## Do not touch

- Sibling addons in the parent `AddOns` folder: MapUtils, OneForAll, EllesmereUI, ForeverQuestTint. Read them. Do not edit them.
- OneForAll's dungeon window. It is not a pin API.
- Git config. For each commit set `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL` in the command environment. Author is Tyler R, `20718430+TylerR909@users.noreply.github.com`. `git commit --author` alone fails because the committer is still unset.
- Do not push, tag, or cut a release unless Tyler asks.
- Do not delete `WTF/Account/EVANICKI/91/Bellemae-Claire/SavedVariables/Zipper.lua`. That file is the pre-migration backup. Live journeys are the account file `WTF/Account/EVANICKI/SavedVariables/Zipper.lua`.
- Do not run the delete-journey dialog on real data. The confirm phrase is `gone forever`.

## Traps that already shipped bugs

- Register events at file scope. `RegisterEvent` inside `ADDON_LOADED` throws here. Never register `COMBAT_LOG_EVENT_UNFILTERED`. Kills come from `PARTY_KILL`.
- `RegisterForClicks` accepts `LeftButtonUp` and `RightButtonUp` only. A modifier name such as `Shift-RightButtonUp` errors, and the click script never attaches. Read Shift with `IsShiftKeyDown` inside the handler. A secret result means not shifted.
- Combat can return secret numbers and booleans. `type()` still reports `"number"`. Check `issecretvalue` before any compare or arithmetic. This hits speed, distance, and some unit flags. A tainted `if` falls through instead of taking the branch.
- `UnitDistanceSquared` does not work inside an instance. The 250-yard party check is `250 * 250`, the same cutoff as Blizzard's party frames. Indoors, matching zone text is the guard.
- World-map pins sit on `ScrollContainer.Child`. Size them in screen pixels divided by the canvas zoom, and leave the pin at `SetScale(1)`. Scaling the pin with the zoom slides it toward TOPLEFT.
- The world-map button exists only when `Krowi_WorldMapButtons-1.4` is loaded. That library owns the corner column. Do not add Zipper's own column. Anchoring against OneForAll loops.
- EllesmereUI is `RegisterSkin` only. There is no `ScrollBarsIn`. Call the skin inside `pcall`. A failed skin must still leave the panel usable.
- BugGrabber keeps old Zipper stack traces across reloads. Clear that sack before treating a listed error as a current bug.
- SavedVariables flush on logout and `/reload`, not continuously. A change is not on disk until one of those happens.

## Decisions that look like omissions

- `ZipperCharDB` is only the one-time copy of an old per-character save (`imported`). Journeys live in account-wide `ZipperDB.journeys`, keyed by player GUID.
- Tracks pack to a `Z3:` string on `PLAYER_LOGOUT`. The packer is in `DB.lua`. Do not vendor Archivist or split journals into a LoadOnDemand addon.
- `journey.with[guid]` stores join and leave times. `ZipperDB.people` stores the name, class, and first meeting, and only after a shared moment within about 250 yards or the same instance. Quest, kill, death, and instance totals are counted from the path when the replay asks. Do not store those totals again.
- A `GROUP` event is a join worth saving only when its extra includes `DB.GROUP_KEPT`. Older join pips do not mean that.
- Quest accept and turn-in pins use the trail window. Do not keep an unfinished accept on the map after that trail has faded.
- The walking line uses the logged-in character's current class from `UnitClass`, and the cache must refresh when the class file changes. Class is not stored on the journey. Mount, flight, and ghost keep their own colors.
- Lua is 5.1. No `//`, no `goto`, and `unpack` rather than `table.unpack`. A `local function` is invisible to earlier functions in the same file. Methods on `ns.DB` are callable once the file has loaded.
- A new `.lua` file does nothing until it is listed in `Zipper.toc`. Load order is Enums, Config, DB, GPS, Social, Map, MapUtilsShim, Replay, Zipper.

## Git

Commit as the work lands. The subject is the release note. Write a sentence a player can read. Do not switch to `feat:` or `fix:` prefixes unless Tyler asks.

When he asks for a release, tag an annotated `vX.Y.Z` that matches `## Version:` in `Zipper.toc` and let the BigWigs packager build the changelog from commits since the previous tag. Do not add `CHANGELOG.md`. The packager workflow is not in the repo yet.

This environment sometimes stages addon files as mode `100755`. They should be `644`. If Git is about to record the executable bit, `git add --chmod=-x` those paths first.

## Check

There is no test harness in the tree. `luajit -e 'assert(loadfile("File.lua"))'` syntax-checks a file. `Enums.lua` and `DB.lua` load under luajit as `loadfile(path)("Zipper", ns)` if `GetServerTime` is stubbed. Do not add a framework for a one-off check.
