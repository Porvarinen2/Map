TESLES NPC OVERHAUL 2.0.3
=========================

Living squads for SCUM dedicated servers.

Up to 200 NPCs in squads (bandits, police patrols, hunters, militia, soldiers,
survivors, elite units, radiation teams...) live on the island all the time,
also where no player is. They walk the roads to towns, bunkers and hunting
spots, search houses, rest, fight zombies and each other, and turn into real
SCUM characters when a player comes within 1 km. Every NPC keeps its own
personality, skills and memories across server restarts.

A live map in your browser shows every squad, where it is going and why.

By Porvarinen - Discord: https://discord.gg/7TFs9VTzEs


REQUIREMENTS
------------
- A SCUM dedicated server on Windows (SCUMServer.exe).
- Nothing else: UE4SS (the Lua mod loader) ships with this package and is
  installed for you.


INSTALL
-------
1. Stop the SCUM server.
2. Extract this ZIP to its own folder (do NOT run it from inside the ZIP).
3. Run INSTALL.bat and answer Y.
4. Start the SCUM server.

That is all. INSTALL.bat finds the server (also in other Steam libraries),
installs UE4SS, installs the mod, and opens the live map at
http://127.0.0.1:8777/. The mod starts working 25 seconds after the server.

Options:
  INSTALL.bat -ServerRoot "D:\SCUM Server"   give the server folder yourself
  INSTALL.bat -DisableOtherMods              switch other UE4SS Lua mods off
  INSTALL.bat -SkipUE4SS                     leave your UE4SS as it is
  INSTALL.bat -NoMap                         no live map
  INSTALL.bat -Yes                           ask nothing

Your save game, database and server settings are never touched. Everything
that is replaced is backed up to <SCUM Server>\TeslesNPCOverhaul_Backups.

Note: the installer switches off the UE4SS engine hooks this mod does not
need (only EngineTick stays on); the default set crashed SCUM when a player
joined. A few other UE4SS mods need those hooks - UNINSTALL.bat restores the
original settings.


UPDATE
------
Extract the new version and run its INSTALL.bat. Your saved world, your
config.lua values, loadouts.lua and squads.lua are kept.


UNINSTALL
---------
Stop the server and run UNINSTALL.bat. It removes the mod, cleans mods.txt /
mods.json, restores the UE4SS settings, switches back on any mods the
installer switched off, stops the live map, and asks whether to remove UE4SS
too. A copy of the mod folder (with your saved world) stays in
<SCUM Server>\TeslesNPCOverhaul_Backups.


SETTINGS
--------
<SCUM Server>\SCUM\Binaries\Win64\ue4ss\Mods\TeslesNPCOverhaul\config.lua

  Language              "en" or "fi" (live map and messages)
  TargetNPCs            NPCs on the island (default 200, hard cap 250)
  EnableReplenish       wiped-out squads are replaced by new ones
  NPCDetectRangeM       how far an NPC sees a player (300 m, only in front)
  NPCViewAngleDeg       field of view to either side (45)
  NPCFireRangeM         when it opens fire (100 m)
  NPCScopedFireRangeM   with a scope (250 m)
  NPCCloseSenseM        notices a player behind it this close (5 m)
  GhostWeaponChance     0 = SCUM's own NPC weapons (default), 1 = weapons
                        themed per squad (hunters with bows and hunting
                        rifles, police with pistols and SMGs...)
  TopWeaponChance       how rare the top weapons are (0.2 = one in five)
  EnableBuildingSearch  squads go through the houses at the places they visit

Your own squad weapons: loadouts.lua (same folder, kept on updates).
Your own squad types:   squads.lua   (same folder, kept on updates).
Restart the server after changing any of these.


LIVE MAP
--------
http://127.0.0.1:8777/  (START_LIVEMAP.bat starts it again if you closed it)

- Click a squad to see its members, their skills, personality and memories.
- Right-click the map: copy a teleport command, spawn a squad at that spot,
  or remove a squad.
- The panel on the right shows what the mod has proven works on your server.

The map is the full 14k x 14k island map by TripplExN, cut into tiles: it
stays sharp down to single buildings. (The original image:
https://drive.google.com/file/d/1XqRochYxs4I5M1Lek0R-JWifUXXDwqVv/view)


IF NOTHING HAPPENS
------------------
1. The mod writes this file as soon as the server starts:
     ...\Mods\TeslesNPCOverhaul\output\boot.log
   If it is there, the mod runs; the live map shows what it is doing.
2. If boot.log is missing, UE4SS did not load the mod. Run tools\CHECK.bat -
   it reads UE4SS.log and tells you what to do.
3. Still stuck? Run DIAGNOSE.bat and share the zip it makes on the Discord.

Tools (in tools\):
  CHECK.bat           status of the mod and UE4SS on this server
  FIX_UE4SS_SCAN.bat  when UE4SS cannot find its byte patterns in a new
                      SCUM build (-Auto finds them in SCUMServer.exe)
  INSTALL_UE4SS.bat   reinstall UE4SS (-ZipFile to use a downloaded zip)
  UPDATE_UE4SS.bat    get the newest UE4SS pre-release from GitHub
  SETUP_HIRES_MAP.bat re-cut the map tiles from your own map image


GOOD TO KNOW
------------
- SCUM's own encounter NPCs near players are removed while the mod runs, so
  the island belongs to the mod's squads.
- The radiation zone (C0) belongs to the radiation teams and the south-west
  island (Z4) to the islanders; nobody else goes there and they never leave.
- NPCs keep the weapon SCUM gives them; the mod gives it a magazine with a
  few rounds and a condition that fits the squad.
- A game update can break UE4SS or the mod. Watch the Discord for updates.


CREDITS AND LICENSE
-------------------
Tesles NPC Overhaul (c) 2026 Porvarinen - MIT License (LICENSE.txt).
UE4SS by the UE4SS team - MIT License (ue4ss\UE4SS_LICENSE.txt).
Island map image stitched by TripplExN, shared for free use on r/SCUMgame.

Not affiliated with or endorsed by Gamepires or Jagex. SCUM is a trademark
of its owners. This is a free, non-commercial community tool; use it on your
own server at your own risk.
