# SkiaLemmings
A lightweight, multi-threaded Lemmings clone written in pure Delphi, utilizing Skia4Delphi for hardware-accelerated 2D rendering. 

This project serves as a technical proof-of-concept to demonstrate how classic 2D game mechanics (pathfinding, state machines, physics, and user interaction) can be efficiently handled in modern Delphi using a decoupled game-loop architecture.

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/LaMitaOne/SkiaLemmings)
          

 <img width="640" height="509" alt="Unbenannt" src="https://github.com/user-attachments/assets/5cc8efb6-02ec-404e-9740-b302dcd4c9de" />

DelphiSkia4Delphi
✨ Features (Current State)

While still a skeleton, the core gameplay loop is fully functional and demonstrates the engine's capabilities:

    Procedural Level Generation: Creates a randomized descending map featuring dirt, stone, steel borders, diggable walls, and bridgeable gaps.
    Multi-threaded Architecture: Physics, AI, and state updates run on a dedicated background thread (~60 FPS), completely decoupled from the UI drawing thread via TCriticalSection.
    Hardware-Accelerated Rendering: Uses TSkCustomControl for direct Skia Canvas access. Draws glowing stick-figure lemmings, parallax scrolling backgrounds, and particle effects with zero UI stutter.
    Core Mechanics Working:
        Lemmings spawn, walk, and automatically reverse direction when hitting walls.
        Gravity, falling, and fatal fall detection (splat).
        Dig Tool: Assign lemmings to dig through destructible terrain.
        Bomb Tool: Assign lemmings to explode, destroying a 3x3 tile radius.
        Bridge Tool: Click-and-drag to draw sloped bridge geometries.
    Visual Feedback: Parallax cloud layers, animated lemming limbs, pulsating exit portal, and particle bursts for digging/explosions.

🚧 Status & Roadmap

This is currently a playable skeleton. You can spawn lemmings, use tools, and interact with the procedural terrain, but it is not a complete game yet.
      
What's missing to make it a full game:

    Lemming count / saved counter UI overlay.
    Level completion/failure logic UI (restart, next level prompts).
    Refining the procedural generator to guarantee solvable levels.
    Additional Lemming skills (Climbing, Blocking, Umbrellas/Parachutes).
    Audio polishing (currently uses basic async WinAPI PlaySound).

🛠️ Technical Highlights

For Delphi developers, this repo is a good reference for:

    Avoiding the "Logic inside OnPaint" anti-pattern.
    Safely passing data between a TThread.CreateAnonymousThread and the main VCL/FMX thread.
    Using Skia Shaders, Path Builders, and Mask Filters for quick 2D visual effects.

⚙️ Getting Started
Prerequisites

    Delphi (RAD Studio 10.4 Sydney or newer recommended for best Skia4Delphi support).
    Skia4Delphi components installed.

      
Zipped exe and sample project included
