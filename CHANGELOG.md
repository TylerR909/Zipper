# Changelog

## 1.0.0

First full release for Warcraft Forever.

### Added

- AddOnSkins support: the replay panel skins to match ElvUI when AddOnSkins is enabled.

### Fixed

- Remaining plain UI labels (chapter navigation, recording and locked markers, save sizes, and short durations) now go through localization.

## 0.1.6-beta

### Added

- Multi-character comparison and role tracking in Charts: compare journeys across characters, and see time spent by combat role.
- Inline delete buttons on the Replay sessions list (with a confirmation dialog for sessions that gained XP), plus a Session Cleanup window in Options that previews quiet, mostly idle, city-only, and short stops before removing them.
- Missing level data and XP gaps are flagged in the level replay list, noted beside the replay timeline clock, and marked with tall orange pips at missing-data seams on the scrubber.

### Changed

- The open session in the replay list is labeled Current instead of its start date.
- Mounted route segments draw as a thinner class-colored line instead of turning gold, and stay thin when zoomed in.
- The Zipper map-button legend automatically includes every map pip, and mount/dismount, flight start/end, and instance enter/leave no longer place map pips.
- Automatic quiet-stop compaction on login now covers all Global characters up to 15 minutes.

### Fixed

- Movement speed is recorded against base run speed so mounts and speed buffs report real speed instead of 100%, and older mounted segments hide their inaccurate speed readout.
- Kills and boss kills inside dungeons are counted reliably, and instance exits are recorded when leaving a dungeon.
- Group kills no longer unpack journey history into memory or cause hitches inside dungeons.
- Opening the world map during combat no longer blocks world map quest pins.
- Forever characters keep both their first and last names in the replay picker and Saved data list, and party members who share a first name no longer inherit each other's zone.

## 0.1.5-beta

### Added

- Crafting is its own activity: cast-bar tradeskill time is recorded for the Pauses chart, kept out of AFK and idle, and left off the map (no pips).

### Fixed

- Login, `/zip status`, party pruning, and party tooltips read packed history instead of unpacking every session into memory.
- Map redraws, idle replay stats, and path hover tips stop rebuilding work you are not looking at.
- Standing still inside short range no longer asks the map for a new position every second, and meal aura duration ticks stay quiet until a real buff change.

## 0.1.4-beta

### Added

- Charts, in the replay header, opens the window to the right. The session or level list fills the left side, the chart names sit beside the drawing, and closing Charts puts the playback controls back under the list. Shift-click a range and the chart covers that selection. Where time went is a pie of open world, dungeons, raids, and the other places you spent time. The other charts show how you moved, kills and turn-ins by place and by level, and pauses.
- Three more charts use that same selection. Grouped and solo splits kills per level. Elites and rares splits them again, and a rare elite is counted with the elites. Zones shows the time there, then the kills and turn-ins.
- Each level and Kills and turn-ins draw the two counts as separate bars, so a handful of turn-ins can fill its own scale. Group share fills one bar per level and splits it between grouped and solo. Solo and grouped puts solo on the left and grouped on the right, on one scale.
- Pauses can switch between the bars and a pie of those same times. A chart with more than one drawing shows that choice under its note.
- Where time went can stay a pie, or split that time by level as stacked bars or a share bar. How you moved can be bars or a pie. Elites and rares can show each level's share. Kills and turn-ins stays the grouped bars.
- `/zip search heart` lists characters you have played with. A single letter is too short, and chat shows at most 8.

### Changed

- Chart notes under the title are shorter. Where time went, Kills and turn-ins, Each level, and Zones leave that line blank.

### Fixed

- Chapter ticks stay on the playback layer, so changing the selection cannot draw them on top of a chart.
- Kills and turn-ins show the real counts for the selection. Where time went calls idle out as its own slice.
- A level played in more than one session stays inside that level. The pie clock matches the rows.
- Where time went keeps one total when several places share a level, and names those places on a legend.
- Elites and rares, and Grouped and solo, size each bar against the busiest row in the selection. A level of about 140 is no longer drawn on a scale of 1,000.
- Charts stays in the header while the chart window is open. The session list on the left stops widening once the text fits.
- Replay charts keep each bar on its row. Where time went is one pie for the whole selection and names the places that had no time. Travel, kills, turn-ins, levels, and pauses are labeled rows.
- Level routes in the replay list stay on one line. A route that does not fit is clipped at the edge of the list instead of wrapping onto the next row.
- Opening Zipper options no longer pauses to re-pack the journey while it measures how big each character's save is.

## 0.1.3-beta

### Added

- Milestone Summaries (on by default) print a range recap in chat at level 6, 10, and every 10 levels after that.
- The world-map Zipper button appears with Zipper alone; Krowi_WorldMapButtons-1.4 is embedded so the button no longer needs Questie or RareScanner.

### Changed

- The replay mode button says All instead of Select all.
- The vanilla replay panel has more padding, a closed fill-to-border seam, and a clear lane under the chapter strip for scrubber pips.
- The level-up chat recap waits one second so the ding can finish first.
- The route draws above zone exploration overlays, so fogged outdoor maps no longer hide the path.

### Fixed

- Settings checkboxes load from saved data the first time you open Zipper options.
- Multi-session replay (All) skips logout gaps between sessions, so the playhead no longer freezes at a chapter while Pause stays lit and only the total time keeps ticking.
- Standing still no longer freezes the open session clock or stops replay at the last footstep; the recording end and playhead keep moving with live time after a hearth or AFK.

## 0.1.2-beta

### Added

- Saved data can mark a character Non-Global so its journey moves into that character's own save. Other characters load less, and cannot replay it until you make it Global again. Global stays the default.
- Non-Global alts stay in the replay picker as locked entries that point you at Saved data instead of opening an empty journey.

### Changed

- Saved data shows Global and Non-Global as two columns, with journey size on one line and a character list that stretches with the options window.
- The Saved data delete picker uses Blizzard's dropdown chrome.

### Fixed

- Moving a journey to Non-Global or back to Global recovers across a half-finished login, so an interrupted migrate does not strand the route.
- Private party names stay readable after other characters log out.
- The locked replay view no longer redraws the previous character's trail.

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
