Okay, I would like an addon to replay my travel history through my character's entire journey. I would love to be able to open up the tool and view a map and hit Play to see either my Session replay, or my entire character's replay (from the moment of installing the app). I think we can swing big and then reign it in. At a basic level it would just be fun to see/replay my movements as a dot on the map (with a line) but it'd also be fun to track kills, quest pickups, quest turn-ins, deaths, being summoned, hearthing, flight point travel, mounting/dismounting, afk time, time spent in dungeons/raids, and so on. We should be conscientious of the quantity of data this could produce, perhaps deduping/normalizing data where able. Instead of storing strings like "mounted" "dismounted" etc we should map it to small-byte enumerations like 0, 1, 2, 3 etc and remap them where it makes sense to for readable code. We'd want to build it in some way to isolate a "gps" data-collection module, and then one or more display modules. You should have access to a wow-api MCP server. Pause if not so I can fix that immediately. 

For the map portion of this, there are several sibling files we can draw inspiration from. MapUtils does a lot of drawing-on-map though it may have its own map assets we can't reuse. EllesmereUI is a massive addon that does reskin the ingame map, put quest markers, etc. There is a map out there called Routes https://github.com/Nevcairiel/Routes that draws lots of lines on maps if we need to draw inspiration. 

Not sure if we could reliably attempt to "recover" from simple reloads (versus logout/login) to keep one session longer-spanning. The PLAYER_READY or whatever the event in would fire each time someone just reloads. We could do some combination of login + check previous log and if it was in the last few minutes we could continue the session. I don't want to overengineer this. 

Might also be prudent to trigger an hourly `print(...)` saying "Zipper has accumulated an hour of data which can be lost. Suggest `/reload` to save it forever."

-----

Simply dump every word I just typed out into a .md file then stop so I can swap models and check the MCP.
