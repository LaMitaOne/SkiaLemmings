# SkiaLemmings
A lightweight, multi-threaded Lemmings(Catlings), Worms, and Portal hybrid written in pure Delphi, utilizing Skia4Delphi for hardware-accelerated 2D rendering.   
    
What started as a classic Lemmings clone has evolved into a fast-paced Touch-Game: Save the Catlings (or Humans) by digging, building, and blowing up the terrain, while using Portal-guns, Bazookas, and Grab-tools to overcome obstacles and defeat cave monsters!    

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SkiaLemmings)   
  
<img width="1920" height="1080" alt="Unbenannt" src="https://github.com/user-attachments/assets/60292f5d-f9e4-476e-862a-d3a68481e835" />

              
Sample Video: https://www.youtube.com/watch?v=z7uKRacZKko   
    
✨ Features (v0.4 alpha)

The core gameplay loop is fully functional, featuring a massive upgrade in mechanics, UI, and visual feedback compared to v0.1:   
    
🐭 Classic Lemmings & Touch-Tools

     Procedural Level Generation: Creates randomized underground cave systems featuring dirt, stone, steel borders, diggable walls, deep caverns, and a grounded exit gate.
     Classic Lemming Skills: Dig (down), Mine (directional drag-to-aim), Bomb (explode), LemBridge (automatic staircase builder), Climber (scale walls), and Blocker (act as a solid wall).
     Worms-Style User Tools: 
         Bazooka: Freeze time, aim with the mouse, and fire a rocket to blast through terrain or enemies.
         Portal Tool: Shoot two portals (blue & orange) into the terrain. Lemmings and rockets are teleported instantly with zero collision blocking.
         Grab Tool: Pick up a Lemming with the mouse, move it over obstacles, and click again to drop it.
         Eraser: Delete a 3x3 area of terrain to clear a path.
         UserBridge: Draw a 1-block thick diagonal bridge directly with the mouse.
     Auto-Parachute: Falling Lemmings automatically deploy a parachute, preventing fall damage entirely.

🐉 Enemies & Dynamic Elements

     Cave Monsters: Deep caves are guarded by patrolling monsters. If a Lemming touches one, both explode in a burst of particles. Monsters can be killed with Bazookas, Bombs, or by dropping them into pits.
     Loot & Upgrades: Find glowing orbs in caves to gain extra Bazooka ammo, Eraser charges, or bonus Lemmings.   

🎮 Controls

The game supports both mouse interaction and keyboard shortcuts. Since it blends different genres, the controls vary depending on your currently selected tool.
Global Controls

     Mouse Wheel: Zoom in / out (centered on cursor).   
     Middle mouse button: While zoomed grab and pan the camera view  
     ESC or M: Toggle Pause Menu.
     C: Toggle between Cat and Human avatars.
     V: Switch texture modes (Normal Dirt / Synthwave).
     F: Cycle post-processing screen filters (None / Film Grain / Vignette).
     U: Toggle Unlimited Ammo mode.

Mouse & Tool Interactions

Select a tool from the bottom toolbar, then interact with the world:

     Classic Skills (Dig, Bomb, LemBridge, Climber, Blocker): 
         Left-Click directly on a Lemming to assign the skill.
     Mine (Directional):
         Left-Click & Drag on a Lemming to aim the mining direction. Release to start digging a tunnel in that specific vector.
     Bazooka:
         Left-Click on a Lemming to select it as the shooter. The game enters Aiming Mode.
         While Aiming, Move Mouse to aim (a trajectory preview is shown).
         Left-Click again to fire the rocket.
     Grab:
         Left-Click & Hold on a Lemming to pick it up. Move your mouse to carry it through the air or over walls.
         Release Left-Click to drop the Lemming (it will fall and parachute if high enough).
     Eraser: 
         Left-Click on the terrain to instantly delete tiles (creates a small explosion radius).
     UsrBridge (User Bridge):
         Left-Click & Drag from one point to another to draw a custom 1-block-thick diagonal bridge.
     Portal:
         Left-Click to place the Blue Portal.
         Left-Click again to place the Orange Portal. (Lemmings and Bazooka rockets can teleport between them).
         Left-Click a third time to clear both portals and start over.
     Unlimited / Pause: 
         Click this button in the bottom-right corner to toggle infinite ammo.

🎮 UI & Game Flow

     Drawn In-Game UI: No VCL/FMX objects used! The entire 2x6 button toolbar is drawn directly via Skia. The active tool is highlighted with a glowing Aqua border.
     Speed Control: Toggle between normal speed (1.0x) and slow-motion (0.5x) to plan complex actions without pausing.
     Unlimited Mode: A toggle button to give you infinite ammo for all tools (perfect for sandbox puzzle solving).
     Gate Zap Effect: Lemmings near the exit gate are magnetically sucked in. Upon reaching the center, they trigger a Zap/Blitz effect and are counted as "Saved".
     Level Progression: Complete a level by saving the required amount of Lemmings to trigger the "Level Complete" screen with a Points score, then automatically load the next random level.

⚙️ Technical & Visual Highlights

     Multi-threaded Architecture: Physics, AI, and state updates run on a dedicated background thread (~30-60 FPS), completely decoupled from the UI drawing thread via TCriticalSection.
     Cached Avatars & UI: Catlings, Humans, Parachutes, and the Toolbar are rendered once into ISkImage caches and drawn as blitting bitmaps for maximum performance.
     Hardware-Accelerated Rendering: Uses TSkCustomControl for direct Skia Canvas access. Includes parallax scrolling backgrounds, procedural textures (Nature & Cyberpunk modes), and post-processing filters (Sepia, Cuphead-style film grain).
     Optimized Terrain: Tile map rendering uses frustum culling and cached tile records to prevent memory leaks during mass explosions.

Latest Changes:    
   
v0.4:    
    
    -Fixed Climber and Bridging   
    -User Bridge now snaps to the ground automatically if placed near the surface, but can still be built freely in the air.   
    -Lemmings can now seamlessly walk up bridge stairs (up to 8px step height) without getting stuck or falling through.   
    -Bridge Builder now acts as a solid invisible wall for other Lemmings behind him. They instantly turn around and wait instead of falling off the edge.   
    -Bridge Builder stops building if he hits a ceiling or wall above/in front of him.   
    -Fixed direction detection: Climbers now correctly detect and climb walls on both their left and right sides.   
    -Fixed an endless loop bug where Climbers would bounce between 'Walking' and 'Climbing' states without moving up.   
    -Climbers now correctly pull themselves over the top edge of a wall.   
    -Fixed Tool Ammo captions not updating immediately after using a tool (e.g., Mine, User Bridge).   
    -"Unlimited" button no longer overwrites the currently selected tool. It simply toggles infinite ammo while keeping your last tool active.   
    -Added Middle Mouse Button (mbMiddle) support to grab and pan the camera view when zoomed in.   
    -Added Parallax background layers (Far/Near Mountains) for better depth perception.   
    -Parachute offset adjusted by 4px to prevent clipping into left-side walls.   
    -Added "11 - Tin Light.wav" sound effect for bridge building.   
    -The game now starts in a "Paused" state with a "Start Level" button in the center of the screen.    
    -Levels no longer auto-advance immediately. When a level is complete, a "Level Complete" overlay menu appears with a "Next Level" button.    

    
v0.3:    
     
    -Fixed Bazooka trajectory to perfectly match the aim prediction line; slightly reduced blast radius.
    -Reworked Exit Gate: Smaller (1/3), placed flush on the ground, and completely cleared of terrain above/sides.
    -Optimized Gate Magnet: Lemmings bypass collisions when sucked in to prevent getting stuck.
    -Fixed Lemming death on enemy contact.
    -Level now ends successfully when all Lemmings are either saved or dead.
    -Shifted Cat and Human avatars 4 pixels up for better tile alignment.
    -Added dynamic Screen Shake on explosions.
    -Lemmings are now drawn in front of the Exit Gate.
    -Added "MENU" button to the bottom-right of the toolbar.
    -Pause Menu now has clickable buttons (Resume, Reset Level, New Level).
    -Added dynamic ammo counters directly to all tool button texts (e.g., Dig x5, ∞ when unlimited).
    -Synced Tool button colors with their matching Loot upgrade colors.
    -Loot upgrades reworked: 11 tool-specific upgrades, strictly spawned in the air (never in terrain).
     "Unlimited" and "Menu" buttons recolored to neutral gray (UI controls, not upgrades).
    -Fixed camera zoom and positioning to eliminate black borders and wrong viewports.
     
     
🚧 Status & Roadmap

This is a highly playable sandbox/arcade prototype. 

What could be added in the future:

     Level select menu and persistent high-score saving.
     More enemy types (e.g., flying bats, ranged attackers).
     Background music integration.
     Mobile/Touch optimizations for Android/iOS deployment.     


🛠️ Getting Started
Prerequisites

     Delphi (RAD Studio 10.4 Sydney or newer recommended for best Skia4Delphi support).
     Skia4Delphi components installed.

Audio Assets

The game uses royalty-free sound effects. Place the audio files in:
Game Design Sound Effects - Pavs Music/
(Using royalty free audios from https://www.pavsmusic.com/free-sound-pack-kits/)

A zipped .exe and sample project are included in the repository for immediate testing. 
   
    
🎮 Skia4Delphi Games (each one file, no ext engine):    
   2D Platformer https://github.com/LaMitaOne/Skia_PlatformerGame    
   C&C style 2.5D isometric rts https://github.com/LaMitaOne/Skia-RTS-Game   
   Tetris clone https://github.com/LaMitaOne/Skiatris    
   2D side-scrolling space shooter https://github.com/LaMitaOne/SkiaStarPatrols    
   2.5D isometric cat game https://github.com/LaMitaOne/Skia-A-Cats-Life      
     
🎮 Game components FMX:    
   MRX Gamepad Core https://github.com/LaMitaOne/MRX-Gamepad-Core       

   
If you want to tip me a coffee.. :)   
    
<p align="center">
  <a href="https://www.paypal.com/donate/?hosted_button_id=RX5KTTMXW497Q">
    <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate with PayPal"/>
  </a>
</p>
        

