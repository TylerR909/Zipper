# Changelog

## 0.1.0-beta

### Changed

- Replay chapter controls use the game's left/right page arrows, with jump-to-start and jump-to-end beside them, on a clearer gold-edged panel header.

### Fixed

- Selecting a session or level with the scrubber at the start shows the whole route on the map until you hit Play, which then clears it and redraws from the playhead.
- Clicking a session or level moves an already-open world map to the scrubber's place without opening the map if it was closed.
- Opening the world map with the route still on no longer jumps away from your zone view.
- Session and level replays always place a chapter marker at the start of the window, so leveling up and staying in the same zone no longer waits until a later zone change for the first chapter.

### Added

- Records your journey on the world map: where you walked, on foot, mounted, flying, or as a ghost.
- Marks kills, quest pickups and turn-ins, deaths, hearths and teleports, flight paths, campfires, fishing, trainers, portals, summons, and group joins along the route.
- Event markers on the map use small colored circles (and hollow rings for deaths and level-ups). Hover the Zipper map button for a legend of each pip.
- Fishing is its own activity: blue circle pins on the replay map, kept out of AFK and idle, and left out of the level-up recap.
- Idle stillness is recorded separately from AFK: recognized after 20 seconds standing still, backdated to when you stopped, and suppressed while eating, camping, fishing, in combat, or talking to an NPC.
- Replay a session, a run of sessions, one level, a range of levels, or the whole journey, at up to 600× speed with chapter skips.
- A level-up recap in chat: how long the level took, where it started and ended, and the kills, quests, and deaths along the way, with a link to replay it. `/zip ding` reprints it, and `/zip ding 28` recaps any finished level.
- Remembers who you grouped with and where you first met, shown on player tooltips and when you hover the route.
- Journeys are saved on the account, so you can browse another character's route without logging into them.
- Deleting a character's journey asks you to type a phrase first.
