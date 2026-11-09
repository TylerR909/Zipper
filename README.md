# Zipper

*The long way, still on the map.*

You dinged in the wetlands, died to something embarrassing, and grouped with a priest whose name you will not remember next week. Zipper keeps the road and the moments on it, then plays them back on the world map: a dot, a line in your class color, and the marks that made the day worth keeping.

## On the map

- **Your color.** The walk is drawn in your class color. A druid leaves an orange line. Flight, a mount, and a ghost walk each look like what they were.
- **A trail, not a scribble.** The line is solid back to a point you choose, then fades. Set that glance on the map, and set it again while you replay.
- **Deaths stay put.** Zipper marks where you fell. It does not draw a straight line from the corpse to the graveyard. The walk back as a ghost is its own stretch, grey unless you ask for red.
- **The route can stay up.** Show it while you play, hide it when you want the map clean, and turn it on again without losing the day.

## Play it back

- **This session, the whole journey, or one level.** Shift-click a second level and Zipper plays the stretch between them, with how long each level took.
- **A real play button.** Speed sits in a row: 1×, 10×, 30×, 120×, 600×. Scrub the day, skip ahead, and hop the stops Zipper found along the way.
- **Dungeons and raids are chapters.** Replay steps from the door to the exit instead of dragging your dot around the continent. Battlegrounds and arenas stay on the path.
- **A recap under the play controls.** Time on foot, mounted, and in the air. Kills, quests, deaths, levels, and the people who were actually there.

## The marks

Pips follow the trail. When a moment scrolls past the length you set, it goes with the road. Zipper does not pin every unfinished quest to the map forever.

- **Kills** are red. An elite is a little larger.
- **Quests** are dark yellow when you pick them up, and a medium green when you turn them in.
- **Level-ups, deaths, hearths, summons, flights, and mounts** each get a mark where they happened.
- **A join** is a blue mark: who you picked up, and where.

## Who you walked with

- The first time you met someone is remembered once: the zone, their level, and which of your characters was there. A later alt can still say you met them in the Wetlands, on the hunter who was actually there.
- Time, quests, kills, and dungeons are counted for the character who was in the group. A stranger who never did anything with you is not saved.
- Across the zone does not count. About 250 yards does. So does the same dungeon. Stepping ahead of the group for a minute does not drop them.

## Small on disk

A long day stays a small save. You can open another character's journey without logging into them. Zipper will nudge you to `/reload` so the hours you just walked are written down, not only held in memory. Deleting a character's journey asks you to type a phrase first, so it is not a misclick.

## Open it

```
/zipper
/zip
/zipper config
/zipper status
```

`/zipper` opens the replay. `/zipper config` is the reminder, the trail, and what gets recorded. If your world map already has the corner button column, Zipper adds a button there:

- Left click shows or hides the route
- Right click opens the replay
- Shift+right click opens settings

Recording starts when you log in with Zipper enabled. Logout or `/reload` writes the journey.

## Works on

Warcraft Forever.

Drop the `Zipper` folder into `Interface/AddOns`, or clone [this repo](https://github.com/TylerR909/Zipper) there. If EllesmereUI is installed, Zipper takes its skin.
