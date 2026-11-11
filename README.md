# Zipper

[![Release](https://img.shields.io/github/v/release/TylerR909/Zipper)](https://github.com/TylerR909/Zipper/releases/latest) [![Check](https://img.shields.io/github/actions/workflow/status/TylerR909/Zipper/check.yml?branch=master&label=check)](https://github.com/TylerR909/Zipper/actions/workflows/check.yml) [![CurseForge](https://img.shields.io/curseforge/dt/1799002?label=CurseForge)](https://www.curseforge.com/wow/addons/zipper) [![License: MIT](https://img.shields.io/github/license/TylerR909/Zipper)](LICENSE)

*Zip around the map again.*

[Screencast From 2026-11-08 03-05-25.webm](https://github.com/user-attachments/assets/d6d97043-e956-4aa7-a77c-9362b85fc63c)

Zipper records your journey zipping around the map, so you can replay it later — by session, by level, or the whole road so far.

## What it tracks

Where you walked — the trail across zones, on foot, mounted, flying, or as a ghost. Along it, marks for the events that happened: kills, quest pickups and turn-ins, deaths, hearths and teleports, flight paths, mounts, campfires, trainers, portals, summons, and joins.

## Play it back

- Replay a session, a stretch of sessions, one level, a range of levels, or the whole journey.
- Up to 600× speed, with chapter skips so you can move through the day.
- **Level-up recap.** When you ding, Zipper prints how long that level took, where it started and ended, and the kills, quests, and deaths along the way — with a link that opens that level in the replay. `/zip ding` reprints it; `/zip ding 28` pulls any finished level.

## Who you walked with

- The first time you met someone is remembered once: the zone, their level, and which of your characters was there. A later alt can still say you met them in the Wetlands, on the hunter who was actually there.
- Time, quests, kills, and dungeons are counted for the character who was in the group. Someone you never did anything with stays off the list.
- About 250 yards counts. So does the same dungeon. Hover a player, or the route itself, and Zipper shows who was with you.

## Small on disk

About **7 KB per hour** of play. If 1–60 takes you about 10 days of game-time, expect roughly **1.6 MB** for that character. Journeys live on the account, so you can browse another character's route without logging into them. Zipper nudges you to `/reload` so the hours you just walked are written down. Deleting a character's journey asks you to type a phrase first.

## Open it

```
/zipper
/zip
/zip options
/zip status
/zip ding
/zip ding 28
```

Recording starts when you log in with Zipper enabled. Logout or `/reload` writes the journey.

## Works on

Warcraft Forever.
