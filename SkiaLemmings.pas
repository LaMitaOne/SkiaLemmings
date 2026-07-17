{*******************************************************************************
  SkiaLemmings (Procedural Clone Edition)

  A procedural Lemmings clone rendered using Skia4Delphi.
  The game logic runs on a separate thread to ensure smooth 60fps rendering,
  while user input is handled synchronously on the main UI thread.
********************************************************************************}
unit SkiaLemmings;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.Generics.Collections, System.UITypes, System.SyncObjs, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Skia, Winapi.MMSystem, System.Skia;

const
  TILE_SIZE = 32;         // Size of a single map tile in pixels
  GRAVITY = 30.0;         // Downward acceleration applied to falling lemmings
  LEMMING_SPEED = 1.5;    // Horizontal movement speed in pixels per frame
  MAX_FALL_SPEED = 10.0;  // Terminal velocity cap to prevent tunneling through floors
  MAX_LEMMINGS = 10;      // Total number of lemmings spawned per level

type
  // Enumerations defining game entities and states
  TTileType = (ttEmpty, ttDirt, ttStone, ttSteel, ttBridge);
  TLemmingState = (lsWalking, lsFalling, lsDigging, lsBombing);
  TToolType = (ttNone, ttDig, ttBomb, ttBridging);
  TGameState = (gsPlaying, gsDead, gsWin);

  /// <summary>
  /// Represents a single grid cell in the gameworld.
  /// DigTime defines how many seconds it takes to dig through this block
  /// (-1 means indestructible like Steel).
  /// </summary>
  TTile = record
    TileType: TTileType;
    Solid: Boolean;
    DigTime: Single;
  end;

  /// <summary>
  /// Represents a single Lemming entity with physics properties.
  /// </summary>
  TLemming = record
    Pos: TPointF;
    Vel: TPointF;
    Width: Single;
    Height: Single;
    State: TLemmingState;
    Dir: Integer;         // 1 for Right, -1 for Left
    DigTimer: Single;
    BombTimer: Single;
    FallDistance: Single;  // Accumulated pixels fallen to determine fatal falls
    Alive: Boolean;
  end;

  /// <summary>
  /// Simple particle used for visual feedback (digging, explosions).
  /// </summary>
  TParticle = record
    Pos: TPointF;
    Vel: TPointF;
    Life: Single;         // Remaining lifespan in seconds
    Color: TAlphaColor;
    Size: Single;
  end;

  /// <summary>
  /// The level exit object. Lemmings colliding with this are saved.
  /// </summary>
  TGate = record
    Pos: TPointF;
    Width: Single;
    Height: Single;
    Phase: Single;        // Used to animate the pulsating glow effect
  end;

  /// <summary>
  /// Handles the timed interval spawning of new lemmings at the level start.
  /// </summary>
  TSpawnPoint = record
    Pos: TPointF;
    Timer: Single;
    Spawned: Integer;     // Tracks how many have been spawned so far
  end;

  /// <summary>
  /// The main game rendering and logic control.
  /// Inherits from TSkCustomControl for direct Skia canvas access.
  /// </summary>
  TSkiaLemmings = class(TSkCustomControl)
  private
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection; // Ensures thread-safety between physics thread and UI draw calls
    FScore: Integer;
    FLevel: Integer;
    FGameState: TGameState;
    FDeadTime: Single;
    FWinTime: Single;       // Countdown timer before loading the next level
    FLemmings: TList<TLemming>;
    FSpawnPoint: TSpawnPoint;
    FIsDrawingBridge: Boolean;
    FTouchStart: TPointF;
    FTouchEnd: TPointF;
    FTiles: TArray<TTile>;
    FGate: TGate;
    FMapCols: Integer;
    FMapRows: Integer;
    FCameraX: Single;       // Horizontal offset for scrolling the viewport
    FParticles: TList<TParticle>;
    FBgClouds: TArray<TPointF>;    // Pre-calculated positions for parallax background
    FBgMountains: TArray<TPointF>;
    FBgBushes: TArray<TPointF>;
    FActiveTool: TToolType;

    procedure PlayEffect(Effect: Integer);
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure UpdateCamera;
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;
    procedure GenerateProceduralMap;
    procedure GenerateBackgroundElements;
    procedure CheckGateCollisions;
    procedure UpdateLemmings(DeltaSec: Double);
    procedure KillLemming(var L: TLemming);
    procedure SpawnExplosion(const X, Y: Single; Color: TAlphaColor);
    procedure DrawBackgrounds(const ACanvas: ISkCanvas; const ADest: TRectF);
    procedure DrawTileMap(const ACanvas: ISkCanvas);
    procedure DrawGate(const ACanvas: ISkCanvas);
    procedure DrawLemmings(const ACanvas: ISkCanvas);
    procedure DrawParticles(const ACanvas: ISkCanvas);
    procedure UpdateParticles(DeltaTime: Single);
  protected
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property ActiveTool: TToolType read FActiveTool write FActiveTool;
  end;

implementation

{ --- TILE HELPER FUNCTIONS --- }

/// <summary>
/// Checks if a given world coordinate overlaps with a solid tile.
/// Returns True if out of bounds to prevent lemmings from escaping the map.
/// </summary>
function IsSolidTile(const Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single): Boolean;
var Col, Row: Integer;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  // Treat out-of-bounds as solid steel walls
  if (Col < 0) or (Col >= Cols) or (Row < 0) or (Row >= Rows) then Exit(True);
  Result := Tiles[Row * Cols + Col].Solid;
end;

/// <summary>
/// Safely retrieves a tile record at a given world coordinate.
/// Returns a Steel tile if coordinates are out of bounds.
/// </summary>
function GetTile(var Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single): TTile;
var Col, Row: Integer;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  if (Col < 0) or (Col >= Cols) or (Row < 0) or (Row >= Rows) then
  begin
    Result.TileType := ttSteel;
    Result.Solid := True;
    Result.DigTime := 0;
    Exit;
  end;
  Result := Tiles[Row * Cols + Col];
end;

/// <summary>
/// Safely modifies a tile at a given world coordinate.
/// Ignores the request if coordinates are out of map bounds.
/// </summary>
procedure SetTile(var Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single; const NewTile: TTile);
var Col, Row: Integer;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  if (Col >= 0) and (Col < Cols) and (Row >= 0) and (Row < Rows) then
    Tiles[Row * Cols + Col] := NewTile;
end;

{ --- LEVEL GENERATION --- }

/// <summary>
/// Creates a randomized map layout featuring platforms, walls requiring digging,
/// and gaps requiring bridging. Borders are sealed with indestructible steel.
/// </summary>
procedure TSkiaLemmings.GenerateProceduralMap;
var
  C, R, CurrentY: Integer;
  EmptyTile, DirtTile, StoneTile, SteelTile: TTile;
begin
  // Define base tile types
  EmptyTile.TileType := ttEmpty; EmptyTile.Solid := False; EmptyTile.DigTime := 0;
  DirtTile.TileType := ttDirt;   DirtTile.Solid := True;   DirtTile.DigTime := 0.5;
  StoneTile.TileType := ttStone; StoneTile.Solid := True;  StoneTile.DigTime := 2.0;
  SteelTile.TileType := ttSteel; SteelTile.Solid := True;  SteelTile.DigTime := -1; // -1 = indestructible

  // Initialize the entire map as empty space
  for R := 0 to FMapRows - 1 do
    for C := 0 to FMapCols - 1 do
      FTiles[R * FMapCols + C] := EmptyTile;

  // Create thick indestructible steel borders (top, bottom, left, right)
  for C := 0 to FMapCols - 1 do
  begin
    FTiles[0 * FMapCols + C] := SteelTile;                  // Ceiling
    FTiles[1 * FMapCols + C] := SteelTile;
    FTiles[(FMapRows - 1) * FMapCols + C] := SteelTile;     // Floor
    FTiles[(FMapRows - 2) * FMapCols + C] := SteelTile;
  end;

  for R := 0 to FMapRows - 1 do
  begin
    FTiles[R * FMapCols + 0] := SteelTile;                  // Left wall
    FTiles[R * FMapCols + 1] := SteelTile;
    FTiles[R * FMapCols + (FMapCols - 1)] := SteelTile;     // Right wall
    FTiles[R * FMapCols + (FMapCols - 2)] := SteelTile;
  end;

  // Generate a descending staircase system of platforms
  CurrentY := 4;
  C := 2;

  while C < FMapCols - 20 do
  begin
    // Create a platform segment of variable length (5 to 8 tiles)
    var PlatLen := 5 + Random(4);

    // Draw the platform surface (Stone) and sub-surface (Dirt)
    for var X := C to C + PlatLen do
    begin
      if FTiles[CurrentY * FMapCols + X].TileType = ttEmpty then
        FTiles[CurrentY * FMapCols + X] := StoneTile;
      if (CurrentY + 1 < FMapRows - 2) then FTiles[(CurrentY + 1) * FMapCols + X] := DirtTile;
    end;

    // Calculate the start of the next platform with a small random gap
    C := C + PlatLen + Random(3);
    // Descend 1 or 2 rows to create the staircase effect
    if CurrentY < FMapRows - 6 then
      Inc(CurrentY, 1 + Random(2));

    // Randomly spawn a vertical wall blocking the path (requires digging)
    if (C > 15) and (Random(2) = 0) then
    begin
      var WallH := 2 + Random(2);
      var WallMat := DirtTile;
      if Random(2) = 0 then WallMat := StoneTile;
      for var W := 0 to WallH do
        if (CurrentY - 1 - W) > 1 then FTiles[(CurrentY - 1 - W) * FMapCols + C] := WallMat;
    end;

    // Randomly spawn a gap in the platform (requires bridging)
    if (C > 20) and (Random(3) = 0) then
    begin
      var GapLen := 2 + Random(2);
      for var G := 0 to GapLen - 1 do
      begin
        if (C + G) < FMapCols - 5 then
        begin
          // Clear both surface and sub-surface tiles to create the gap
          FTiles[CurrentY * FMapCols + (C + G)] := EmptyTile;
          if (CurrentY + 1 < FMapRows - 2) then FTiles[(CurrentY + 1) * FMapCols + (C + G)] := EmptyTile;
        end;
      end;
      C := C + GapLen;
    end;
  end;

  // Define the lemming spawn point at the top left
  FSpawnPoint.Pos := PointF(3 * TILE_SIZE, 4 * TILE_SIZE - 24);
  FSpawnPoint.Timer := 0;
  FSpawnPoint.Spawned := 0;

  // Carve out an empty area for the exit gate at the bottom right
  var GateY := FMapRows - 4;
  for var ty := GateY - 3 to FMapRows - 3 do
    for var tx := FMapCols - 12 to FMapCols - 3 do
      FTiles[ty * FMapCols + tx] := EmptyTile;

  FGate.Pos := PointF((FMapCols - 10) * TILE_SIZE, (GateY - 3) * TILE_SIZE);
  FGate.Width := 64;
  FGate.Height := 96;
  FGate.Phase := 0;

  // Reset level state
  FScore := 0;
  FGameState := gsPlaying;
  FLemmings.Clear;
end;

/// <summary>
/// Pre-calculates random X/Y coordinates for background visual elements.
/// These are rendered with a parallax offset to create depth.
/// </summary>
procedure TSkiaLemmings.GenerateBackgroundElements;
var I: Integer;
begin
  SetLength(FBgClouds, 30);
  for I := 0 to High(FBgClouds) do FBgClouds[I] := PointF(Random(FMapCols * TILE_SIZE * 2), Random(300) + 20);
  SetLength(FBgMountains, 15);
  for I := 0 to High(FBgMountains) do FBgMountains[I] := PointF(Random(FMapCols * TILE_SIZE * 2), 30 + Random(40));
  SetLength(FBgBushes, 50);
  for I := 0 to High(FBgBushes) do FBgBushes[I] := PointF(Random(FMapCols * TILE_SIZE * 2), 25 + Random(35));
end;

{ --- GAME LOGIC --- }

/// <summary>
/// Triggers the death sequence for a lemming: marks it dead, spawns red particles, plays sound.
/// </summary>
procedure TSkiaLemmings.KillLemming(var L: TLemming);
begin
  L.Alive := False;
  SpawnExplosion(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2, TAlphaColors.Red);
  PlayEffect(3);
end;

/// <summary>
/// Core game loop logic. Handles spawning intervals and updates every living lemming
/// based on their current state (walking, falling, digging, bombing).
/// </summary>
procedure TSkiaLemmings.UpdateLemmings(DeltaSec: Double);
var I: Integer; L: TLemming; T: TTile; EmptyTile: TTile;
begin
  EmptyTile.TileType := ttEmpty; EmptyTile.Solid := False; EmptyTile.DigTime := 0;

  // Handle timed spawning of new lemmings
  if FSpawnPoint.Spawned < MAX_LEMMINGS then
  begin
    FSpawnPoint.Timer := FSpawnPoint.Timer + DeltaSec;
    if FSpawnPoint.Timer > 0.8 then
    begin
      FSpawnPoint.Timer := 0;
      // Initialize new lemming properties
      L.Pos := FSpawnPoint.Pos; L.Vel := PointF(0, 0); L.Width := 16; L.Height := 24;
      L.State := lsWalking; L.Dir := 1; L.DigTimer := 0; L.BombTimer := 0; L.FallDistance := 0; L.Alive := True;
      FLemmings.Add(L);
      Inc(FSpawnPoint.Spawned);
    end;
  end;

  // Iterate backwards to allow safe deletion from the list during the loop
  for I := FLemmings.Count - 1 downto 0 do
  begin
    L := FLemmings[I];
    if not L.Alive then begin FLemmings.Delete(I); Continue; end;

    case L.State of
      lsWalking:
      begin
        // Apply horizontal movement
        L.Vel.X := LEMMING_SPEED * L.Dir;
        L.Pos.X := L.Pos.X + L.Vel.X;

        // Check for wall collision in the direction of movement
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir=1, L.Width, 0)), L.Pos.Y + L.Height - 2) then
        begin
          L.Dir := -L.Dir; // Reverse direction
          L.Pos.X := L.Pos.X + (L.Dir * 2); // Nudge away from wall to prevent sticking
        end;

        // Check for ground beneath feet
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 1) then
        begin
          // Snap lemming's Y position perfectly to the top of the tile
          L.Pos.Y := Trunc((L.Pos.Y + L.Height) / TILE_SIZE) * TILE_SIZE - L.Height;
          L.FallDistance := 0;
        end
        else
          L.State := lsFalling; // No ground found, transition to falling
      end;

      lsFalling:
      begin
        // Apply gravity, capped at terminal velocity
        L.Vel.Y := L.Vel.Y + GRAVITY * DeltaSec;
        if L.Vel.Y > MAX_FALL_SPEED then L.Vel.Y := MAX_FALL_SPEED;
        L.Pos.Y := L.Pos.Y + L.Vel.Y * TILE_SIZE * DeltaSec;

        // Accumulate fall distance to check for fatal landing later
        L.FallDistance := L.FallDistance + (L.Vel.Y * TILE_SIZE * DeltaSec);

        // Check if lemming has hit the ground
        if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 1) then
        begin
          L.Pos.Y := Trunc((L.Pos.Y + L.Height) / TILE_SIZE) * TILE_SIZE - L.Height;

          // Fatal fall threshold: 4 tiles (128 pixels)
          if L.FallDistance > (TILE_SIZE * 4) then
            KillLemming(L)
          else
          begin
            L.State := lsWalking;
            L.Vel.Y := 0;
            L.FallDistance := 0;
          end;
        end;
      end;

      lsDigging:
      begin
        L.Vel.X := 0; // Stop horizontal movement while digging
        // Look at the tile directly below the lemming
        T := GetTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 2);

        if T.Solid and (T.DigTime >= 0) then // Ensure it's not indestructible (Steel)
        begin
          L.DigTimer := L.DigTimer + DeltaSec;

          // Spawn brown dirt particles occasionally for visual feedback
          if Random(3) = 0 then
          begin
            var P: TParticle;
            P.Pos := PointF(L.Pos.X + L.Width/2, L.Pos.Y + L.Height);
            P.Vel := PointF((Random-0.5)*50, -Random*50);
            P.Life := 0.5;
            P.Color := TAlphaColors.Brown;
            P.Size := 3;
            FParticles.Add(P);
          end;

          // Check if dig timer exceeds the tile's required dig time
          if L.DigTimer >= T.DigTime then
          begin
            // Destroy the tile and drop the lemming into the new hole
            SetTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width/2, L.Pos.Y + L.Height + 2, EmptyTile);
            L.DigTimer := 0;
            L.Pos.Y := L.Pos.Y + 4;
            L.State := lsFalling;
          end;
        end
        else
          L.State := lsWalking; // Resume walking if tile is gone or indestructible
      end;

      lsBombing:
      begin
        L.Vel.X := 0;
        L.BombTimer := L.BombTimer - DeltaSec;

        if L.BombTimer <= 0 then
        begin
          // Calculate 3x3 tile grid around the lemming's center
          var CX := Trunc((L.Pos.X + L.Width/2) / TILE_SIZE);
          var CY := Trunc((L.Pos.Y + L.Height/2) / TILE_SIZE);

          // Destroy all non-steel tiles in the blast radius
          for var dy := -1 to 1 do
            for var dx := -1 to 1 do
            begin
              var tX := CX + dx;
              var tY := CY + dy;
              if (tX >= 0) and (tX < FMapCols) and (tY >= 0) and (tY < FMapRows) then
                if FTiles[tY * FMapCols + tX].TileType <> ttSteel then
                  FTiles[tY * FMapCols + tX] := EmptyTile;
            end;
          KillLemming(L);
        end;
      end;
    end;
    FLemmings[I] := L; // Write updated record back to the list
  end;
end;

/// <summary>
/// Checks if any lemming's bounding box overlaps with the exit gate.
/// If so, the lemming is removed and the score increases.
/// Triggers a level win if all lemmings are saved.
/// </summary>
procedure TSkiaLemmings.CheckGateCollisions;
var I: Integer; L: TLemming; R, R2: TRectF;
begin
  if FGameState <> gsPlaying then Exit;

  R2 := TRectF.Create(FGate.Pos.X, FGate.Pos.Y, FGate.Pos.X + FGate.Width, FGate.Pos.Y + FGate.Height);
  for I := FLemmings.Count - 1 downto 0 do
  begin
    L := FLemmings[I];
    if not L.Alive then Continue;

    R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);
    if R.IntersectsWith(R2) then
    begin
      FLemmings.Delete(I);
      Inc(FScore);
      PlayEffect(4);

      // Check win condition
      if FScore >= MAX_LEMMINGS then
      begin
        FGameState := gsWin;
        FWinTime := 2.0; // 2 second delay before loading next level
      end;
    end;
  end;
end;

{ --- USER INPUT --- }

/// <summary>
/// Translates screen click coordinates to world coordinates.
/// Assigns tools to lemmings (Dig/Bomb) or starts tracking a bridge drawing.
/// </summary>
procedure TSkiaLemmings.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited;
  // Convert screen space to world space
  var WorldX := X + FCameraX;
  var WorldY := Y;

  if FActiveTool = ttBridging then
  begin
    FIsDrawingBridge := True;
    FTouchStart := PointF(WorldX, WorldY);
    FTouchEnd := PointF(WorldX, WorldY);
  end
  else if (FActiveTool = ttDig) or (FActiveTool = ttBomb) then
  begin
    // Find the first living lemming within a 20x30 pixel hitbox of the click
    for var I := 0 to FLemmings.Count - 1 do
    begin
      var L := FLemmings[I];
      if not L.Alive then Continue;
      if (Abs(L.Pos.X - WorldX) < 20) and (Abs(L.Pos.Y - WorldY) < 30) then
      begin
        var LemToChange := FLemmings[I];
        if FActiveTool = ttDig then LemToChange.State := lsDigging;
        if FActiveTool = ttBomb then
        begin
          LemToChange.State := lsBombing;
          LemToChange.BombTimer := 2.0; // 2 second fuse
        end;
        FLemmings[I] := LemToChange;
        Break; // Only assign tool to one lemming per click
      end;
    end;
  end;
end;

/// <summary>
/// Updates the end-point of the bridge preview while the mouse button is held.
/// </summary>
procedure TSkiaLemmings.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  if FIsDrawingBridge then
  begin
    FTouchEnd := PointF(X + FCameraX, Y);
    Redraw; // Force redraw to show the bridge preview line
  end;
end;

/// <summary>
/// Finalizes the bridge drawing. Calculates a slope between start and end points
/// and places bridge tiles along that trajectory (2 tiles thick).
/// </summary>
procedure TSkiaLemmings.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var BridgeTile: TTile;
begin
  inherited;
  if FIsDrawingBridge then
  begin
    FIsDrawingBridge := False;
    BridgeTile.TileType := ttBridge;
    BridgeTile.Solid := True;
    BridgeTile.DigTime := 1.0;

    var DX := FTouchEnd.X - FTouchStart.X;
    var DY := FTouchEnd.Y - FTouchStart.Y;
    var Dist := Sqrt(DX*DX + DY*DY);

    // Require a minimum drag distance to prevent accidental single-tile bridges
    if Dist > TILE_SIZE then
    begin
      // Calculate how many horizontal tile steps the bridge spans
      var Steps := Trunc(Abs(DX) / TILE_SIZE);
      if Steps = 0 then Steps := 1;
      var StepY := DY / Steps; // Y-offset applied per X-tile step to create the slope

      var CurX := FTouchStart.X;
      var CurY := FTouchStart.Y;

      for var I := 0 to Steps do
      begin
        // Place 2 vertically stacked tiles to give the bridge physical thickness
        for var T := 0 to 1 do
        begin
          if not IsSolidTile(FTiles, FMapCols, FMapRows, CurX, CurY + (T * TILE_SIZE)) then
            SetTile(FTiles, FMapCols, FMapRows, CurX, CurY + (T * TILE_SIZE), BridgeTile);
        end;

        // Advance coordinates along the slope
        CurX := CurX + (TILE_SIZE * Sign(DX));
        CurY := CurY + StepY;
      end;

      PlayEffect(1);
    end;
    Redraw;
  end;
end;

{ --- PHYSICS & CAMERA --- }

/// <summary>
/// Smoothly scrolls the camera to follow the first living lemming.
/// Prevents the camera from scrolling past the left edge of the map (X < 0).
/// </summary>
procedure TSkiaLemmings.UpdateCamera;
var TargetX: Single;
begin
  TargetX := FSpawnPoint.Pos.X; // Default to spawn point
  for var L in FLemmings do
    if L.Alive then
    begin
      TargetX := L.Pos.X;
      Break; // Follow the first living lemming found
    end;

  // Position lemming roughly 40% from the left edge of the screen
  TargetX := TargetX - (Width * 0.4);

  // Lerp (Linear Interpolation) for smooth camera movement
  FCameraX := FCameraX + (TargetX - FCameraX) * 0.05;
  if FCameraX < 0 then FCameraX := 0;
end;

/// <summary>
/// Spawns a burst of particles radiating outward from a given point.
/// Used for explosions and lemming deaths.
/// </summary>
procedure TSkiaLemmings.SpawnExplosion(const X, Y: Single; Color: TAlphaColor);
var I: Integer; P: TParticle;
begin
  for I := 0 to 15 do
  begin
    P.Pos := PointF(X, Y);
    P.Vel := PointF((Random - 0.5) * 400, (Random - 0.5) * 400 - 100); // Random spread with upward bias
    P.Life := 0.8;
    P.Color := Color;
    P.Size := 4 + Random * 4;
    FParticles.Add(P);
  end;
end;

/// <summary>
/// Updates particle positions, applies life decay, and removes dead particles.
/// </summary>
procedure TSkiaLemmings.UpdateParticles(DeltaTime: Single);
var I: Integer; P: TParticle;
begin
  for I := FParticles.Count - 1 downto 0 do
  begin
    P := FParticles[I];
    P.Pos.X := P.Pos.X + P.Vel.X * DeltaTime;
    P.Pos.Y := P.Pos.Y + P.Vel.Y * DeltaTime;
    P.Life := P.Life - (0.8 * DeltaTime); // Decay life

    if P.Life <= 0 then
      FParticles.Delete(I)
    else
      FParticles[I] := P;
  end;
end;

/// <summary>
/// The main tick function called by the background thread.
/// Updates physics, handles win state delays, and triggers UI redraws safely.
/// </summary>
procedure TSkiaLemmings.DoPhysicsUpdate(DeltaSec: Double);
begin
  if not FActive then Exit;

  // Handle post-win countdown before generating the next level
  if FGameState = gsWin then
  begin
    FWinTime := FWinTime - DeltaSec;
    if FWinTime <= 0 then
    begin
      Inc(FLevel);
      GenerateProceduralMap;
      GenerateBackgroundElements;
    end;
    Exit;
  end;

  // Lock the critical section to prevent data corruption if the UI thread is reading data for drawing
  FLock.Acquire;
  try
    UpdateLemmings(DeltaSec);
    CheckGateCollisions;
    UpdateParticles(DeltaSec);
    UpdateCamera;
  finally
    FLock.Release;
  end;
end;

{ --- RENDERING --- }

/// <summary>
/// Renders the sky gradient and parallax-scrolling background clouds.
/// </summary>
procedure TSkiaLemmings.DrawBackgrounds(const ACanvas: ISkCanvas; const ADest: TRectF);
var Paint: ISkPaint; Colors: TArray<TAlphaColor>; I: Integer; ParallaxX, CloudX, CloudY: Single;
begin
  // Draw a vertical linear gradient for the sky
  Colors := [$FF0f0c29, $FF302b63, $FF24243e];
  Paint := TSkPaint.Create;
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, ADest.Height), Colors, nil, TSkTileMode.Clamp);
  ACanvas.DrawPaint(Paint);

  // Calculate parallax offset (clouds move slower than the foreground)
  ParallaxX := -FCameraX * 0.1;
  Paint.AntiAlias := True;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 20.0);

  // Draw clouds, wrapping them around if they scroll off the left edge
  for I := 0 to High(FBgClouds) do
  begin
    CloudX := FBgClouds[I].X + ParallaxX;
    CloudY := FBgClouds[I].Y;
    if CloudX < -200 then CloudX := CloudX + (FMapCols * TILE_SIZE * 2);
    Paint.Color := $FF3d3d5c;
    Paint.Alpha := 100;
    ACanvas.DrawCircle(PointF(CloudX, CloudY), 60, Paint);
  end;
end;

/// <summary>
/// Iterates through the tile map and draws only visible solid tiles.
/// Applies basic culling to skip tiles outside the current viewport.
/// </summary>
procedure TSkiaLemmings.DrawTileMap(const ACanvas: ISkCanvas);
var Paint: ISkPaint; TileRect: TRectF; C, R: Integer;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;

  for R := 0 to FMapRows - 1 do
    for C := 0 to FMapCols - 1 do
    begin
      if not FTiles[R * FMapCols + C].Solid then Continue;

      TileRect := TRectF.Create(C * TILE_SIZE, R * TILE_SIZE, (C + 1) * TILE_SIZE, (R + 1) * TILE_SIZE);

      // Frustum culling: skip tiles that are completely off-screen
      if (TileRect.Right < FCameraX - 50) or (TileRect.Left > FCameraX + Width + 50) then Continue;

      // Assign color based on tile material
      case FTiles[R * FMapCols + C].TileType of
        ttDirt:   Paint.Color := $FF8B4513;
        ttStone:  Paint.Color := $FF3d3d5c;
        ttSteel:  Paint.Color := $FFAAAAAA;
        ttBridge: Paint.Color := $FFDEB887;
        else      Paint.Color := TAlphaColors.Black;
      end;

      ACanvas.DrawRect(TileRect, Paint);

      // Draw a subtle 1px black outline for tile definition
      Paint.Style := TSkPaintStyle.Stroke;
      Paint.StrokeWidth := 1;
      Paint.Color := $FF000000;
      ACanvas.DrawRect(TileRect, Paint);
      Paint.Style := TSkPaintStyle.Fill;
    end;
end;

/// <summary>
/// Renders the level exit gate with a pulsating, glowing oval effect.
/// </summary>
procedure TSkiaLemmings.DrawGate(const ACanvas: ISkCanvas);
var Paint: ISkPaint; Center: TPointF; PhaseOffset: Single;
begin
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Center := PointF(FGate.Pos.X + FGate.Width / 2, FGate.Pos.Y + FGate.Height / 2);

  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 25.0);

  // Oscillate color between Cyan and Magenta
  Paint.Color := ifthen(Sin(FGate.Phase * 2) > 0, $FF00FFFF, $FFFF00FF);
  Paint.Alpha := 180;

  // Apply a subtle breathing scale effect
  PhaseOffset := Sin(FGate.Phase) * 0.2;
  ACanvas.Save;
  ACanvas.Translate(Center.X, Center.Y);
  ACanvas.Scale(1.0 + PhaseOffset, 1.0 - PhaseOffset);
  ACanvas.DrawOval(TRectF.Create(-45, -70, 45, 70), Paint);
  ACanvas.Restore;

  // Draw a dark inner oval to create a "portal" look
  Paint.Color := $FF050510;
  ACanvas.DrawOval(TRectF.Create(Center.X - 25, Center.Y - 45, Center.X + 25, Center.Y + 45), Paint);
end;

/// <summary>
/// Renders lemmings as glowing stick figures.
/// Includes simple walk animations, and visual indicators for digging/bombing states.
/// </summary>
procedure TSkiaLemmings.DrawLemmings(const ACanvas: ISkCanvas);
var L: TLemming; Paint, GlowPaint: ISkPaint; Center: TPointF; PB: ISkPathBuilder;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Stroke);
  Paint.StrokeWidth := 2.5;
  Paint.StrokeCap := TSkStrokeCap.Round;
  Paint.Color := $FF00FF00;

  // Create a secondary paint object for the neon glow effect
  GlowPaint := TSkPaint.Create(Paint);
  GlowPaint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0);
  GlowPaint.Color := $FF00FF00;

  for L in FLemmings do
  begin
    if not L.Alive then Continue;
    Center := PointF(L.Pos.X + L.Width/2, L.Pos.Y + L.Height/2);

    // Build stick figure path
    PB := TSkPathBuilder.Create;
    // Torso
    PB.MoveTo(Center.X, Center.Y - 8);
    PB.LineTo(Center.X, Center.Y + 4);
    // Arms
    PB.MoveTo(Center.X, Center.Y);
    PB.LineTo(Center.X - 6 * L.Dir, Center.Y - 4);
    PB.MoveTo(Center.X, Center.Y);
    PB.LineTo(Center.X + 6 * L.Dir, Center.Y - 4);

    // Legs with a simple sine-wave walk animation
    var LegAnim := Sin(Self.FSpawnPoint.Timer * 10) * 4;
    if L.State = lsDigging then LegAnim := 0; // Legs stop moving when digging
    PB.MoveTo(Center.X, Center.Y + 4);
    PB.LineTo(Center.X - 4 + LegAnim, Center.Y + 12);
    PB.MoveTo(Center.X, Center.Y + 4);
    PB.LineTo(Center.X + 4 - LegAnim, Center.Y + 12);

    // Draw the stick figure with glow
    ACanvas.DrawPath(PB.Snapshot, GlowPaint);
    ACanvas.DrawPath(PB.Snapshot, Paint);

    // Draw Head
    Paint.Style := TSkPaintStyle.Fill;
    ACanvas.DrawCircle(PointF(Center.X, Center.Y - 10), 4, Paint);
    Paint.Style := TSkPaintStyle.Stroke;

    // Draw state indicators above the lemming
    if L.State = lsBombing then
    begin
      Paint.Color := TAlphaColors.Red;
      Paint.Style := TSkPaintStyle.Fill;
      ACanvas.DrawCircle(Center.X, Center.Y - 18, 4, Paint); // Red bomb dot
      Paint.Color := $FF00FF00;
      Paint.Style := TSkPaintStyle.Stroke;
    end;
    if L.State = lsDigging then
    begin
      Paint.Color := TAlphaColors.Yellow;
      ACanvas.DrawSimpleText('?', Center.X - 3, Center.Y - 18, TSkFont.Create, Paint); // Dig indicator
      Paint.Color := $FF00FF00;
    end;
  end;
end;

/// <summary>
/// Renders active particles with opacity and size based on their remaining life.
/// </summary>
procedure TSkiaLemmings.DrawParticles(const ACanvas: ISkCanvas);
var P: TParticle; Paint: ISkPaint; AlphaVal: Integer;
begin
  if FParticles.Count = 0 then Exit;
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 3.0);

  for P in FParticles do
  begin
    Paint.Color := P.Color;
    // Map life (0.0 to 0.8) to alpha (0 to 180)
    AlphaVal := Round(P.Life * 180);
    if AlphaVal > 255 then AlphaVal := 255;
    if AlphaVal < 0 then AlphaVal := 0;
    Paint.Alpha := AlphaVal;

    // Shrink particle as it dies
    ACanvas.DrawCircle(P.Pos, P.Size * P.Life, Paint);
  end;
end;

/// <summary>
/// Main render loop entry point. Draws all visual layers in correct order.
/// Translates the canvas by the camera offset to simulate scrolling.
/// </summary>
procedure TSkiaLemmings.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  // Draw sky and clouds (fixed to screen, only parallax shifted)
  DrawBackgrounds(ACanvas, ADest);

  // Apply camera transform for world-space objects
  ACanvas.Save;
  ACanvas.Translate(-FCameraX, 0);

  // Lock to safely read physics data while the background thread might be writing
  FLock.Acquire;
  try
    DrawTileMap(ACanvas);
    DrawGate(ACanvas);
    DrawLemmings(ACanvas);
    DrawParticles(ACanvas);

    // Advance gate animation phase
    FGate.Phase := FGate.Phase + 0.05;
  finally
    FLock.Release;
    ACanvas.Restore;
  end;
end;

{ --- LIFECYCLE & THREADING --- }

/// <summary>
/// Safely triggers a UI redraw from the background thread
/// using TThread.Queue to avoid cross-thread VCL/FMX exceptions.
/// </summary>
procedure TSkiaLemmings.SafeInvalidate;
begin
  if csDestroying in ComponentState then Exit;
  TThread.Queue(nil, procedure
  begin
    if not (csDestroying in ComponentState) and Assigned(Self) then
    begin
      Redraw;
      Repaint;
    end;
  end);
end;

/// <summary>
/// Spawns an anonymous background thread running a fixed-timestep loop.
/// Calculates delta time to ensure frame-rate independent physics.
/// </summary>
procedure TSkiaLemmings.StartThread;
begin
  if Assigned(FThread) then Exit;
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
        DoPhysicsUpdate(DeltaMS / 1000); // Convert MS to Seconds
        SafeInvalidate;
      end;
      Sleep(16); // Target ~60 FPS
    end;
  end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

/// <summary>
/// Signals the physics thread to terminate and waits briefly for it to finish.
/// </summary>
procedure TSkiaLemmings.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Give the thread time to process the termination flag
  end;
end;

/// <summary>
/// Constructor: Initializes lists, dimensions, generates the first level, and starts the physics thread.
/// </summary>
constructor TSkiaLemmings.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  Align := TAlignLayout.Client;
  HitTest := True; // Required to receive mouse events
  FActive := True;

  FLevel := 1;
  FMapCols := 200;
  FMapRows := 20;
  FCameraX := 0;
  FActiveTool := ttDig;
  FIsDrawingBridge := False;

  FParticles := TList<TParticle>.Create;
  FLemmings := TList<TLemming>.Create;
  SetLength(FTiles, FMapCols * FMapRows);

  GenerateBackgroundElements;
  GenerateProceduralMap;
  StartThread;
end;

/// <summary>
/// Destructor: Stops the background thread and frees allocated memory.
/// </summary>
destructor TSkiaLemmings.Destroy;
begin
  StopThread;
  FreeAndNil(FLock);
  FreeAndNil(FParticles);
  FreeAndNil(FLemmings);
  inherited;
end;

/// <summary>
/// Plays a hardcoded sound effect asynchronously using the Windows API.
/// </summary>
procedure TSkiaLemmings.PlayEffect(Effect: Integer);
var FileName, BasePath: string; Flags: Cardinal;
begin
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

  // Play asynchronously so it doesn't freeze the game logic thread
  Flags := SND_ASYNC or SND_FILENAME or SND_NODEFAULT;
  PlaySound(PChar(FileName), 0, Flags);
end;

end.
