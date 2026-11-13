# Zipper

Conventions for anyone working on this addon, including a fork. Match the file you are editing. Do not invent a second architecture.

The README is the player page. `.context/todo.md` is the unfinished list. Do not start the next item on that list unless asked.

## Where changes have to land

The client loads one folder: `_forever_/Interface/AddOns/Zipper`. That directory is this repo. A git worktree is a different directory, so the game never runs it. Pointing the client at a worktree is not a test. SavedVariables live outside the repo, under `_forever_/WTF/`, and every copy the client loads writes the same account save.

Do one task at a time in the loaded addon folder. A new session in that folder is fine. A batch of worktrees is not a way to try several changes in game.

## Use the wow-api MCP

Before you name, add, or remove a WoW API, event, or widget, look it up with the `wow-api` server. The project file is the repo-root `.mcp.json`. Claude Code and Grok read it. Codex does not, and Grok does not read `.codex/config.toml`. Do not add a `.grok/`, `.codex/`, or `.cursor/` copy of this server.

`mise` must be on `PATH`. The server starts as `mise exec -- npx -y @nighthawk42/wow-api-mcp`. A user-level config entry of the same name outranks `.mcp.json`. Leave that entry alone. Grok skips `.mcp.json` after the Claude import marker is set. If the server is missing and it is not in the user config either, that marker is why. Install or enable it before guessing at the API.

This client is Warcraft Forever: product `wowf`, interface 16001, flavor `forever`. The server's default flavor is live. Pass `flavor: "forever"` on every lookup. Fetch the tool schema before calling a tool.

The generated index is incomplete. "No results" does not mean the function is absent. Search the Forever UI source next. `GetNumGroupMembers()` includes the player. `party1`–`party4` do not. `raid1`–`raidN` do.

Use the server again when a review or a bug touches client behavior. Do not carry an API fact from memory when the lookup is one call away.

## SavedVariables

Flush happens on logout and `/reload`, not continuously. The client renames `Zipper.lua` to `Zipper.lua.bak` and then writes a new `Zipper.lua`. The `.bak` is the only backup. The next logout or `/reload` overwrites it. If a flush looks wrong, copy the `.bak` back over `Zipper.lua` before anything else logs out or reloads. Do not reload again to see if it recovers.

From this addon folder the account file is `../../../WTF/Account/<Account>/SavedVariables/Zipper.lua`. The same directory holds `Zipper.lua.bak`. A character file is `../../../WTF/Account/<Account>/<Realm>/<Character>/SavedVariables/Zipper.lua`, again with a `.bak` beside it. From `_forever_/` those are `WTF/Account/<Account>/SavedVariables/Zipper.lua` and `WTF/Account/<Account>/<Realm>/<Character>/SavedVariables/Zipper.lua`.

The account file is the live journey store. A per-character file may still hold an older copy. Do not delete either, and do not delete a `.bak`. Do not run the delete-journey dialog against a real save. The confirm phrase is `gone forever`.

## Repo conventions

- Player-facing text goes through `ns.L`. Register the English key in `Locales/enUS.lua`. `NewLocale` returns a write-only proxy, and reading a key on it asserts, so `ns.L` is the table from `GetLocale`. The other locale files stay empty so the packager can fill them from CurseForge. Do not invent translations. Do not translate the confirm phrase `gone forever`.
- Lua is 5.1. No `//`, no `goto`, and `unpack` rather than `table.unpack`. A `local function` is invisible to earlier functions in the same file.
- A new `.lua` file does nothing until it is listed in `Zipper.toc`. Keep the existing load order.
- Do not edit other addons installed beside this one.
- Do not vendor Archivist or move journals into a LoadOnDemand addon. The packer is in `DB.lua`.
- Anything that can be counted from the path later is not stored again. `journey.with` is join and leave times. `ZipperDB.people` is identity and the first meeting, and only after a shared moment. A `GROUP` event counts as that only when its extra includes `DB.GROUP_KEPT`.
- Quest pins use the trail window. Do not keep an unfinished accept on the map after that trail has faded.
- The walking line uses the logged-in character's current class from `UnitClass`. Class is not stored on the journey.
- Combat can return secret numbers and booleans. `type()` still says `"number"`. Check `issecretvalue` before a compare or any arithmetic.
- Do not register `COMBAT_LOG_EVENT_UNFILTERED`. Kills come from `PARTY_KILL`.
- Do not edit git config. Do not invent an author. If the identity is unset in this checkout, set `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`, `GIT_COMMITTER_NAME`, and `GIT_COMMITTER_EMAIL` on the commit command to Tyler R, `20718430+TylerR909@users.noreply.github.com`. A fork uses the contributor's own identity, not that address.
- Commit as the work lands. Write the subject as a sentence a player can read. Subjects are not shipped. Do not switch to `feat:` or `fix:` prefixes unless asked.
- Do not push, tag, or cut a release unless asked. A release is an annotated tag `vX.Y.Z`. `Zipper.toc` keeps `## Version: @project-version@`; the packager fills that from the tag in the zip. `CHANGELOG.md` is hand-written and player-facing: no chores, CI, or refactors. Keep older `## <version>` sections for history. Before tagging, add a `## <version>` section matching the tag without the leading `v` (so tag `v0.1.2` needs `## 0.1.2`). The release workflow fails without one, and it ships only that section as the GitHub/CurseForge release notes.
- Addon files are mode `644`. If the environment marks them executable, `git add --chmod=-x` before committing. Do not record `100755`.

## Reports

Bugs and feature requests use the GitHub issue forms in `.github/ISSUE_TEMPLATE/`. Triage from what the reporter wrote. Do not ask them for SavedVariables, WTF paths, or a code trace. An empty error box means no error window appeared.

## Check

`luajit -e 'assert(loadfile("File.lua"))'` syntax-checks a file. `Enums.lua` and `DB.lua` load under luajit as `loadfile(path)("Zipper", ns)` if `GetServerTime` is stubbed. Do not add a framework for a one-off check.

If the check depends on a client API, use the wow-api server with flavor `forever` before you call the check done.
