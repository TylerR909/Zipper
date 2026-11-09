# Zipper

Working list. One feature at a time. Do not start the next item unless asked.

## Level cap

Not started. At max level there are no more dings, so time at the cap stays an open span. XP, renown, and item level are not a substitute yet. Decide what a "level" means once the character cannot gain another.

## Pie charts

Not started. Travel, combat, and AFK for a level.

## Party leftovers

Not started. Leave pips, instance names, a filter for the path while grouped with one person, and a friends list.

## Already built

### Death log

A death does not draw a straight line to the graveyard. A red square marks the corpse. The ghost walk back is its own stretch, grey by default, red if "Red ghost trail" is on. A resurrection onto a nearby player does not get a special path.

### Level-up ceremony

`PLAYER_LEVEL_UP` is stored on the journey and as a map mark. The replay list has a Levels view. One row per level, with the time from every session at that level added together. The level still in progress reads "so far". Click a level to replay it. Shift-click a second level for a range. Older sessions that crossed several levels without a recorded ding stay as one range.

### Party and social

A party is a time span per person on that character's journey. The name and the first meeting are saved only after a quest, a finished objective, a kill, a death, or an instance while they were within about 250 yards, or in the same instance. A different zone does not count. Stepping past 250 yards for under a minute and a half still does. A reload keeps that stretch if they are still here a few minutes later. Someone who joined during the reload starts when the roster is first readable.

It shows in the replay and on player tooltips. The stats list ends with a Company section of up to eight people for the sessions on screen. A kept join is a blue square on the route, and hovering that square lists who joined. Hovering the route or another marker adds who was with you then. Mousing over a player adds time together, what you did, and where you first met.

### Localization

Player text goes through AceLocale. English is the base. The other locale files stay empty for the packager.

### Dungeons, raids, and PvP

A dungeon or raid is a chapter on the scrubber. Replay skips from the door to the exit, and indoor points are not drawn on the world map. Battlegrounds and arenas stay on the path. Login compares the live instance with the last saved door and writes the missing enter or leave, including across a relog. OneForAll's dungeon window is not used.
