{*******************************************************************************
  SkiaLemmings v 0.2 alpha
********************************************************************************
  A high-performance, thread-safe 2D Lemmings/Worms hybrid engine built entirely
  with Skia4Delphi. No external images or assets are used; all graphics, UI, and
  terrain textures are generated procedurally via code (Vector graphics & Shaders).

  Author:  Lara Miriam Tamy Reschke
  License: MIT

  PERFORMANCE & ARCHITECTURE UPDATES IN THIS VERSION:
  - Asset Caching: Avatars (Cats/Humans), UI Toolbars, and Textures are rendered
    once into ISkImage/ISkShader caches at startup and blitted, drastically
    reducing garbage collection and draw-call overhead.
  - Terrain Optimization: Tile maps use frustum culling (only visible tiles are
    drawn) and pre-allocated constant Records (CEmptyTile) to prevent memory
    leaks during mass explosions.
  - Thread-Safety: Game logic (Physics, AI, Tools) runs on a background thread
    with frame-drop protection (clamped DeltaSec), fully decoupled from the UI.
  - State Machine: Robust Lemming states (Walk, Fall, Dig, Mine, Climb, Bomb,
    Portal, Grab) with precise 12x20 pixel hitboxes for reliable user interaction.

  GAMEPLAY UPDATES IN THIS VERSION:
  - Touch & Worms Mechanics: Directional Mine aiming, Bazooka, Portal Gun (zero
    collision), and a Click-to-Grab tool for moving Lemmings manually.
  - Dynamic Combat: Cave monsters spawn in deep caverns and explode on contact
    with Lemmings. Can be destroyed with Bazookas or terrain manipulation.
  - UI & Flow: Fully drawn in-game UI with Aqua active-tool highlighting,
    slow-motion toggle (0.5x), Unlimited ammo mode, and magnet gate teleportation.
  - Auto-Parachute: Lemmings automatically deploy chutes when falling, negating
    fall damage.
*******************************************************************************}

unit SkiaLemmings;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.Generics.Collections, System.UITypes, System.SyncObjs, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Skia, Winapi.MMSystem, System.Skia;

// --- GAME CONSTANTS ---
// You can easily tweak these to change the feel of the game.
const
  TILE_SIZE = 32;               // Size of one map tile in pixels
  GRAVITY = 30.0;               // How fast lemmings accelerate downwards
  LEMMING_SPEED = 1.5;          // Horizontal walking speed
  MAX_FALL_SPEED = 10.0;        // Terminal velocity (currently auto-parachute limits this)
  INITIAL_MAX_LEMMINGS = 10;    // How many lemmings need to be saved

type
  // --- ENUMS ---
  TTileType = (ttEmpty, ttDirt, ttStone, ttSteel, ttBridge, ttBlocker);
  TLemmingState = (lsWalking, lsFalling, lsDigging, lsBombing, lsBridging, lsClimbing, lsBlocking, lsGrabbed, lsMiningDir, lsSaved);
  TToolType = (ttNone, ttDig, ttMine, ttBomb, ttLemBridge, ttClimber, ttBlockerTool,
               ttBazooka, ttEraser, ttUserBridge, ttPortal, ttGrab, ttUnlimited, ttSpeed);
  TGameState = (gsPlaying, gsDead, gsWin, gsAiming);

  // --- RECORDS ---
  // Using plain records for game entities is fast and cache-friendly.
  TTile = record
    TileType: TTileType;
    Solid: Boolean;
    DigTime: Single; // Time required to destroy this tile. -1 = indestructible
  end;

  TLemming = record
    Pos: TPointF;
    Vel: TPointF;
    Width, Height: Single;
    State: TLemmingState;
    Dir: Integer; // 1 = Right, -1 = Left
    DigTimer, BombTimer: Single;
    FallDistance: Single;
    Alive: Boolean;
    AnimPhase: Single;
    BridgeStep: Integer;
    IsClimber: Boolean;
    GrabOffset: TPointF;  // Offset from mouse cursor when grabbed
    MineDir: TPointF;     // Direction vector for directional mining
  end;

  TParticle = record
    Pos, Vel: TPointF;
    Life: Single;
    Color: TAlphaColor;
    Size: Single;
  end;

  TLoot = record
    Pos: TPointF;
    Kind: Integer; // 0=More Lemmings, 1=Bazooka Ammo, 2=Eraser Ammo
    Collected: Boolean;
    Phase: Single;
  end;

  TBazooka = record
    Pos, Vel: TPointF;
    Active: Boolean;
  end;

  TPortal = record
    Pos: TPointF;
    Active: Boolean;
  end;

  TGate = record
    Pos: TPointF;
    Width, Height: Single;
    Phase: Single; // For pulsing animation
  end;

  TSpawnPoint = record
    Pos: TPointF;
    Timer: Single;
    Spawned: Integer;
  end;

  TEnemy = record
    Pos, Vel: TPointF;
    Width, Height: Single;
    Phase: Single;
    Alive: Boolean;
  end;

  // --- MAIN COMPONENT ---
  TSkiaLemmings = class(TSkCustomControl)
  private
    // Threading & State
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection; // Prevents data races between logic and rendering
    FGameState: TGameState;
    FWinTime: Single;
    FMenuActive: Boolean;

    // Game Stats
    FScore, FPoints, FLevel: Integer;
    FMaxLemmings: Integer;
    FGameSpeed: Single; // For slow-motion effects

    // Map & Camera
    FTiles: TArray<TTile>;
    FMapCols, FMapRows: Integer;
    FGate: TGate;
    FSpawnPoint: TSpawnPoint;
    FCameraX, FCameraY: Single;
    FZoom: Single;
    FViewOffsetX, FViewOffsetY: Single;
    FMouseScreen: TPointF;

    // Entities
    FLemmings: TList<TLemming>;
    FParticles: TList<TParticle>;
    FLoot: TList<TLoot>;
    FBazookas: TList<TBazooka>;
    FEnemies: TList<TEnemy>;
    FPortals: array[0..1] of TPortal;

    // Tools & Ammo
    FActiveTool: TToolType;
    FUnlimited: Boolean;
    FBazookaAmmo, FEraserAmmo, FBridgeAmmo, FPortalAmmo, FGrabAmmo: Integer;

    // Input States
    FAimLemmingIndex: Integer;
    FAimStart, FAimEnd: TPointF;
    FIsDrawingBridge: Boolean;
    FTouchStart, FTouchEnd: TPointF;
    FGrabbedLemming: Integer;
    FIsAimingMine: Boolean;
    FMineLemmingIndex: Integer;

    // Cached Skia Assets (Procedurally generated)
    FToolbarImg: ISkImage;
    FCatImg, FHumanImg, FParaImg: ISkImage;
    FGrassShader, FDirtShader, FStoneShader, FSteelShader: ISkShader;
    FGrainShader: ISkShader;
    FBgClouds: TArray<TPointF>;

    // Visual Settings
    FVisualMode: Integer; // 0=Normal, 1=Synthwave
    FFilterMode: Integer; // 0=None, 1=Grain, 2=Vignette
    FUseCatAvatar: Boolean;

    // --- Private Methods ---
    procedure PlayEffect(Effect: Integer);
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;

    // Generation
    procedure GenerateProceduralMap;
    procedure GenerateBackgroundElements;
    procedure InitProceduralTextures;
    procedure RenderToolbarCache;
    procedure RenderAvatarCache;

    // Logic Updates
    procedure CheckGateCollisions;
    procedure CheckLootCollisions;
    procedure CheckEnemyCollisions;
    procedure UpdateLemmings(DeltaSec: Double);
    procedure UpdateBazookas(DeltaSec: Double);
    procedure UpdateEnemies(DeltaSec: Double);
    procedure UpdateParticles(DeltaTime: Single);

    // Actions
    procedure KillLemming(var L: TLemming);
    procedure SpawnExplosion(const X, Y: Single; Color: TAlphaColor);
    procedure FireBazooka(const TargetX, TargetY: Single);
    procedure EraserAt(const X, Y: Single);
    procedure BuildBridge(const P1, P2: TPointF);

    // Rendering
    procedure DrawBackgrounds(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure DrawTileMap(const ACanvas: ISkCanvas);
    procedure DrawGate(const ACanvas: ISkCanvas);
    procedure DrawSpawnGate(const ACanvas: ISkCanvas);
    procedure DrawLoot(const ACanvas: ISkCanvas);
    procedure DrawBazookas(const ACanvas: ISkCanvas);
    procedure DrawPortals(const ACanvas: ISkCanvas);
    procedure DrawEnemies(const ACanvas: ISkCanvas);
    procedure DrawParticles(const ACanvas: ISkCanvas);
    procedure DrawMenu(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure DrawUI(const ACanvas: ISkCanvas);
    procedure DrawToolbar(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure DrawLemmings(const ACanvas: ISkCanvas);
    procedure DrawAimReticle(const ACanvas: ISkCanvas);
    procedure DrawBridgePreview(const ACanvas: ISkCanvas);
    procedure DrawMinePreview(const ACanvas: ISkCanvas);

    // Math & Camera
    procedure CalculateViewMetrics;
    function ScreenToWorld(const P: TPointF): TPointF;
    procedure ApplyZoom(NewZoom: Single);
    procedure ResetPortals;
    function PtDistance(const P1, P2: TPointF): Single;
  protected
    // Overridden FMX/Skia methods
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState); override;
    procedure Resize; override;
    procedure MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

implementation

// --- TILE CONSTANTS ---
// Pre-initialized records for quick tile placement.
const
  CEmptyTile: TTile = (TileType: ttEmpty; Solid: False; DigTime: 0);
  CBridgeTile: TTile = (TileType: ttBridge; Solid: True; DigTime: 1.0);
  CBlockerTile: TTile = (TileType: ttBlocker; Solid: True; DigTime: 999); // Blockers are solid to other lemmings

{ --- GLOBAL HELPER FUNCTIONS --- }
{ These functions convert pixel coordinates to grid coordinates and manipulate
  the terrain array directly. They are kept outside the class for speed. }

function IsSolidTile(const Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single; IgnoreBlocker: Boolean = False): Boolean;
var Col, Row: Integer; T: TTile;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  // Out of bounds is considered solid (invisible walls)
  if (Col < 0) or (Col >= Cols) or (Row < 0) or (Row >= Rows) then Exit(True);

  T := Tiles[Row * Cols + Col];
  if IgnoreBlocker and (T.TileType = ttBlocker) then Exit(False);
  Result := T.Solid;
end;

function GetTile(var Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single): TTile;
var Col, Row: Integer;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  if (Col < 0) or (Col >= Cols) or (Row < 0) or (Row >= Rows) then
  begin
    // Return an indestructible steel tile if out of bounds
    Result.TileType := ttSteel; Result.Solid := True; Result.DigTime := 0;
    Exit;
  end;
  Result := Tiles[Row * Cols + Col];
end;

procedure SetTile(var Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single; const NewTile: TTile);
var Col, Row: Integer;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  if (Col >= 0) and (Col < Cols) and (Row >= 0) and (Row < Rows) then
    Tiles[Row * Cols + Col] := NewTile;
end;

procedure ExplodeTerrain(var Tiles: TArray<TTile>; Cols, Rows: Integer; const X, Y, Radius: Single);
var C, R, CX, CY: Integer; Dist: Single;
begin
  CX := Trunc(X / TILE_SIZE); CY := Trunc(Y / TILE_SIZE);
  // Loop through a square bounding box around the explosion center
  for R := Max(0, CY - Trunc(Radius) - 1) to Min(Rows - 1, CY + Trunc(Radius) + 1) do
    for C := Max(0, CX - Trunc(Radius) - 1) to Min(Cols - 1, CX + Trunc(Radius) + 1) do
    begin
      Dist := Sqrt(Sqr(C - CX) + Sqr(R - CY));
      // If inside the circle radius, and not Steel, make it empty
      if Dist <= Radius then
        if Tiles[R * Cols + C].TileType <> ttSteel then
          Tiles[R * Cols + C] := CEmptyTile;
    end;
end;

function TSkiaLemmings.PtDistance(const P1, P2: TPointF): Single;
begin
  Result := Sqrt(Sqr(P1.X - P2.X) + Sqr(P1.Y - P2.Y));
end;

{ --- VIEW & CAMERA --- }
{ Handles the conversion between Screen Pixels and World Pixels, and zoom. }

procedure TSkiaLemmings.CalculateViewMetrics;
var MapWidth, MapHeight, ScreenW, ScreenH: Single;
begin
  MapWidth := FMapCols * TILE_SIZE;
  MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width;
  ScreenH := Height - 200; // Reserve 200px at bottom for UI
  if (ScreenW <= 0) or (ScreenH <= 0) or (MapWidth <= 0) or (MapHeight <= 0) then Exit;

  // Calculate scale to fit map on screen, apply zoom
  var BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  var ActualScale := BaseScale * FZoom;

  // Center the view
  FViewOffsetX := (ScreenW - (MapWidth * ActualScale)) / 2;
  FViewOffsetY := (ScreenH - (MapHeight * ActualScale)) / 2;
end;

function TSkiaLemmings.ScreenToWorld(const P: TPointF): TPointF;
var MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale: Single;
begin
  // Reverse the translation and scale applied during Draw to find world coordinates
  MapWidth := FMapCols * TILE_SIZE;
  MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width;
  ScreenH := Height - 200;
  BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  ActualScale := BaseScale * FZoom;

  Result.X := ((P.X - FViewOffsetX) / ActualScale) + FCameraX;
  Result.Y := ((P.Y - FViewOffsetY) / ActualScale) + FCameraY;
end;

procedure TSkiaLemmings.ApplyZoom(NewZoom: Single);
var OldWorld, NewWorld: TPointF;
begin
  NewZoom := EnsureRange(NewZoom, 1.0, 3.0);
  if NewZoom = FZoom then Exit;

  // Zoom towards the mouse cursor
  OldWorld := ScreenToWorld(FMouseScreen);
  FZoom := NewZoom;
  CalculateViewMetrics;
  NewWorld := ScreenToWorld(FMouseScreen);

  // Adjust camera so the world point under the cursor stays the same
  FCameraX := FCameraX - (NewWorld.X - OldWorld.X);
  FCameraY := FCameraY - (NewWorld.Y - OldWorld.Y);
end;

procedure TSkiaLemmings.ResetPortals;
begin
  FPortals[0].Active := False;
  FPortals[1].Active := False;
end;

{ --- PROCEDURAL TEXTURES & CACHING --- }
{ Instead of loading PNGs, we generate textures using Skia at runtime.
  This keeps the project lightweight and dependency-free. }

procedure TSkiaLemmings.InitProceduralTextures;
var LSurface: ISkSurface; LCanvas: ISkCanvas; LPaint: ISkPaint; I, VariantX: Integer;
begin
  Randomize;
  LPaint := TSkPaint.Create(TSkPaintStyle.Fill);
  LPaint.AntiAlias := True;

  if FVisualMode = 1 then // Synthwave Mode
  begin
    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas; LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := $FF111118;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      LPaint.StrokeWidth := 1.5; LPaint.Style := TSkPaintStyle.Stroke;
      if VariantX mod 2 = 0 then LPaint.Color := $FFFF00FF else LPaint.Color := $FF00FFFF;
      for I := 0 to 3 do
        LCanvas.DrawLine(PointF(VariantX * 32 + Random(32), Random(32)), PointF(VariantX * 32 + Random(32), Random(32)), LPaint);
    end;
    // In synthwave, everything uses the same shader
    FGrassShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.Repeat, TSkTileMode.Repeat);
    FDirtShader := FGrassShader; FStoneShader := FGrassShader; FSteelShader := FGrassShader;
  end
  else // Normal Mode
  begin
    // 1. Dirt Texture
    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas; LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Color := $FF5A3A1A; LPaint.Style := TSkPaintStyle.Fill;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      // Add random speckles for texture
      for I := 0 to 15 do
      begin
        LPaint.Color := $FF3A220A; LCanvas.DrawCircle(PointF(VariantX * 32 + Random(32), Random(32)), 1 + Random(2), LPaint);
        LPaint.Color := $FF8A6A4A; LCanvas.DrawCircle(PointF(VariantX * 32 + Random(32), Random(32)), 1, LPaint);
      end;
    end;
    FDirtShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.Repeat, TSkTileMode.Repeat);

    // 2. Stone Texture
    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas; LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := $FF3D3D5C;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      for I := 0 to 10 do
      begin
        LPaint.Color := $FF505080; LCanvas.DrawCircle(PointF(VariantX * 32 + Random(32), Random(32)), 1 + Random(3), LPaint);
      end;
      LPaint.StrokeWidth := 1; LPaint.Style := TSkPaintStyle.Stroke; LPaint.Color := $FF000000;
      for I := 0 to 2 do
        LCanvas.DrawLine(PointF(VariantX * 32 + Random(32), Random(32)), PointF(VariantX * 32 + Random(32), Random(32)), LPaint);
    end;
    FStoneShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.Repeat, TSkTileMode.Repeat);

    // 3. Steel Texture
    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas; LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := $FF666666;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      LPaint.Color := $FF888888; LCanvas.DrawRect(RectF(VariantX * 32 + 2, 2, (VariantX + 1) * 32 - 2, 30), LPaint);
      LPaint.StrokeWidth := 1; LPaint.Style := TSkPaintStyle.Stroke; LPaint.Color := $FF333333;
      // Draw rivets / cross marks
      LCanvas.DrawLine(PointF(VariantX * 32 + 16, 0), PointF(VariantX * 32 + 16, 32), LPaint);
      LCanvas.DrawLine(PointF(VariantX * 32, 16), PointF((VariantX + 1) * 32, 16), LPaint);
    end;
    FSteelShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.Repeat, TSkTileMode.Repeat);
  end;

  // 4. Film Grain Shader (for post-processing)
  LSurface := TSkSurface.MakeRaster(512, 512);
  LCanvas := LSurface.Canvas; LCanvas.Clear($FF000000);
  LPaint.Style := TSkPaintStyle.Fill;
  for I := 0 to 30000 do
  begin
    var LGray := Random(255);
    LPaint.Color := TAlphaColorF.Create(LGray, LGray, LGray, 80).ToAlphaColor;
    LCanvas.DrawPoint(PointF(Random(512), Random(512)), LPaint);
  end;
  FGrainShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.Repeat, TSkTileMode.Repeat);
end;

procedure TSkiaLemmings.RenderToolbarCache;
var LSurf: ISkSurface; LCanvas: ISkCanvas; LPaint: ISkPaint; LFont: TSkFont; BtnW, BtnH: Single; R: TRectF;
  // Helper to draw a button
  procedure DrawBtn(Index, Row: Integer; const Text: string; Color: TAlphaColor; IsActive: Boolean);
  begin
    R := RectF(Index * BtnW, Row * BtnH, (Index + 1) * BtnW, (Row + 1) * BtnH);
    LPaint.Style := TSkPaintStyle.Fill;
    if IsActive then LPaint.Color := $FF223344 else LPaint.Color := $FF111122;
    LCanvas.DrawRect(R, LPaint);

    // Highlight active tool
    if IsActive then
    begin
      LPaint.Style := TSkPaintStyle.Stroke; LPaint.StrokeWidth := 5; LPaint.Color := TAlphaColors.Aqua;
      LCanvas.DrawRect(R, LPaint);
    end;

    LPaint.Style := TSkPaintStyle.Stroke; LPaint.StrokeWidth := 2; LPaint.Color := Color;
    LCanvas.DrawRect(R, LPaint);

    LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := Color;
    LCanvas.DrawCircle(PointF(R.CenterPoint.X, R.CenterPoint.Y - 10), 8, LPaint);
    LPaint.Color := TAlphaColors.White;
    LCanvas.DrawSimpleText(Text, R.CenterPoint.X - 45, R.CenterPoint.Y + 25, LFont, LPaint);
  end;
begin
  if Width <= 0 then Exit;
  // Draw the whole toolbar to a single surface and cache it.
  // This is much faster than drawing buttons every frame.
  LSurf := TSkSurface.MakeRaster(Round(Width), 200);
  LCanvas := LSurf.Canvas; LCanvas.Clear($FF000000);
  LPaint := TSkPaint.Create; LPaint.AntiAlias := True;
  LFont := TSkFont.Create;
  try
    BtnW := Width / 6; BtnH := 100; // 6 columns, 2 rows
    DrawBtn(0, 0, 'Dig', $FFFF8800, FActiveTool = ttDig);
    DrawBtn(1, 0, 'Mine', $FFFF8800, FActiveTool = ttMine);
    DrawBtn(2, 0, 'Bomb', $FFFF8800, FActiveTool = ttBomb);
    DrawBtn(3, 0, 'LemBridge', $FFFF8800, FActiveTool = ttLemBridge);
    DrawBtn(4, 0, 'Climber', $FFFF8800, FActiveTool = ttClimber);
    DrawBtn(5, 0, 'Blocker', $FFFF8800, FActiveTool = ttBlockerTool);

    DrawBtn(0, 1, 'Bazooka', $FFAA00FF, FActiveTool = ttBazooka);
    DrawBtn(1, 1, 'Eraser', $FFAA00FF, FActiveTool = ttEraser);
    DrawBtn(2, 1, 'UsrBridge', $FFAA00FF, FActiveTool = ttUserBridge);
    DrawBtn(3, 1, 'Portal', $FFAA00FF, FActiveTool = ttPortal);
    DrawBtn(4, 1, 'Grab', $FFAA00FF, FActiveTool = ttGrab);
    if FUnlimited then
      DrawBtn(5, 1, 'UNL: ON', $FF00FF00, FActiveTool = ttUnlimited)
    else
      DrawBtn(5, 1, 'UNL: OFF', $FFAA00FF, FActiveTool = ttUnlimited);
  finally
    LFont.Free;
  end;
  FToolbarImg := LSurf.MakeImageSnapshot;
end;

procedure TSkiaLemmings.RenderAvatarCache;
var
  LSurf: ISkSurface; LCanvas: ISkCanvas; LPaint: ISkPaint; PB: ISkPathBuilder;
  BodyRect, HeadRect: TRectF;
begin
  // Draw Cat Avatar
  LSurf := TSkSurface.MakeRaster(32, 32);
  LCanvas := LSurf.Canvas; LCanvas.Clear($00000000);
  LPaint := TSkPaint.Create; LPaint.AntiAlias := True;
  LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := $FF333333;
  BodyRect := RectF(8, 10, 24, 22);
  LCanvas.DrawOval(BodyRect, LPaint);
  LPaint.Style := TSkPaintStyle.Stroke; LPaint.StrokeWidth := 2.5; LPaint.StrokeCap := TSkStrokeCap.Round;
  LCanvas.DrawLine(PointF(12, 22), PointF(12, 28), LPaint); // Legs
  LCanvas.DrawLine(PointF(20, 22), PointF(20, 28), LPaint);
  LPaint.Style := TSkPaintStyle.Fill;
  HeadRect := RectF(16, 4, 26, 14);
  LCanvas.DrawOval(HeadRect, LPaint);
  // Ears
  PB := TSkPathBuilder.Create;
  PB.MoveTo(17, 6); PB.LineTo(19, 0); PB.LineTo(21, 6);
  PB.MoveTo(23, 6); PB.LineTo(25, 0); PB.LineTo(27, 6);
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  // Tail
  LPaint.Style := TSkPaintStyle.Stroke;
  LCanvas.DrawLine(PointF(8, 16), PointF(2, 10), LPaint);
  // Eyes
  LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := TAlphaColors.Yellow;
  LCanvas.DrawCircle(PointF(19, 9), 1.5, LPaint);
  LCanvas.DrawCircle(PointF(23, 9), 1.5, LPaint);
  FCatImg := LSurf.MakeImageSnapshot;

  // Draw Human Avatar
  LSurf := TSkSurface.MakeRaster(32, 32);
  LCanvas := LSurf.Canvas; LCanvas.Clear($00000000);
  LPaint.Style := TSkPaintStyle.Stroke; LPaint.StrokeWidth := 2.5; LPaint.StrokeCap := TSkStrokeCap.Round;
  LPaint.Color := $FF2A2A2A;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(13, 20); PB.LineTo(13, 28); // Legs
  PB.MoveTo(19, 20); PB.LineTo(19, 28);
  PB.MoveTo(16, 12); PB.LineTo(16, 20); // Body
  PB.MoveTo(16, 14); PB.LineTo(11, 18); // Arms
  PB.MoveTo(16, 14); PB.LineTo(21, 18);
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  // Head
  LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := $FFD2B48C;
  LCanvas.DrawCircle(PointF(16, 8), 4.5, LPaint);
  LPaint.Color := TAlphaColors.Black;
  LCanvas.DrawCircle(PointF(18, 7), 1, LPaint); // Eye
  FHumanImg := LSurf.MakeImageSnapshot;

  // Draw Parachute
  LSurf := TSkSurface.MakeRaster(48, 48);
  LCanvas := LSurf.Canvas; LCanvas.Clear($00000000);
  LPaint.Style := TSkPaintStyle.Stroke; LPaint.StrokeWidth := 1.5; LPaint.Color := $FF444444;
  LCanvas.DrawLine(PointF(10, 18), PointF(16, 30), LPaint); // Strings
  LCanvas.DrawLine(PointF(38, 18), PointF(32, 30), LPaint);
  LPaint.Style := TSkPaintStyle.Fill; LPaint.Color := $FFE0E0E0; // Chute
  PB := TSkPathBuilder.Create;
  PB.MoveTo(4, 18);
  PB.QuadTo(24, -4, 44, 18);
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  LPaint.Style := TSkPaintStyle.Stroke; LPaint.Color := $FF886644; LPaint.StrokeWidth := 1;
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  FParaImg := LSurf.MakeImageSnapshot;
end;

{ --- LEVEL GENERATION --- }

procedure TSkiaLemmings.GenerateProceduralMap;
var C, R: Integer; DirtTile, StoneTile, SteelTile: TTile; Loot: TLoot; E: TEnemy;
begin
  // Define base tiles
  DirtTile.TileType := ttDirt;   DirtTile.Solid := True;   DirtTile.DigTime := 0.5;
  StoneTile.TileType := ttStone; StoneTile.Solid := True;  StoneTile.DigTime := 2.0;
  SteelTile.TileType := ttSteel; SteelTile.Solid := True;  SteelTile.DigTime := -1; // Indestructible

  // Fill map with dirt
  for R := 0 to FMapRows - 1 do
    for C := 0 to FMapCols - 1 do
      FTiles[R * FMapCols + C] := DirtTile;

  // Create borders
  for C := 0 to FMapCols - 1 do
  begin
    FTiles[(FMapRows - 1) * FMapCols + C] := SteelTile;
    FTiles[(FMapRows - 2) * FMapCols + C] := SteelTile;
  end;
  for R := 0 to FMapRows - 1 do
  begin
    FTiles[R * FMapCols + 0] := SteelTile; FTiles[R * FMapCols + 1] := SteelTile;
    FTiles[R * FMapCols + (FMapCols - 1)] := SteelTile; FTiles[R * FMapCols + (FMapCols - 2)] := SteelTile;
  end;

  // Clear top area for lemmings to walk
  for R := 0 to 3 do
    for C := 2 to FMapCols - 3 do
      FTiles[R * FMapCols + C] := CEmptyTile;

  // Carve random gaps on the surface
  var SurfaceY := 4; var SkipUntil := 0;
  for C := 2 to FMapCols - 3 do
  begin
    if C < SkipUntil then Continue;
    if (C > 10) and (C < FMapCols - 10) and (Random(12) = 0) then
    begin
      var GapLen := 2 + Random(3);
      for var G := 0 to GapLen - 1 do
        if (C + G) < FMapCols - 2 then
          for R := SurfaceY to SurfaceY + 2 do
            FTiles[R * FMapCols + C + G] := CEmptyTile;
      SkipUntil := C + GapLen + 2;
    end;
  end;

  FLoot.Clear;
  FEnemies.Clear;

  // Generate random caves underground
  for var I := 0 to 20 do
  begin
    var CaveX := 4 + Random(FMapCols - 8); var CaveY := 8 + Random(FMapRows - 12);
    var CaveW := 3 + Random(6); var CaveH := 2 + Random(4);
    for var Cy := 0 to CaveH do
      for var Cx := 0 to CaveW do
        if (CaveX + Cx < FMapCols - 2) and (CaveY + Cy < FMapRows - 3) then
          FTiles[(CaveY + Cy) * FMapCols + (CaveX + Cx)] := CEmptyTile;

    // Add loot to some caves
    if Random(2) = 0 then
    begin
      Loot.Pos := PointF((CaveX + CaveW/2) * TILE_SIZE, (CaveY + CaveH/2) * TILE_SIZE);
      Loot.Kind := Random(3); Loot.Collected := False; Loot.Phase := 0;
      FLoot.Add(Loot);
    end;

    // Add monsters to deep caves
    if (CaveY > 10) and (FEnemies.Count < 3) and (Random(2) = 0) then
    begin
      E.Pos := PointF((CaveX + 1) * TILE_SIZE, (CaveY + 1) * TILE_SIZE);
      E.Vel := PointF(15 + Random(10), 0);
      if Random(2) = 0 then E.Vel.X := -E.Vel.X; // Random direction
      E.Width := 24; E.Height := 24; E.Phase := Random(100); E.Alive := True;
      FEnemies.Add(E);
    end;
  end;

  // Add random stone walls on surface to act as obstacles
  for C := 2 to FMapCols - 3 do
  begin
    if (Random(8) = 0) then
    begin
      var WallH := 2 + Random(3);
      for var W := 0 to WallH do
        if (SurfaceY + W) < FMapRows - 3 then
          FTiles[(SurfaceY + W) * FMapCols + C] := StoneTile;
    end;
  end;

  // Create Exit Gate area
  var GateY := FMapRows - 4;
  for var ty := GateY - 3 to FMapRows - 3 do
    for var tx := FMapCols - 10 to FMapCols - 4 do
      FTiles[ty * FMapCols + tx] := CEmptyTile;

  // Ensure solid floor for exit
  for var tx := FMapCols - 10 to FMapCols - 4 do
    for var ty := FMapRows - 3 to FMapRows - 1 do
      FTiles[ty * FMapCols + tx] := StoneTile;

  FGate.Pos := PointF((FMapCols - 9) * TILE_SIZE, (GateY - 3) * TILE_SIZE);
  FGate.Width := 96; FGate.Height := 96; FGate.Phase := 0;

  // Set spawn point top-left
  FSpawnPoint.Pos := PointF(4 * TILE_SIZE, 2 * TILE_SIZE);
  FSpawnPoint.Timer := 0; FSpawnPoint.Spawned := 0;

  // Reset game state
  FScore := 0; FGameState := gsPlaying; FLemmings.Clear;
  FBazookaAmmo := 2; FEraserAmmo := 5; FBridgeAmmo := 3; FPortalAmmo := 2; FGrabAmmo := 3;
  ResetPortals;
  CalculateViewMetrics;
end;

procedure TSkiaLemmings.GenerateBackgroundElements;
var I: Integer;
begin
  SetLength(FBgClouds, 30);
  for I := 0 to High(FBgClouds) do FBgClouds[I] := PointF(Random(FMapCols * TILE_SIZE * 2), Random(300) + 20);
end;

{ --- GAME LOGIC --- }

procedure TSkiaLemmings.KillLemming(var L: TLemming);
begin
  L.Alive := False;
  SpawnExplosion(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2, TAlphaColors.Red);
  PlayEffect(3);
end;

procedure TSkiaLemmings.SpawnExplosion(const X, Y: Single; Color: TAlphaColor);
var I: Integer; P: TParticle;
begin
  for I := 0 to 15 do
  begin
    P.Pos := PointF(X, Y);
    P.Vel := PointF((Random - 0.5) * 400, (Random - 0.5) * 400 - 100);
    P.Life := 0.8; P.Color := Color; P.Size := 4 + Random * 4;
    FParticles.Add(P);
  end;
end;

procedure TSkiaLemmings.FireBazooka(const TargetX, TargetY: Single);
var L: TLemming; B: TBazooka; DX, DY, Len, Power: Single;
begin
  if FAimLemmingIndex = -1 then Exit;
  L := FLemmings[FAimLemmingIndex];

  // Calculate vector to target
  DX := TargetX - (L.Pos.X + L.Width/2);
  DY := TargetY - (L.Pos.Y + L.Height/2);
  Len := Sqrt(DX*DX + DY*DY);
  if Len = 0 then Len := 1;

  // Power is proportional to distance, capped at 1500
  Power := Min(1500, Len * 5);
  B.Pos := PointF(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2 - 10);
  B.Vel := PointF((DX/Len)*Power, (DY/Len)*Power);
  B.Active := True;
  FBazookas.Add(B);

  FGameState := gsPlaying;
  if not FUnlimited then Dec(FBazookaAmmo);
  RenderToolbarCache;
  PlayEffect(3);
end;

procedure TSkiaLemmings.EraserAt(const X, Y: Single);
begin
  ExplodeTerrain(FTiles, FMapCols, FMapRows, X, Y, 1.5);
  SpawnExplosion(X, Y, TAlphaColors.White);
  PlayEffect(1);
end;

procedure TSkiaLemmings.BuildBridge(const P1, P2: TPointF);
var DX, DY, Dist, StepX, StepY, CurX, CurY: Single; Steps, I: Integer;
begin
  DX := P2.X - P1.X; DY := P2.Y - P1.Y;
  Dist := Sqrt(DX*DX + DY*DY);
  if Dist > TILE_SIZE then
  begin
    // Calculate steps to place 1-block thick diagonal tiles
    Steps := Trunc(Dist / (TILE_SIZE * 0.5));
    StepX := DX / Steps;
    StepY := DY / Steps;
    CurX := P1.X; CurY := P1.Y;
    for I := 0 to Steps do
    begin
      // Only place if empty
      if not IsSolidTile(FTiles, FMapCols, FMapRows, CurX, CurY) then
        SetTile(FTiles, FMapCols, FMapRows, CurX, CurY, CBridgeTile);
      CurX := CurX + StepX;
      CurY := CurY + StepY;
    end;
    if not FUnlimited then Dec(FBridgeAmmo);
    PlayEffect(1);
  end;
end;

procedure TSkiaLemmings.UpdateLemmings(DeltaSec: Double);
var I: Integer; L: TLemming; T: TTile;
begin
  // Spawn lemmings over time
  if FSpawnPoint.Spawned < FMaxLemmings then
  begin
    FSpawnPoint.Timer := FSpawnPoint.Timer + DeltaSec;
    if FSpawnPoint.Timer > 0.8 then
    begin
      FSpawnPoint.Timer := 0;
      L.Pos := FSpawnPoint.Pos; L.Vel := PointF(0,0); L.Width := 16; L.Height := 24;
      L.State := lsFalling; L.Dir := 1; L.DigTimer := 0; L.BombTimer := 0; L.FallDistance := 0; L.Alive := True;
      L.AnimPhase := Random(10); L.BridgeStep := 0; L.IsClimber := False; L.MineDir := PointF(0,0);
      FLemmings.Add(L);
      Inc(FSpawnPoint.Spawned);
    end;
  end;

  // Loop backwards so we can safely delete dead lemmings
  for I := FLemmings.Count - 1 downto 0 do
  begin
    L := FLemmings[I];
    if not L.Alive then begin FLemmings.Delete(I); Continue; end;
    L.AnimPhase := L.AnimPhase + DeltaSec * 10;

    // --- GRAB STATE ---
    if L.State = lsGrabbed then
    begin
      var TargetPos := ScreenToWorld(FMouseScreen) - L.GrabOffset;
      // Prevent dropping through solid terrain while dragging
      if not IsSolidTile(FTiles, FMapCols, FMapRows, TargetPos.X, TargetPos.Y, True) then
        L.Pos := TargetPos;
      FLemmings[I] := L;
      Continue;
    end;

    // --- DIRECTIONAL MINING STATE ---
    if L.State = lsMiningDir then
    begin
      var Step := L.MineDir * 2.0;
      var NextPos := L.Pos + Step;
      T := GetTile(FTiles, FMapCols, FMapRows, NextPos.X + L.Width/2, NextPos.Y + L.Height/2);
      if T.Solid and (T.DigTime >= 0) and (T.TileType <> ttBlocker) then
        SetTile(FTiles, FMapCols, FMapRows, NextPos.X + L.Width/2, NextPos.Y + L.Height/2, CEmptyTile);
      L.Pos := NextPos;
      L.DigTimer := L.DigTimer - DeltaSec;
      if L.DigTimer <= 0 then L.State := lsWalking;
      FLemmings[I] := L;
      Continue;
    end;

    // --- STATE MACHINE ---
    case L.State of
      lsWalking:
      begin
        L.Vel.X := LEMMING_SPEED * L.Dir;
        L.Pos.X := L.Pos.X + L.Vel.X;

        // Check wall ahead
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir=1, L.Width, 0)), L.Pos.Y + L.Height - 2, True) then
        begin
          if L.IsClimber then
            L.State := lsClimbing
          else
          begin
            L.Dir := -L.Dir; L.Pos.X := L.Pos.X + (L.Dir * 2); // Turn around
          end;
        end;

        // Check floor
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 1, True) then
        begin
          L.Pos.Y := Trunc((L.Pos.Y + L.Height) / TILE_SIZE) * TILE_SIZE - L.Height;
          L.FallDistance := 0;
        end
        else L.State := lsFalling; // Walked off edge
      end;

      lsFalling:
      begin
        L.Vel.Y := L.Vel.Y + GRAVITY * DeltaSec;
        if L.Vel.Y > 4.0 then L.Vel.Y := 4.0; // Auto-Parachute limits fall speed

        L.Pos.Y := L.Pos.Y + L.Vel.Y * TILE_SIZE * DeltaSec;
        L.FallDistance := L.FallDistance + (L.Vel.Y * TILE_SIZE * DeltaSec);

        // Hit ground
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 1, True) then
        begin
          L.Pos.Y := Trunc((L.Pos.Y + L.Height) / TILE_SIZE) * TILE_SIZE - L.Height;
          L.State := lsWalking; L.Vel.Y := 0; L.FallDistance := 0;
        end;
      end;

      lsClimbing:
      begin
        L.Vel.Y := -LEMMING_SPEED;
        L.Pos.Y := L.Pos.Y - 1;
        // Snap to wall
        if L.Dir = 1 then L.Pos.X := Trunc((L.Pos.X + L.Width) / TILE_SIZE) * TILE_SIZE - L.Width - 1
        else L.Pos.X := Trunc(L.Pos.X / TILE_SIZE) * TILE_SIZE + 1;

        // Reached top?
        if not IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir=1, L.Width, 0)), L.Pos.Y + L.Height - 2, True) then
          L.State := lsWalking;
        // Hit ceiling?
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y - 2, True) then
          L.State := lsWalking;
      end;

      lsDigging: // Dig straight down
      begin
        L.Vel.X := 0;
        T := GetTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 2);
        if T.Solid and (T.DigTime >= 0) and (T.TileType <> ttBlocker) then
        begin
          L.DigTimer := L.DigTimer + DeltaSec;
          if L.DigTimer >= T.DigTime then
          begin
            SetTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 2, CEmptyTile);
            L.DigTimer := 0; L.Pos.Y := L.Pos.Y + 4; L.State := lsFalling;
          end;
        end
        else L.State := lsWalking;
      end;

      lsBombing:
      begin
        L.Vel.X := 0; L.BombTimer := L.BombTimer - DeltaSec;
        if L.BombTimer <= 0 then
        begin
          ExplodeTerrain(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2, 2.5);
          KillLemming(L);
        end;
      end;

      lsBridging: // Build diagonal ramp
      begin
        L.Vel.X := 0;
        L.DigTimer := L.DigTimer + DeltaSec;
        if L.DigTimer >= 0.5 then // Place block every 0.5s
        begin
          L.DigTimer := 0;
          var PlaceX := L.Pos.X + (ifthen(L.Dir=1, L.Width, -1));
          var PlaceY := L.Pos.Y + L.Height - 4;
          if not IsSolidTile(FTiles, FMapCols, FMapRows, PlaceX, PlaceY, True) then
          begin
            SetTile(FTiles, FMapCols, FMapRows, PlaceX, PlaceY, CBridgeTile);
            L.Pos.X := L.Pos.X + (L.Dir * 8); // Step forward
            L.Pos.Y := L.Pos.Y - 8; // Step up
            Inc(L.BridgeStep);
            if (L.BridgeStep >= 12) or IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y - 2, True) then
              L.State := lsWalking;
          end
          else L.State := lsWalking;
        end;
      end;

      lsBlocking:
      begin
        // Fall if floor disappears
        if not IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 1, True) then
          L.State := lsFalling;
      end;
    end;

    // --- PORTAL TELEPORTATION ---
    if FPortals[0].Active and FPortals[1].Active then
    begin
      var LC := PointF(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2);
      if PtDistance(LC, FPortals[0].Pos) < 16 then
      begin
        L.Pos := FPortals[1].Pos - PointF(L.Width/2, L.Height/2);
        L.Pos.Y := L.Pos.Y - 20; // Pop out and fall
        L.Vel.Y := 0;
      end
      else if PtDistance(LC, FPortals[1].Pos) < 16 then
      begin
        L.Pos := FPortals[0].Pos - PointF(L.Width/2, L.Height/2);
        L.Pos.Y := L.Pos.Y - 20;
        L.Vel.Y := 0;
      end;
    end;

    FLemmings[I] := L; // Write back to list
  end;
end;

procedure TSkiaLemmings.UpdateBazookas(DeltaSec: Double);
var I, J: Integer; B: TBazooka; E: TEnemy;
begin
  for I := FBazookas.Count - 1 downto 0 do
  begin
    B := FBazookas[I];
    if not B.Active then begin FBazookas.Delete(I); Continue; end;

    // Apply gravity
    B.Vel.Y := B.Vel.Y + 400 * DeltaSec;
    B.Pos := B.Pos + B.Vel * DeltaSec;

    // Portal logic for rockets
    if FPortals[0].Active and FPortals[1].Active then
    begin
      if PtDistance(B.Pos, FPortals[0].Pos) < 16 then B.Pos := FPortals[1].Pos - PointF(0, 20)
      else if PtDistance(B.Pos, FPortals[1].Pos) < 16 then B.Pos := FPortals[0].Pos - PointF(0, 20);
    end;

    var HitTerrain := IsSolidTile(FTiles, FMapCols, FMapRows, B.Pos.X, B.Pos.Y);
    var HitEnemy := False;

    // Check collision with enemies
    for J := 0 to FEnemies.Count - 1 do
    begin
      E := FEnemies[J];
      if E.Alive and (PtDistance(B.Pos, PointF(E.Pos.X + E.Width/2, E.Pos.Y + E.Height/2)) < 20) then
      begin
        HitEnemy := True;
        E.Alive := False;
        FEnemies[J] := E;
        Break;
      end;
    end;

    if HitTerrain or HitEnemy then
    begin
      ExplodeTerrain(FTiles, FMapCols, FMapRows, B.Pos.X, B.Pos.Y, 4.0);
      SpawnExplosion(B.Pos.X, B.Pos.Y, TAlphaColors.Orange);
      PlayEffect(3); B.Active := False;
    end
    else if (B.Pos.X < 0) or (B.Pos.X > FMapCols * TILE_SIZE) or (B.Pos.Y > FMapRows * TILE_SIZE) then
      B.Active := False; // Out of bounds

    FBazookas[I] := B;
  end;
end;

procedure TSkiaLemmings.UpdateEnemies(DeltaSec: Double);
var I: Integer; E: TEnemy;
begin
  for I := FEnemies.Count - 1 downto 0 do
  begin
    E := FEnemies[I];
    if not E.Alive then begin FEnemies.Delete(I); Continue; end;

    E.Phase := E.Phase + DeltaSec * 5;
    E.Pos.X := E.Pos.X + E.Vel.X * DeltaSec;
    E.Pos.Y := E.Pos.Y + 15 * DeltaSec; // Apply gravity

    // Floor collision
    if IsSolidTile(FTiles, FMapCols, FMapRows, E.Pos.X + E.Width / 2, E.Pos.Y + E.Height) then
    begin
      E.Pos.Y := Trunc((E.Pos.Y + E.Height) / TILE_SIZE) * TILE_SIZE - E.Height;
      // Wall collision -> reverse direction
      if IsSolidTile(FTiles, FMapCols, FMapRows, E.Pos.X + E.Width / 2 + Sign(E.Vel.X) * 10, E.Pos.Y + E.Height / 2) then
        E.Vel.X := -E.Vel.X;
    end;

    FEnemies[I] := E;
  end;
end;

procedure TSkiaLemmings.CheckGateCollisions;
var I: Integer; L: TLemming; R, R2, MagnetR: TRectF; Center: TPointF;
begin
  if FGameState <> gsPlaying then Exit;
  R2 := TRectF.Create(FGate.Pos.X, FGate.Pos.Y, FGate.Pos.X + FGate.Width, FGate.Pos.Y + FGate.Height);
  // Create a larger "magnet" zone around the gate
  MagnetR := TRectF.Create(FGate.Pos.X - TILE_SIZE*2, FGate.Pos.Y - TILE_SIZE*2, FGate.Pos.X + FGate.Width + TILE_SIZE*2, FGate.Pos.Y + FGate.Height + TILE_SIZE*2);
  Center := PointF(FGate.Pos.X + FGate.Width/2, FGate.Pos.Y + FGate.Height/2);

  for I := FLemmings.Count - 1 downto 0 do
  begin
    L := FLemmings[I];
    if not L.Alive then Continue;
    R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);

    // If inside the gate
    if R.IntersectsWith(R2) then
    begin
      // ZAP EFFECT
      SpawnExplosion(Center.X, Center.Y, TAlphaColors.Aqua);
      SpawnExplosion(Center.X, Center.Y, TAlphaColors.White);

      FLemmings.Delete(I); Inc(FScore); Inc(FPoints, 100 + Max(0, 60 - Trunc(FWinTime)));
      PlayEffect(4);
      if FScore >= FMaxLemmings then
      begin
        FGameState := gsWin; FWinTime := 3.0;
      end;
    end
    // If near the gate, get sucked in
    else if R.IntersectsWith(MagnetR) then
    begin
      var LC := PointF(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2);
      var Dir := Center - LC;
      var Len := Sqrt(Dir.X*Dir.X + Dir.Y*Dir.Y);
      if Len > 0 then
      begin
        L.Pos.X := L.Pos.X + (Dir.X / Len) * 4.0; // Pull speed
        L.Pos.Y := L.Pos.Y + (Dir.Y / Len) * 4.0;
      end;
      L.State := lsWalking; // Stop digging/falling, just walk in
      FLemmings[I] := L;
    end;
  end;
end;

procedure TSkiaLemmings.CheckLootCollisions;
var I, J: Integer; L: TLemming; Lo: TLoot; R, R2: TRectF;
begin
  for I := 0 to FLoot.Count - 1 do
  begin
    if FLoot[I].Collected then Continue;
    Lo := FLoot[I];
    R2 := TRectF.Create(Lo.Pos.X - 16, Lo.Pos.Y - 16, Lo.Pos.X + 16, Lo.Pos.Y + 16);
    for J := 0 to FLemmings.Count - 1 do
    begin
      L := FLemmings[J];
      if not L.Alive then Continue;
      R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);
      if R.IntersectsWith(R2) then
      begin
        Lo.Collected := True;
        case Lo.Kind of
          0: Inc(FMaxLemmings);      // Add a lemming to save
          1: Inc(FBazookaAmmo, 3);   // Bazooka rockets
          2: Inc(FEraserAmmo, 2);    // Erasers
        end;
        RenderToolbarCache;
        SpawnExplosion(Lo.Pos.X, Lo.Pos.Y, TAlphaColors.Gold);
        PlayEffect(4); Break;
      end;
    end;
    FLoot[I] := Lo;
  end;
end;

procedure TSkiaLemmings.CheckEnemyCollisions;
var I, J: Integer; L: TLemming; E: TEnemy; R, R2: TRectF;
begin
  for I := 0 to FEnemies.Count - 1 do
  begin
    E := FEnemies[I];
    if not E.Alive then Continue;
    R2 := TRectF.Create(E.Pos.X, E.Pos.Y, E.Pos.X + E.Width, E.Pos.Y + E.Height);
    for J := 0 to FLemmings.Count - 1 do
    begin
      L := FLemmings[J];
      if not L.Alive then Continue;
      R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);
      if R.IntersectsWith(R2) then
      begin
        KillLemming(L);
        E.Alive := False; // Enemy dies too
        FEnemies[I] := E;
        SpawnExplosion(E.Pos.X + E.Width/2, E.Pos.Y + E.Height/2, TAlphaColors.Fuchsia);
        Break;
      end;
    end;
  end;
end;

{ --- USER INPUT --- }

procedure TSkiaLemmings.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var WorldP: TPointF; L: TLemming; BestL, I: Integer; BestDist, Dist: Single; R: TRectF;
begin
  inherited;
  if FMenuActive then Exit;

  // --- TOOLBAR CLICKS ---
  if Y >= Height - 200 then
  begin
    var BtnW := Width / 6;
    if Y < Height - 100 then // Row 1
    begin
      if X < BtnW then FActiveTool := ttDig
      else if X < BtnW*2 then FActiveTool := ttMine
      else if X < BtnW*3 then FActiveTool := ttBomb
      else if X < BtnW*4 then FActiveTool := ttLemBridge
      else if X < BtnW*5 then FActiveTool := ttClimber
      else FActiveTool := ttBlockerTool;
    end
    else // Row 2
    begin
      if X < BtnW then FActiveTool := ttBazooka
      else if X < BtnW*2 then FActiveTool := ttEraser
      else if X < BtnW*3 then FActiveTool := ttUserBridge
      else if X < BtnW*4 then FActiveTool := ttPortal
      else if X < BtnW*5 then FActiveTool := ttGrab
      else begin
        // It's the UNLIMITED button (toggles state)
        FUnlimited := not FUnlimited;
        FActiveTool := ttUnlimited;
      end;
    end;
    RenderToolbarCache;
    Exit;
  end;

  // --- GAME WORLD CLICKS ---
  WorldP := ScreenToWorld(PointF(X, Y));

  // Drop grabbed lemming
  if (FActiveTool = ttGrab) and (FGrabbedLemming <> -1) then
  begin
    L := FLemmings[FGrabbedLemming];
    L.State := lsFalling;
    FLemmings[FGrabbedLemming] := L;
    FGrabbedLemming := -1;
    if not FUnlimited then Dec(FGrabAmmo);
    RenderToolbarCache;
    Exit;
  end;

  // Fire bazooka
  if FGameState = gsAiming then
  begin
    if FActiveTool = ttBazooka then FireBazooka(WorldP.X, WorldP.Y);
    Exit;
  end;

  // Tool Actions
  if FActiveTool = ttBazooka then
  begin
    if FUnlimited or (FBazookaAmmo > 0) then
    begin
      BestL := -1; BestDist := 9999;
      // Find closest lemming to click
      for I := 0 to FLemmings.Count - 1 do
      begin
        L := FLemmings[I];
        if not L.Alive then Continue;
        Dist := Sqrt(Sqr(L.Pos.X - WorldP.X) + Sqr(L.Pos.Y - WorldP.Y));
        if Dist < BestDist then
        begin
          BestDist := Dist; BestL := I;
        end;
      end;
      if BestL <> -1 then
      begin
        FAimLemmingIndex := BestL;
        FAimStart := PointF(FLemmings[BestL].Pos.X + 8, FLemmings[BestL].Pos.Y + 2);
        FAimEnd := WorldP;
        FGameState := gsAiming; // Switch to aiming state
      end;
    end;
  end
  else if FActiveTool = ttEraser then
  begin
    if FUnlimited or (FEraserAmmo > 0) then
    begin
      EraserAt(WorldP.X, WorldP.Y);
      if not FUnlimited then Dec(FEraserAmmo);
      RenderToolbarCache;
    end;
  end
  else if FActiveTool = ttUserBridge then
  begin
    if FUnlimited or (FBridgeAmmo > 0) then
    begin
      FIsDrawingBridge := True;
      FTouchStart := WorldP;
      FTouchEnd := WorldP;
    end;
  end
  else if FActiveTool = ttPortal then
  begin
    if FUnlimited or (FPortalAmmo > 0) then
    begin
      if not FPortals[0].Active then
      begin
        FPortals[0].Pos := WorldP;
        FPortals[0].Active := True;
        SpawnExplosion(WorldP.X, WorldP.Y, $FF0000FF);
      end
      else if not FPortals[1].Active then
      begin
        FPortals[1].Pos := WorldP;
        FPortals[1].Active := True;
        SpawnExplosion(WorldP.X, WorldP.Y, $FFFF8800);
        if not FUnlimited then Dec(FPortalAmmo);
        RenderToolbarCache;
      end
      else // Both active, reset and place new portal 1
      begin
        ResetPortals;
        SpawnExplosion(WorldP.X, WorldP.Y, TAlphaColors.White);
      end;
    end;
  end
  else if FActiveTool = ttGrab then
  begin
    if FUnlimited or (FGrabAmmo > 0) then
    begin
      R := RectF(WorldP.X - 15, WorldP.Y - 20, WorldP.X + 15, WorldP.Y + 20);
      for I := 0 to FLemmings.Count - 1 do
      begin
        L := FLemmings[I];
        if not L.Alive then Continue;
        if R.IntersectsWith(TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height)) then
        begin
          var LemToChange := FLemmings[I];
          LemToChange.State := lsGrabbed;
          LemToChange.GrabOffset := WorldP - LemToChange.Pos;
          FLemmings[I] := LemToChange;
          FGrabbedLemming := I;
          Break;
        end;
      end;
    end;
  end
  else if (FActiveTool in [ttDig, ttMine, ttBomb, ttLemBridge, ttClimber, ttBlockerTool]) then
  begin
    R := RectF(WorldP.X - 6, WorldP.Y - 10, WorldP.X + 6, WorldP.Y + 10);
    for I := 0 to FLemmings.Count - 1 do
    begin
      L := FLemmings[I];
      if not L.Alive then Continue;
      if R.IntersectsWith(TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height)) then
      begin
        var LemToChange := FLemmings[I];
        if FActiveTool = ttDig then LemToChange.State := lsDigging;

        if FActiveTool = ttMine then
        begin
          // Mine requires aiming a direction
          FIsAimingMine := True;
          FMineLemmingIndex := I;
          FTouchStart := PointF(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2);
          FTouchEnd := WorldP;
          Exit;
        end;

        if FActiveTool = ttBomb then
        begin
          LemToChange.State := lsBombing; LemToChange.BombTimer := 2.0;
        end;
        if FActiveTool = ttLemBridge then
        begin
          LemToChange.State := lsBridging; LemToChange.BridgeStep := 0;
        end;
        if FActiveTool = ttClimber then
        begin
          LemToChange.IsClimber := True;
          if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir=1, L.Width, 0)), L.Pos.Y + L.Height - 2, True) then
            LemToChange.State := lsClimbing;
        end;
        if FActiveTool = ttBlockerTool then
        begin
          LemToChange.State := lsBlocking;
          SetTile(FTiles, FMapCols, FMapRows, LemToChange.Pos.X + LemToChange.Width/2, LemToChange.Pos.Y + LemToChange.Height/2, CBlockerTile);
        end;
        FLemmings[I] := LemToChange;
        Break;
      end;
    end;
  end;
end;

procedure TSkiaLemmings.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  FMouseScreen := PointF(X, Y);
  // Update end points for dragging actions
  if (FGameState = gsAiming) or FIsDrawingBridge or FIsAimingMine then
  begin
    FTouchEnd := ScreenToWorld(FMouseScreen);
    if FGameState = gsAiming then FAimEnd := FTouchEnd;
  end;
end;

procedure TSkiaLemmings.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var DX, DY, Len: Single; L: TLemming;
begin
  inherited;
  // Finish drawing bridge
  if FIsDrawingBridge then
  begin
    FIsDrawingBridge := False;
    BuildBridge(FTouchStart, FTouchEnd);
    RenderToolbarCache;
  end;

  // Finish aiming mine
  if FIsAimingMine then
  begin
    FIsAimingMine := False;
    if FMineLemmingIndex <> -1 then
    begin
      DX := FTouchEnd.X - FTouchStart.X;
      DY := FTouchEnd.Y - FTouchStart.Y;
      Len := Sqrt(DX*DX + DY*DY);
      if Len > 5 then // If dragged enough
      begin
        L := FLemmings[FMineLemmingIndex];
        L.State := lsMiningDir;
        L.MineDir := PointF(DX/Len, DY/Len); // Normalize vector
        L.DigTimer := 3.0; // Mine for 3 seconds
        FLemmings[FMineLemmingIndex] := L;
      end;
    end;
    FMineLemmingIndex := -1;
  end;
end;

procedure TSkiaLemmings.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  inherited;
  if WheelDelta > 0 then ApplyZoom(FZoom * 1.1)
  else ApplyZoom(FZoom / 1.1);
  Handled := True;
end;

procedure TSkiaLemmings.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  inherited;
  if (Key = vkEscape) or (KeyChar = 'M') or (KeyChar = 'm') then
  begin
    if FGameState = gsAiming then FGameState := gsPlaying
    else FMenuActive := not FMenuActive;
    Exit;
  end;
  if FMenuActive then Exit;

  if (KeyChar = 'C') or (KeyChar = 'c') then FUseCatAvatar := not FUseCatAvatar;
  if (KeyChar = 'V') or (KeyChar = 'v') then
  begin
    FVisualMode := FVisualMode + 1; if FVisualMode > 1 then FVisualMode := 0;
    InitProceduralTextures; // Regenerate textures
  end;
  if (KeyChar = 'F') or (KeyChar = 'f') then
  begin
    FFilterMode := FFilterMode + 1; if FFilterMode > 2 then FFilterMode := 0;
  end;
  if (KeyChar = 'U') or (KeyChar = 'u') then
  begin
    FUnlimited := not FUnlimited;
    RenderToolbarCache;
  end;
end;

procedure TSkiaLemmings.Resize;
begin
  inherited;
  CalculateViewMetrics;
  RenderToolbarCache; // Toolbar needs to redraw for new width
end;

{ --- PHYSICS LOOP --- }

procedure TSkiaLemmings.UpdateParticles(DeltaTime: Single);
var I: Integer; P: TParticle;
begin
  for I := FParticles.Count - 1 downto 0 do
  begin
    P := FParticles[I];
    P.Pos.X := P.Pos.X + P.Vel.X * DeltaTime;
    P.Pos.Y := P.Pos.Y + P.Vel.Y * DeltaTime;
    P.Life := P.Life - (0.8 * DeltaTime);
    if P.Life <= 0 then FParticles.Delete(I) else FParticles[I] := P;
  end;
end;

procedure TSkiaLemmings.DoPhysicsUpdate(DeltaSec: Double);
begin
  if not FActive or FMenuActive or (FGameState = gsAiming) then Exit;

  // Apply slow motion multiplier
  DeltaSec := DeltaSec * FGameSpeed;

  if FGameState = gsWin then
  begin
    FWinTime := FWinTime - DeltaSec;
    if FWinTime <= 0 then
    begin
      Inc(FLevel); GenerateProceduralMap; GenerateBackgroundElements;
    end; Exit;
  end;

  // CRITICAL SECTION: Lock data so the render thread doesn't access it while we modify it.
  FLock.Acquire;
  try
    UpdateLemmings(DeltaSec);
    UpdateBazookas(DeltaSec);
    UpdateEnemies(DeltaSec);
    CheckGateCollisions;
    CheckLootCollisions;
    CheckEnemyCollisions;
    UpdateParticles(DeltaSec);
  finally
    FLock.Release;
  end;
end;

{ --- RENDERING --- }
{ All drawing happens here. Notice we check FLock before accessing game data. }

procedure TSkiaLemmings.DrawBackgrounds(const ACanvas: ISkCanvas; const ADest: TRectF);
var Paint: ISkPaint; Colors: TArray<TAlphaColor>; I: Integer; ParallaxX, CloudX, CloudY: Single;
begin
  // Gradient sky
  Colors := [$FF05050A, $FF0A0A12, $FF020205];
  Paint := TSkPaint.Create;
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, ADest.Height - 200), Colors, nil, TSkTileMode.Clamp);
  ACanvas.DrawPaint(Paint);

  // Parallax clouds
  ParallaxX := -FCameraX * 0.1 * FZoom;
  Paint.AntiAlias := True;
  Paint.MaskFilter := nil;

  for I := 0 to High(FBgClouds) do
  begin
    CloudX := (FBgClouds[I].X * FZoom) + ParallaxX;
    CloudY := FBgClouds[I].Y * FZoom;
    if CloudX < -200 then CloudX := CloudX + (FMapCols * TILE_SIZE * 2 * FZoom); // Wrap around
    Paint.Color := $FF1A1A2A;
    Paint.Alpha := 80;
    ACanvas.DrawCircle(PointF(CloudX, CloudY), 60 * FZoom, Paint);
  end;
end;

procedure TSkiaLemmings.DrawTileMap(const ACanvas: ISkCanvas);
var Paint, OutlinePaint: ISkPaint; TileRect: TRectF; C, R: Integer; VariantX: Single;
  MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale: Single;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  OutlinePaint := TSkPaint.Create(TSkPaintStyle.Stroke);
  OutlinePaint.StrokeWidth := 1.0; OutlinePaint.Color := $AA000000;

  // Only draw visible tiles (Culling)
  MapWidth := FMapCols * TILE_SIZE; MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width; ScreenH := Height - 200;
  BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  ActualScale := BaseScale * FZoom;

  var StartCol := Max(0, Trunc(FCameraX / TILE_SIZE));
  var EndCol := Min(FMapCols - 1, Trunc((FCameraX + ScreenW / ActualScale) / TILE_SIZE));
  var StartRow := Max(0, Trunc(FCameraY / TILE_SIZE));
  var EndRow := Min(FMapRows - 1, Trunc((FCameraY + ScreenH / ActualScale) / TILE_SIZE));

  for R := StartRow to EndRow do
    for C := StartCol to EndCol do
    begin
      if not FTiles[R * FMapCols + C].Solid then Continue;
      TileRect := TRectF.Create(C * TILE_SIZE, R * TILE_SIZE, (C + 1) * TILE_SIZE, (R + 1) * TILE_SIZE);

      var TargetShader: ISkShader := nil;
      case FTiles[R * FMapCols + C].TileType of
        ttDirt, ttBridge: TargetShader := FDirtShader;
        ttStone: TargetShader := FStoneShader;
        ttSteel: TargetShader := FSteelShader;
      end;

      if Assigned(TargetShader) then
      begin
        ACanvas.Save;
        try
          ACanvas.ClipRect(TileRect);
          // Add slight variation to tiles by shifting the shader source
          VariantX := ((C * 13 + R * 7) mod 8) * 32;
          ACanvas.Translate(C * TILE_SIZE - VariantX, R * TILE_SIZE);
          Paint.Shader := TargetShader;
          ACanvas.DrawRect(RectF(0, 0, 256, 32), Paint);
          Paint.Shader := nil;
        finally ACanvas.Restore; end;
      end;
      ACanvas.DrawRect(TileRect, OutlinePaint); // Black outline
    end;
end;

procedure TSkiaLemmings.DrawSpawnGate(const ACanvas: ISkCanvas);
var Paint: ISkPaint; Center: TPointF;
begin
  Paint := TSkPaint.Create; Paint.AntiAlias := True;
  Center := PointF(FSpawnPoint.Pos.X + 8, FSpawnPoint.Pos.Y - 10);
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 10.0); // Glow effect
  Paint.Color := $FF00FF00; Paint.Alpha := 150;
  ACanvas.DrawRect(RectF(Center.X - 12, Center.Y - 15, Center.X + 12, Center.Y + 15), Paint);
  Paint.Color := $FF050510;
  ACanvas.DrawRect(RectF(Center.X - 8, Center.Y - 10, Center.X + 8, Center.Y + 10), Paint);
end;

procedure TSkiaLemmings.DrawGate(const ACanvas: ISkCanvas);
var Paint: ISkPaint; Center: TPointF; PhaseOffset: Single;
begin
  Paint := TSkPaint.Create; Paint.AntiAlias := True;
  Center := PointF(FGate.Pos.X + FGate.Width / 2, FGate.Pos.Y + FGate.Height / 2);
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 25.0); // Big glow
  // Alternate colors based on phase
  Paint.Color := ifthen(Sin(FGate.Phase * 2) > 0, $FF00FFFF, $FFFF00FF); Paint.Alpha := 180;
  PhaseOffset := Sin(FGate.Phase) * 0.2;
  // Squeeze and stretch effect
  ACanvas.Save; ACanvas.Translate(Center.X, Center.Y); ACanvas.Scale(1.0 + PhaseOffset, 1.0 - PhaseOffset);
  ACanvas.DrawOval(TRectF.Create(-45, -70, 45, 70), Paint); ACanvas.Restore;
  // Dark center
  Paint.Color := $FF050510;
  ACanvas.DrawOval(TRectF.Create(Center.X - 25, Center.Y - 45, Center.X + 25, Center.Y + 45), Paint);
end;

procedure TSkiaLemmings.DrawLoot(const ACanvas: ISkCanvas);
var I: Integer; Lo: TLoot; Paint: ISkPaint;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill); Paint.AntiAlias := True;
  Paint.MaskFilter := nil;
  for I := 0 to FLoot.Count - 1 do
  begin
    Lo := FLoot[I];
    if Lo.Collected then Continue;
    Lo.Phase := Lo.Phase + 0.05;
    var Offset := Sin(Lo.Phase) * 5.0; // Floating effect
    case Lo.Kind of
      0: Paint.Color := $FF00FF00; // Green
      1: Paint.Color := $FFFF0000; // Red
      2: Paint.Color := $FFFFFFFF; // White
    end;
    ACanvas.DrawCircle(PointF(Lo.Pos.X, Lo.Pos.Y + Offset), 8, Paint);
    FLoot[I] := Lo;
  end;
end;

procedure TSkiaLemmings.DrawBazookas(const ACanvas: ISkCanvas);
var B: TBazooka; Paint: ISkPaint;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill); Paint.AntiAlias := True; Paint.Color := $FF222222;
  for B in FBazookas do
  begin
    if not B.Active then Continue;
    ACanvas.DrawCircle(B.Pos, 4, Paint);
    // Draw trail
    Paint.Color := $FFFF0000;
    ACanvas.DrawCircle(PointF(B.Pos.X - B.Vel.X*0.02, B.Pos.Y - B.Vel.Y*0.02), 2, Paint);
    Paint.Color := $FF222222;
  end;
end;

procedure TSkiaLemmings.DrawPortals(const ACanvas: ISkCanvas);
var Paint: ISkPaint; I: Integer;
begin
  Paint := TSkPaint.Create; Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 10.0);
  for I := 0 to 1 do
  begin
    if not FPortals[I].Active then Continue;
    if I = 0 then Paint.Color := $FF0000FF else Paint.Color := $FFFF8800;
    Paint.Alpha := 180;
    ACanvas.DrawOval(TRectF.Create(FPortals[I].Pos.X - 16, FPortals[I].Pos.Y - 24, FPortals[I].Pos.X + 16, FPortals[I].Pos.Y + 24), Paint);
  end;
end;

procedure TSkiaLemmings.DrawEnemies(const ACanvas: ISkCanvas);
var E: TEnemy; Paint, GlowPaint: ISkPaint; Center: TPointF; Offset: Single;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  GlowPaint := TSkPaint.Create(Paint);
  GlowPaint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0);
  GlowPaint.Color := TAlphaColors.Purple;
  for E in FEnemies do
  begin
    if not E.Alive then Continue;
    Center := PointF(E.Pos.X + E.Width / 2, E.Pos.Y + E.Height / 2);
    Offset := Sin(E.Phase) * 3.0; // Floating effect
    Paint.Color := TAlphaColors.Fuchsia;
    // Draw body
    ACanvas.DrawOval(TRectF.Create(Center.X - 14, Center.Y - 12 + Offset, Center.X + 14, Center.Y + 12 + Offset), GlowPaint);
    ACanvas.DrawOval(TRectF.Create(Center.X - 12, Center.Y - 10 + Offset, Center.X + 12, Center.Y + 10 + Offset), Paint);
    // Draw eyes
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawCircle(PointF(Center.X - 4, Center.Y - 2 + Offset), 3, Paint);
    ACanvas.DrawCircle(PointF(Center.X + 4, Center.Y - 2 + Offset), 3, Paint);
    Paint.Color := TAlphaColors.Black;
    ACanvas.DrawCircle(PointF(Center.X - 4, Center.Y - 2 + Offset), 1.5, Paint);
    ACanvas.DrawCircle(PointF(Center.X + 4, Center.Y - 2 + Offset), 1.5, Paint);
  end;
end;

procedure TSkiaLemmings.DrawAimReticle(const ACanvas: ISkCanvas);
var Paint: ISkPaint; PB: ISkPathBuilder; I: Integer; SimPos, SimVel: TPointF;
begin
  if FGameState <> gsAiming then Exit;
  Paint := TSkPaint.Create; Paint.AntiAlias := True;
  // Draw aim line
  Paint.Style := TSkPaintStyle.Stroke; Paint.StrokeWidth := 2; Paint.Color := $FFFF0000;
  PB := TSkPathBuilder.Create; PB.MoveTo(FAimStart.X, FAimStart.Y); PB.LineTo(FAimEnd.X, FAimEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);

  // Simulate trajectory for dotted line
  SimPos := FAimStart; SimVel := PointF(FAimEnd.X - FAimStart.X, FAimEnd.Y - FAimStart.Y);
  var Len := Sqrt(SimVel.X*SimVel.X + SimVel.Y*SimVel.Y);
  if Len > 0 then
  begin
    SimVel.X := (SimVel.X / Len) * Min(1500, Len * 5);
    SimVel.Y := (SimVel.Y / Len) * Min(1500, Len * 5);
  end;
  Paint.Color := $FFFFFFFF;
  for I := 0 to 30 do
  begin
    SimVel.Y := SimVel.Y + 400 * 0.05; // Apply gravity to simulation
    SimPos := SimPos + SimVel * 0.05;
    if I mod 2 = 0 then ACanvas.DrawCircle(SimPos, 2, Paint);
    if IsSolidTile(FTiles, FMapCols, FMapRows, SimPos.X, SimPos.Y) then Break;
  end;
  // Draw crosshair
  Paint.Style := TSkPaintStyle.Stroke; Paint.StrokeWidth := 2; Paint.Color := $FF00FF00;
  ACanvas.DrawCircle(FAimEnd, 15, Paint);
  ACanvas.DrawLine(PointF(FAimEnd.X - 20, FAimEnd.Y), PointF(FAimEnd.X + 20, FAimEnd.Y), Paint);
  ACanvas.DrawLine(PointF(FAimEnd.X, FAimEnd.Y - 20), PointF(FAimEnd.X, FAimEnd.Y + 20), Paint);
end;

procedure TSkiaLemmings.DrawBridgePreview(const ACanvas: ISkCanvas);
var Paint: ISkPaint; PB: ISkPathBuilder;
begin
  if not FIsDrawingBridge then Exit;
  Paint := TSkPaint.Create; Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Stroke; Paint.StrokeWidth := 3; Paint.Color := $FFDEB887;
  PB := TSkPathBuilder.Create; PB.MoveTo(FTouchStart.X, FTouchStart.Y); PB.LineTo(FTouchEnd.X, FTouchEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);
end;

procedure TSkiaLemmings.DrawMinePreview(const ACanvas: ISkCanvas);
var Paint: ISkPaint; PB: ISkPathBuilder;
begin
  if not FIsAimingMine then Exit;
  Paint := TSkPaint.Create; Paint.AntiAlias := True;
  // Draw arrow
  Paint.Style := TSkPaintStyle.Stroke; Paint.StrokeWidth := 3; Paint.Color := $FFFF0000;
  PB := TSkPathBuilder.Create; PB.MoveTo(FTouchStart.X, FTouchStart.Y); PB.LineTo(FTouchEnd.X, FTouchEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);
  // Arrow head
  var Ang := ArcTan2(FTouchEnd.Y - FTouchStart.Y, FTouchEnd.X - FTouchStart.X);
  PB.MoveTo(FTouchEnd.X, FTouchEnd.Y);
  PB.LineTo(FTouchEnd.X - 10 * Cos(Ang - 0.4), FTouchEnd.Y - 10 * Sin(Ang - 0.4));
  PB.MoveTo(FTouchEnd.X, FTouchEnd.Y);
  PB.LineTo(FTouchEnd.X - 10 * Cos(Ang + 0.4), FTouchEnd.Y - 10 * Sin(Ang + 0.4));
  ACanvas.DrawPath(PB.Snapshot, Paint);
end;

procedure TSkiaLemmings.DrawLemmings(const ACanvas: ISkCanvas);
var L: TLemming; Img: ISkImage; Bounce: Single; Paint: ISkPaint;
begin
  Paint := TSkPaint.Create;
  for L in FLemmings do
  begin
    if not L.Alive then Continue;

    if FUseCatAvatar then Img := FCatImg else Img := FHumanImg;
    if not Assigned(Img) then Continue;

    Bounce := 0;
    if L.State = lsWalking then Bounce := Abs(Sin(L.AnimPhase * 2)) * 1.5;

    ACanvas.Save;
    try
      ACanvas.Translate(L.Pos.X, L.Pos.Y - Bounce);
      // Flip sprite if moving left
      if L.Dir = -1 then
      begin
        ACanvas.Scale(-1, 1);
        ACanvas.Translate(-L.Width, 0);
      end;
      ACanvas.DrawImage(Img, 0, 0, Paint);
    finally
      ACanvas.Restore;
    end;

    // Draw parachute if falling fast
    if (L.State = lsFalling) and (L.Vel.Y > 2.0) and Assigned(FParaImg) then
      ACanvas.DrawImage(FParaImg, L.Pos.X - 8, L.Pos.Y - 20, Paint);

    // Bomb indicator
    if L.State = lsBombing then
    begin
      Paint.Style := TSkPaintStyle.Fill;
      Paint.Color := TAlphaColors.Red;
      ACanvas.DrawCircle(L.Pos.X + L.Width/2, L.Pos.Y - 4, 3, Paint);
    end;
  end;
end;

procedure TSkiaLemmings.DrawParticles(const ACanvas: ISkCanvas);
var P: TParticle; Paint: ISkPaint; AlphaVal: Integer;
begin
  if FParticles.Count = 0 then Exit;
  Paint := TSkPaint.Create(TSkPaintStyle.Fill); Paint.AntiAlias := True;
  Paint.MaskFilter := nil;
  for P in FParticles do
  begin
    Paint.Color := P.Color;
    AlphaVal := Round(P.Life * 180);
    if AlphaVal > 255 then AlphaVal := 255;
    if AlphaVal < 0 then AlphaVal := 0;
    Paint.Alpha := AlphaVal;
    ACanvas.DrawCircle(P.Pos, P.Size * P.Life, Paint);
  end;
end;

procedure TSkiaLemmings.DrawToolbar(const ACanvas: ISkCanvas; const ADest: TRectF);
var Paint: ISkPaint;
begin
  // Draw cached toolbar image
  if Assigned(FToolbarImg) then
  begin
    Paint := TSkPaint.Create;
    ACanvas.DrawImage(FToolbarImg, 0, ADest.Height - 200, Paint);
  end;
end;

procedure TSkiaLemmings.DrawUI(const ACanvas: ISkCanvas);
var Font: TSkFont; Paint: ISkPaint; Txt: string;
begin
  // Draw top-left stats text
  Txt := 'Saved: ' + IntToStr(FScore) + '/' + IntToStr(FMaxLemmings) + ' | Level: ' + IntToStr(FLevel) + ' | Points: ' + IntToStr(FPoints);
  Txt := Txt + ' | Zoom: ' + FloatToStrF(FZoom, ffFixed, 2, 1) + 'x';
  if FGameSpeed < 1.0 then Txt := Txt + ' [SLOW-MO]';
  if FGameState = gsAiming then Txt := Txt + ' [AIMING - Click to fire!]';
  if FUnlimited then Txt := Txt + ' [UNLIMITED]';
  if FUseCatAvatar then Txt := Txt + ' [CAT]' else Txt := Txt + ' [HUMAN]';

  Font := TSkFont.Create;
  try
    Paint := TSkPaint.Create; Paint.Style := TSkPaintStyle.Fill; Paint.AntiAlias := True;
    // Draw shadow
    Paint.Color := TAlphaColors.Black; Paint.Alpha := 150;
    ACanvas.DrawSimpleText(Txt, 12, 32, Font, Paint);
    // Draw text
    Paint.Color := TAlphaColors.Yellow; Paint.Alpha := 255;
    ACanvas.DrawSimpleText(Txt, 10, 30, Font, Paint);
  finally
    Font.Free;
  end;
end;

procedure TSkiaLemmings.DrawMenu(const ACanvas: ISkCanvas; const ADest: TRectF);
var Paint: ISkPaint; Font: TSkFont; Rect: TRectF; CenterX, CenterY: Single;
begin
  Paint := TSkPaint.Create; Paint.Color := $AA000000; ACanvas.DrawPaint(Paint);
  CenterX := ADest.Width / 2; CenterY := ADest.Height / 2;
  Rect := TRectF.Create(CenterX - 150, CenterY - 120, CenterX + 150, CenterY + 120);
  Paint.Color := $FF333344; Paint.AntiAlias := True; ACanvas.DrawRoundRect(Rect, 20, 20, Paint);
  Paint.Style := TSkPaintStyle.Stroke; Paint.StrokeWidth := 3; Paint.Color := $FFFFFFFF;
  ACanvas.DrawRoundRect(Rect, 20, 20, Paint);
  Font := TSkFont.Create;
  try
    Paint := TSkPaint.Create(TSkPaintStyle.Fill); Paint.AntiAlias := True; Paint.Color := TAlphaColors.White;
    ACanvas.DrawSimpleText('PAUSED', CenterX - 70, CenterY - 70, Font, Paint);
    Paint.Color := TAlphaColors.Yellow;
    ACanvas.DrawSimpleText('ESC - Resume', CenterX - 65, CenterY - 20, Font, Paint);
    ACanvas.DrawSimpleText('C - Toggle Cat/Human', CenterX - 95, CenterY + 10, Font, Paint);
    ACanvas.DrawSimpleText('V - Textures', CenterX - 60, CenterY + 40, Font, Paint);
    ACanvas.DrawSimpleText('U - Unlimited', CenterX - 60, CenterY + 70, Font, Paint);
  finally
    Font.Free;
  end;
end;

procedure TSkiaLemmings.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale: Single;
begin
  DrawBackgrounds(ACanvas, ADest);

  // Calculate camera transform
  MapWidth := FMapCols * TILE_SIZE; MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width; ScreenH := Height - 200;
  BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  ActualScale := BaseScale * FZoom;

  ACanvas.Save;
  // Apply Camera transformations
  ACanvas.Translate(FViewOffsetX, FViewOffsetY);
  ACanvas.Scale(ActualScale, ActualScale);
  ACanvas.Translate(-FCameraX, -FCameraY);

  // LOCK: Prevent logic thread from changing lists while we draw them
  FLock.Acquire;
  try
    DrawTileMap(ACanvas);
    DrawSpawnGate(ACanvas);
    DrawLoot(ACanvas);
    DrawGate(ACanvas);
    DrawPortals(ACanvas);
    DrawLemmings(ACanvas);
    DrawBazookas(ACanvas);
    DrawEnemies(ACanvas);
    if FGameState = gsAiming then DrawAimReticle(ACanvas);
    if FIsDrawingBridge then DrawBridgePreview(ACanvas);
    if FIsAimingMine then DrawMinePreview(ACanvas);
    DrawParticles(ACanvas);
    FGate.Phase := FGate.Phase + 0.05; // Animate gate
  finally
    FLock.Release;
    ACanvas.Restore; // Restore canvas to screen space for UI
  end;

  // Draw UI on top
  DrawToolbar(ACanvas, ADest);
  DrawUI(ACanvas);
  if FMenuActive then DrawMenu(ACanvas, ADest);

  // Win Screen Overlay
  if FGameState = gsWin then
  begin
    var LPaint: ISkPaint := TSkPaint.Create(TSkPaintStyle.Fill);
    LPaint.Color := $AA000000;
    ACanvas.DrawRect(ADest, LPaint);

    var LFont: TSkFont := TSkFont.Create;
    try
      LPaint.Color := TAlphaColors.Aqua;
      ACanvas.DrawSimpleText('LEVEL COMPLETE!', ADest.Width/2 - 150, ADest.Height/2 - 40, LFont, LPaint);
      LPaint.Color := TAlphaColors.Yellow;
      ACanvas.DrawSimpleText('Saved: ' + IntToStr(FScore) + ' / ' + IntToStr(FMaxLemmings), ADest.Width/2 - 120, ADest.Height/2, LFont, LPaint);
      ACanvas.DrawSimpleText('Points: ' + IntToStr(FPoints), ADest.Width/2 - 80, ADest.Height/2 + 40, LFont, LPaint);
    finally
      LFont.Free;
    end;
  end;

  // Post-processing Filters
  if FFilterMode > 0 then
  begin
    var LPaint: ISkPaint := TSkPaint.Create(TSkPaintStyle.Fill);
    LPaint.AntiAlias := True;
    if FFilterMode = 1 then // Grain
    begin
      if Assigned(FGrainShader) then
      begin
        LPaint.Shader := FGrainShader; LPaint.Alpha := 100;
        ACanvas.DrawRect(ADest, LPaint); LPaint.Shader := nil;
      end;
      LPaint.Alpha := 255; LPaint.Color := $22FFD700;
      ACanvas.DrawRect(ADest, LPaint);
    end
    else if FFilterMode = 2 then // Grain + Vignette
    begin
      LPaint.Color := $55FFD700; ACanvas.DrawRect(ADest, LPaint);
      if Assigned(FGrainShader) then
      begin
        LPaint.Shader := FGrainShader; LPaint.Alpha := 100;
        ACanvas.Save; ACanvas.Translate(Random(50) - 25, Random(50) - 25); // Shake grain
        ACanvas.DrawRect(RectF(-50, -50, ADest.Width + 100, ADest.Height + 100), LPaint);
        ACanvas.Restore; LPaint.Shader := nil; LPaint.Alpha := 255;
      end;
      // Radial gradient for vignette
      LPaint.Shader := TSkShader.MakeGradientRadial(ADest.CenterPoint, ADest.Width * 0.7,
        [$00000000, $00000000, $99000000], [0, 0.7, 1], TSkTileMode.Clamp);
      ACanvas.DrawRect(ADest, LPaint);
    end;
  end;
end;

{ --- LIFECYCLE & THREADING --- }

procedure TSkiaLemmings.SafeInvalidate;
begin
  if csDestroying in ComponentState then Exit;
  // Thread-safe UI update. Queues the repaint on the main FMX thread.
  TThread.Queue(nil, procedure
  begin
    if not (csDestroying in ComponentState) and Assigned(Self) then
    begin
      Redraw; Repaint;
    end;
  end);
end;

procedure TSkiaLemmings.StartThread;
begin
  if Assigned(FThread) then Exit;
  // Create a background thread for the game loop
  FThread := TThread.CreateAnonymousThread(procedure
  var LastTime, NowTime, DeltaMS: Cardinal;
  begin
    LastTime := TThread.GetTickCount;
    while not TThread.CheckTerminated do
    begin
      NowTime := TThread.GetTickCount;
      DeltaMS := NowTime - LastTime;
      if DeltaMS = 0 then DeltaMS := 1; // Prevent division by zero
      LastTime := NowTime;

      if FActive then
      begin
        DoPhysicsUpdate(DeltaMS / 1000); // Convert to seconds
        SafeInvalidate; // Trigger repaint
      end;
      Sleep(33); // Target ~30 FPS for logic
    end;
  end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TSkiaLemmings.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Give it a moment to exit
  end;
end;

constructor TSkiaLemmings.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Initialize Lock and Lists
  FLock := TCriticalSection.Create;
  FParticles := TList<TParticle>.Create;
  FLemmings := TList<TLemming>.Create;
  FLoot := TList<TLoot>.Create;
  FBazookas := TList<TBazooka>.Create;
  FEnemies := TList<TEnemy>.Create;

  // Setup Control
  Align := TAlignLayout.Client; HitTest := True; CanFocus := True; TabStop := True;

  // Initial Settings
  FActive := True; FLevel := 1;
  FMapCols := 64; FMapRows := 32;
  FCameraX := 0; FCameraY := 0; FZoom := 1.0;
  FGameSpeed := 1.0;
  FActiveTool := ttDig; FMenuActive := False; FUseCatAvatar := True;
  FVisualMode := 0; FFilterMode := 0; FUnlimited := False;
  FBazookaAmmo := 2; FEraserAmmo := 5; FBridgeAmmo := 3; FPortalAmmo := 2; FGrabAmmo := 3;
  FGrabbedLemming := -1;
  FMaxLemmings := INITIAL_MAX_LEMMINGS;
  FGameState := gsPlaying;

  SetLength(FTiles, FMapCols * FMapRows);

  // Generate initial assets and map
  InitProceduralTextures;
  RenderAvatarCache;
  GenerateBackgroundElements;
  GenerateProceduralMap;
  CalculateViewMetrics;
  RenderToolbarCache;

  // Start game loop
  StartThread;
end;

destructor TSkiaLemmings.Destroy;
begin
  StopThread;
  // Cleanup
  FreeAndNil(FLock); FreeAndNil(FParticles);
  FreeAndNil(FLemmings); FreeAndNil(FLoot);
  FreeAndNil(FBazookas); FreeAndNil(FEnemies);
  inherited;
end;

procedure TSkiaLemmings.PlayEffect(Effect: Integer);
var FileName, BasePath: string; Flags: Cardinal;
begin
  // Plays WAV files asynchronously using Windows API
  BasePath := ExtractFilePath(ParamStr(0));
  case Effect of
    1: FileName := 'Game Design Sound Effects - Pavs Music\05 - Equip.wav';
    3: FileName := 'Game Design Sound Effects - Pavs Music\03 - Crush.wav';
    4: FileName := 'Game Design Sound Effects - Pavs Music\12 - TingaLing.wav';
    else FileName := '';
  end;
  if FileName = '' then Exit;
  FileName := BasePath + FileName;
  if not FileExists(FileName) then Exit;
  Flags := SND_ASYNC or SND_FILENAME or SND_NODEFAULT;
  PlaySound(PChar(FileName), 0, Flags);
end;

end.
