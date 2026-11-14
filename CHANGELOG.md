# Changelog

## 0.1.2-beta

### Added

- Saved data can mark a character Non-Global so its journey moves into that character's own save. Other characters load less, and cannot replay it until you make it Global again. Global stays the default.
- Non-Global alts stay in the replay picker as locked entries that point you at Saved data instead of opening an empty journey.

### Changed

- Saved data shows Global and Non-Global as two columns, with journey size on one line and a character list that stretches with the options window.
- The Saved data delete picker uses Blizzard's dropdown chrome.

### Fixed

- The world-map Zipper button appears with Zipper alone; Krowi_WorldMapButtons-1.4 is embedded so the button no longer needs Questie or RareScanner.
- Moving a journey to Non-Global or back to Global recovers across a half-finished login, so an interrupted migrate does not strand the route.
- Private party names stay readable after other characters log out.
- The locked replay view no longer redraws the previous character's trail.
- Multi-session replay (All) skips logout gaps between sessions, so the playhead no longer freezes at a chapter while Pause stays lit and only the total time keeps ticking.
- Standing still no longer freezes the open session clock or stops replay at the last footstep; the recording end and playhead keep moving with live time after a hearth or AFK.

## 0.1.1-beta

### Added

- Replay speed buttons show a short hover tip that turns 30x into wall time, like "1 hr = 2 min".
- Event markers on the map use small colored circles (and hollow rings for deaths and level-ups). Hover the Zipper map button for a legend of each pip.
- Fishing is its own activity: blue circle pins on the replay map, kept out of AFK and idle, and left out of the level-up recap.
- Idle stillness is recorded separately from AFK: recognized after 20 seconds standing still, backdated to when you stopped, and suppressed while eating, camping, fishing, in combat, or talking to an NPC.

### Changed

- Replay chapter controls use clean « ‹ › » marks on a gold-edged strip, with jump-to-start and jump-to-end beside previous and next chapter.
- The map-button legend is titled Zipper, and labels say Joined Party, Teleport, Quest pickup, and Quest turn-in.
- Elite kill pips try a gold ring around the red fill.
- While the playhead is fishing, the tip turns into the blue fishing mark (like idle replaces the tip); same-hole casts within about 10 yards share one pip.
- Switching characters in the picker refreshes the replay tip to that class color.

### Fixed

- Well-Rested no longer opens a sleeping-bag mark every time you pause between pulls; short false camp/sleep starts stay off the map so kill pips can show again.
- A replay trail length counts played time, so a logout overnight no longer wipes the route when you keep playing the same level.
- The finishing level-up ring sits above the class tip so it stays visible at the end of a level.
- Brief continent map samples no longer yank the replay camera out of the zone.
- Hearth keeps the cast-to-arrival route line, and hearth chapters read Hearthed - Zone.
- Selecting a session or level with the scrubber at the start shows the whole route on the map until you hit Play, which then clears it and redraws from the playhead.
- Clicking a session or level moves an already-open world map to the scrubber's place without opening the map if it was closed.
- Opening the world map with the route still on no longer jumps away from your zone view.
- Session and level replays always place a chapter marker at the start of the window, so leveling up and staying in the same zone no longer waits until a later zone change for the first chapter.
- Party meeting credit only counts members who are actually nearby, and a dungeon run counts with the party only after a boss dies.

## 0.1.0-beta

### Added

- Records your journey on the world map: where you walked, on foot, mounted, flying, or as a ghost.
- Marks kills, quest pickups and turn-ins, deaths, hearths and teleports, flight paths, campfires, trainers, portals, summons, and group joins along the route.
- Replay a session, a run of sessions, one level, a range of levels, or the whole journey, at up to 600× speed with chapter skips.
- A level-up recap in chat: how long the level took, where it started and ended, and the kills, quests, and deaths along the way, with a link to replay it. `/zip ding` reprints it, and `/zip ding 28` recaps any finished level.
- Remembers who you grouped with and where you first met, shown on player tooltips and when you hover the route.
- Journeys are saved on the account, so you can browse another character's route without logging into them.
- Deleting a character's journey asks you to type a phrase first.
