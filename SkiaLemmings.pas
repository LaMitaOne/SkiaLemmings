{*******************************************************************************
  SkiaLemmings v 0.3 alpha
********************************************************************************
  A high-performance, thread-safe 2D Lemmings/Worms hybrid engine built entirely
  with Skia4Delphi. No external images or assets are used; all graphics, UI, and
  terrain textures are generated procedurally via code (Vector graphics & Shaders).
  Author:  Lara Miriam Tamy Reschke
  License: MIT

v0.3 alpha:

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

*******************************************************************************}
unit SkiaLemmings;

interface

uses
  System.SysUtils, System.Types, System.Classes, System.Math,
  System.Generics.Collections, System.UITypes, System.SyncObjs, FMX.Types,
  FMX.Controls, FMX.Forms, FMX.Skia, Winapi.MMSystem, System.Skia;

const
  TILE_SIZE = 32;
  GRAVITY = 30.0;
  LEMMING_SPEED = 1.5;
  MAX_FALL_SPEED = 10.0;
  INITIAL_MAX_LEMMINGS = 10;

type
  TTileType = (ttEmpty, ttDirt, ttStone, ttSteel, ttBridge, ttBlocker);

  TLemmingState = (lsWalking, lsFalling, lsDigging, lsBombing, lsBridging, lsClimbing, lsBlocking, lsGrabbed, lsMiningDir, lsSaved, lsSucked);

  TToolType = (ttNone, ttDig, ttMine, ttBomb, ttLemBridge, ttClimber, ttBlockerTool, ttBazooka, ttEraser, ttUserBridge, ttPortal, ttGrab, ttUnlimited, ttSpeed);

  TGameState = (gsPlaying, gsDead, gsWin, gsAiming);

  TTile = record
    TileType: TTileType;
    Solid: Boolean;
    DigTime: Single;
  end;

  TLemming = record
    Pos: TPointF;
    Vel: TPointF;
    Width, Height: Single;
    State: TLemmingState;
    Dir: Integer;
    DigTimer, BombTimer: Single;
    FallDistance: Single;
    Alive: Boolean;
    AnimPhase: Single;
    BridgeStep: Integer;
    IsClimber: Boolean;
    GrabOffset: TPointF;
    MineDir: TPointF;
  end;

  TParticle = record
    Pos, Vel: TPointF;
    Life: Single;
    Color: TAlphaColor;
    Size: Single;
  end;

  TLoot = record
    Pos: TPointF;
    Kind: Integer; // 0=Dig, 1=Mine, 2=Bomb, 3=LemBridge, 4=Climber, 5=Blocker, 6=Bazooka, 7=Eraser, 8=UserBridge, 9=Portal, 10=Grab
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
    Phase: Single;
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

  TSkiaLemmings = class(TSkCustomControl)
  private
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection;
    FGameState: TGameState;
    FWinTime: Single;
    FMenuActive: Boolean;

    FScore, FPoints, FLevel: Integer;
    FMaxLemmings: Integer;
    FGameSpeed: Single;

    FTiles: TArray<TTile>;
    FMapCols, FMapRows: Integer;
    FGate: TGate;
    FSpawnPoint: TSpawnPoint;
    FCameraX, FCameraY: Single;
    FZoom: Single;
    FViewOffsetX, FViewOffsetY: Single;
    FMouseScreen: TPointF;

    FLemmings: TList<TLemming>;
    FParticles: TList<TParticle>;
    FLoot: TList<TLoot>;
    FBazookas: TList<TBazooka>;
    FEnemies: TList<TEnemy>;
    FPortals: array[0..1] of TPortal;

    FActiveTool: TToolType;
    FUnlimited: Boolean;
    // Ammo for all tools
    FDigAmmo, FMineAmmo, FBombAmmo, FLemBridgeAmmo, FClimberAmmo, FBlockerAmmo: Integer;
    FBazookaAmmo, FEraserAmmo, FBridgeAmmo, FPortalAmmo, FGrabAmmo: Integer;

    FAimLemmingIndex: Integer;
    FAimStart, FAimEnd: TPointF;
    FIsDrawingBridge: Boolean;
    FTouchStart, FTouchEnd: TPointF;
    FGrabbedLemming: Integer;
    FIsAimingMine: Boolean;
    FMineLemmingIndex: Integer;

    FShakeTime: Single;
    FShakeIntensity: Single;

    FToolbarImg: ISkImage;
    FCatImg, FHumanImg, FParaImg: ISkImage;
    FGrassShader, FDirtShader, FStoneShader, FSteelShader: ISkShader;
    FGrainShader: ISkShader;
    FBgClouds: TArray<TPointF>;

    FVisualMode: Integer;
    FFilterMode: Integer;
    FUseCatAvatar: Boolean;

    procedure PlayEffect(Effect: Integer);
    procedure DoPhysicsUpdate(DeltaSec: Double);
    procedure SafeInvalidate;
    procedure StartThread;
    procedure StopThread;

    procedure GenerateProceduralMap;
    procedure GenerateBackgroundElements;
    procedure InitProceduralTextures;
    procedure RenderToolbarCache;
    procedure RenderAvatarCache;

    procedure CheckGateCollisions;
    procedure CheckLootCollisions;
    procedure CheckEnemyCollisions;
    procedure UpdateLemmings(DeltaSec: Double);
    procedure UpdateBazookas(DeltaSec: Double);
    procedure UpdateEnemies(DeltaSec: Double);
    procedure UpdateParticles(DeltaTime: Single);

    procedure KillLemming(var L: TLemming);
    procedure SpawnExplosion(const X, Y: Single; Color: TAlphaColor; Size: Single = 4.0);
    procedure FireBazooka(const TargetX, TargetY: Single);
    procedure EraserAt(const X, Y: Single);
    procedure BuildBridge(const P1, P2: TPointF);

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

    procedure CalculateViewMetrics;
    function ScreenToWorld(const P: TPointF): TPointF;
    procedure ApplyZoom(NewZoom: Single);
    procedure ResetPortals;
    function PtDistance(const P1, P2: TPointF): Single;
  protected
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

const
  CEmptyTile: TTile = (
    TileType: ttEmpty;
    Solid: False;
    DigTime: 0
  );
  CBridgeTile: TTile = (
    TileType: ttBridge;
    Solid: True;
    DigTime: 1.0
  );
  CBlockerTile: TTile = (
    TileType: ttBlocker;
    Solid: True;
    DigTime: 999
  );

  // Colors for Tools and matching Loot
  ToolColors: array[0..10] of TAlphaColor = ($FFA52A2A, // 0: Dig (Brown)
    $FFFF8800, // 1: Mine (Orange)
    $FFFF0000, // 2: Bomb (Red)
    $FFDEB887, // 3: LemBridge (BurlyWood)
    $FF00FF00, // 4: Climber (Green)
    $FFFFFF00, // 5: Blocker (Yellow)
    $FF00FFFF, // 6: Bazooka (Aqua)
    $FFFFFFFF, // 7: Eraser (White)
    $FF8B4513, // 8: UserBridge (SaddleBrown)
    $FF0000FF, // 9: Portal (Blue)
    $FF32CD32  // 10: Grab (LimeGreen)
    );

function PtInRect(const P: TPointF; const R: TRectF): Boolean;
begin
  Result := (P.X >= R.Left) and (P.X <= R.Right) and (P.Y >= R.Top) and (P.Y <= R.Bottom);
end;

function IsSolidTile(const Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single; IgnoreBlocker: Boolean = False): Boolean;
var
  Col, Row: Integer;
  T: TTile;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  if (Col < 0) or (Col >= Cols) or (Row < 0) or (Row >= Rows) then
    Exit(True);
  T := Tiles[Row * Cols + Col];
  if IgnoreBlocker and (T.TileType = ttBlocker) then
    Exit(False);
  Result := T.Solid;
end;

function GetTile(var Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single): TTile;
var
  Col, Row: Integer;
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

procedure SetTile(var Tiles: TArray<TTile>; Cols, Rows: Integer; const AX, AY: Single; const NewTile: TTile);
var
  Col, Row: Integer;
begin
  Col := Trunc(AX / TILE_SIZE);
  Row := Trunc(AY / TILE_SIZE);
  if (Col >= 0) and (Col < Cols) and (Row >= 0) and (Row < Rows) then
    Tiles[Row * Cols + Col] := NewTile;
end;

procedure ExplodeTerrain(var Tiles: TArray<TTile>; Cols, Rows: Integer; const X, Y, Radius: Single);
var
  C, R, CX, CY: Integer;
  Dist: Single;
begin
  CX := Trunc(X / TILE_SIZE);
  CY := Trunc(Y / TILE_SIZE);
  for R := Max(0, CY - Trunc(Radius) - 1) to Min(Rows - 1, CY + Trunc(Radius) + 1) do
    for C := Max(0, CX - Trunc(Radius) - 1) to Min(Cols - 1, CX + Trunc(Radius) + 1) do
    begin
      Dist := Sqrt(Sqr(C - CX) + Sqr(R - CY));
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
procedure TSkiaLemmings.CalculateViewMetrics;
var
  MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale, VisibleW, VisibleH: Single;
begin
  MapWidth := FMapCols * TILE_SIZE;
  MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width;
  ScreenH := Height - 200;

  if (ScreenW <= 0) or (ScreenH <= 0) or (MapWidth <= 0) or (MapHeight <= 0) then
    Exit;

  BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  ActualScale := BaseScale * FZoom;

  VisibleW := ScreenW / ActualScale;
  VisibleH := ScreenH / ActualScale;

  FCameraX := EnsureRange(FCameraX, 0, Max(0, MapWidth - VisibleW));
  FCameraY := EnsureRange(FCameraY, 0, Max(0, MapHeight - VisibleH));

  if VisibleW >= MapWidth then
    FViewOffsetX := (ScreenW - (MapWidth * ActualScale)) / 2
  else
    FViewOffsetX := 0;

  if VisibleH >= MapHeight then
    FViewOffsetY := (ScreenH - (MapHeight * ActualScale)) / 2
  else
    FViewOffsetY := 0;
end;

function TSkiaLemmings.ScreenToWorld(const P: TPointF): TPointF;
var
  MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale: Single;
begin
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
var
  OldWorld, NewWorld: TPointF;
begin
  NewZoom := EnsureRange(NewZoom, 1.0, 3.0);
  if NewZoom = FZoom then
    Exit;

  OldWorld := ScreenToWorld(FMouseScreen);
  FZoom := NewZoom;
  CalculateViewMetrics;
  NewWorld := ScreenToWorld(FMouseScreen);

  FCameraX := FCameraX - (NewWorld.X - OldWorld.X);
  FCameraY := FCameraY - (NewWorld.Y - OldWorld.Y);

  CalculateViewMetrics;
end;

procedure TSkiaLemmings.ResetPortals;
begin
  FPortals[0].Active := False;
  FPortals[1].Active := False;
end;

{ --- PROCEDURAL TEXTURES & CACHING --- }
procedure TSkiaLemmings.InitProceduralTextures;
var
  LSurface: ISkSurface;
  LCanvas: ISkCanvas;
  LPaint: ISkPaint;
  I, VariantX: Integer;
begin
  Randomize;
  LPaint := TSkPaint.Create(TSkPaintStyle.Fill);
  LPaint.AntiAlias := True;

  if FVisualMode = 1 then
  begin
    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas;
    LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Style := TSkPaintStyle.Fill;
      LPaint.Color := $FF111118;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      LPaint.StrokeWidth := 1.5;
      LPaint.Style := TSkPaintStyle.Stroke;
      if VariantX mod 2 = 0 then
        LPaint.Color := $FFFF00FF
      else
        LPaint.Color := $FF00FFFF;
      for I := 0 to 3 do
        LCanvas.DrawLine(PointF(VariantX * 32 + Random(32), Random(32)), PointF(VariantX * 32 + Random(32), Random(32)), LPaint);
    end;
    FGrassShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.repeat, TSkTileMode.repeat);
    FDirtShader := FGrassShader;
    FStoneShader := FGrassShader;
    FSteelShader := FGrassShader;
  end
  else
  begin
    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas;
    LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Color := $FF5A3A1A;
      LPaint.Style := TSkPaintStyle.Fill;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      for I := 0 to 15 do
      begin
        LPaint.Color := $FF3A220A;
        LCanvas.DrawCircle(PointF(VariantX * 32 + Random(32), Random(32)), 1 + Random(2), LPaint);
        LPaint.Color := $FF8A6A4A;
        LCanvas.DrawCircle(PointF(VariantX * 32 + Random(32), Random(32)), 1, LPaint);
      end;
    end;
    FDirtShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.repeat, TSkTileMode.repeat);

    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas;
    LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Style := TSkPaintStyle.Fill;
      LPaint.Color := $FF3D3D5C;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      for I := 0 to 10 do
      begin
        LPaint.Color := $FF505080;
        LCanvas.DrawCircle(PointF(VariantX * 32 + Random(32), Random(32)), 1 + Random(3), LPaint);
      end;
      LPaint.StrokeWidth := 1;
      LPaint.Style := TSkPaintStyle.Stroke;
      LPaint.Color := $FF000000;
      for I := 0 to 2 do
        LCanvas.DrawLine(PointF(VariantX * 32 + Random(32), Random(32)), PointF(VariantX * 32 + Random(32), Random(32)), LPaint);
    end;
    FStoneShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.repeat, TSkTileMode.repeat);

    LSurface := TSkSurface.MakeRaster(256, 32);
    LCanvas := LSurface.Canvas;
    LCanvas.Clear($FF000000);
    for VariantX := 0 to 7 do
    begin
      LPaint.Style := TSkPaintStyle.Fill;
      LPaint.Color := $FF666666;
      LCanvas.DrawRect(RectF(VariantX * 32, 0, (VariantX + 1) * 32, 32), LPaint);
      LPaint.Color := $FF888888;
      LCanvas.DrawRect(RectF(VariantX * 32 + 2, 2, (VariantX + 1) * 32 - 2, 30), LPaint);
      LPaint.StrokeWidth := 1;
      LPaint.Style := TSkPaintStyle.Stroke;
      LPaint.Color := $FF333333;
      LCanvas.DrawLine(PointF(VariantX * 32 + 16, 0), PointF(VariantX * 32 + 16, 32), LPaint);
      LCanvas.DrawLine(PointF(VariantX * 32, 16), PointF((VariantX + 1) * 32, 16), LPaint);
    end;
    FSteelShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.repeat, TSkTileMode.repeat);
  end;

  LSurface := TSkSurface.MakeRaster(512, 512);
  LCanvas := LSurface.Canvas;
  LCanvas.Clear($FF000000);
  LPaint.Style := TSkPaintStyle.Fill;
  for I := 0 to 30000 do
  begin
    var LGray := Random(255);
    LPaint.Color := TAlphaColorF.Create(LGray, LGray, LGray, 80).ToAlphaColor;
    LCanvas.DrawPoint(PointF(Random(512), Random(512)), LPaint);
  end;
  FGrainShader := LSurface.MakeImageSnapshot.MakeShader(TSkTileMode.repeat, TSkTileMode.repeat);
end;

procedure TSkiaLemmings.RenderToolbarCache;
var
  LSurf: ISkSurface;
  LCanvas: ISkCanvas;
  LPaint: ISkPaint;
  LFontObj: TSkFont;
  BtnW1, BtnW2, BtnH: Single;
  R: TRectF;

  procedure DrawBtn(Index, Row: Integer; BtnW: Single; const Text: string; Color: TAlphaColor; IsActive: Boolean);
  begin
    R := RectF(Index * BtnW, Row * BtnH, (Index + 1) * BtnW, (Row + 1) * BtnH);
    LPaint.Style := TSkPaintStyle.Fill;
    if IsActive then
      LPaint.Color := $FF223344
    else
      LPaint.Color := $FF111122;
    LCanvas.DrawRect(R, LPaint);

    if IsActive then
    begin
      LPaint.Style := TSkPaintStyle.Stroke;
      LPaint.StrokeWidth := 5;
      LPaint.Color := TAlphaColors.Aqua;
      LCanvas.DrawRect(R, LPaint);
    end;

    LPaint.Style := TSkPaintStyle.Stroke;
    LPaint.StrokeWidth := 2;
    LPaint.Color := Color;
    LCanvas.DrawRect(R, LPaint);

    LPaint.Style := TSkPaintStyle.Fill;
    LPaint.Color := Color;
    LCanvas.DrawCircle(PointF(R.CenterPoint.X, R.CenterPoint.Y - 10), 8, LPaint);

    LPaint.Color := TAlphaColors.White;
    // Fixed offset to center text manually
    LCanvas.DrawSimpleText(Text, R.CenterPoint.X - 20, R.CenterPoint.Y + 25, LFontObj, LPaint);
  end;

  procedure DrawBtnWithAmmo(Index, Row: Integer; BtnW: Single; const Text: string; Color: TAlphaColor; IsActive: Boolean; Ammo: Integer);
  var
    FullText: string;
  begin
    if FUnlimited then
      FullText := Text + ' (∞)'
    else
      FullText := Text + ' x' + IntToStr(Ammo);
    DrawBtn(Index, Row, BtnW, FullText, Color, IsActive);
  end;

begin
  if Width <= 0 then
    Exit;

  LFontObj := TSkFont.Create;
  try
    LSurf := TSkSurface.MakeRaster(Round(Width), 200);
    LCanvas := LSurf.Canvas;
    LCanvas.Clear($FF000000);
    LPaint := TSkPaint.Create;
    LPaint.AntiAlias := True;

    BtnW1 := Width / 6;
    BtnW2 := Width / 7;
    BtnH := 100;

    // Row 1 (Tools)
    DrawBtnWithAmmo(0, 0, BtnW1, 'Dig', ToolColors[0], FActiveTool = ttDig, FDigAmmo);
    DrawBtnWithAmmo(1, 0, BtnW1, 'Mine', ToolColors[1], FActiveTool = ttMine, FMineAmmo);
    DrawBtnWithAmmo(2, 0, BtnW1, 'Bomb', ToolColors[2], FActiveTool = ttBomb, FBombAmmo);
    DrawBtnWithAmmo(3, 0, BtnW1, 'LemBrg', ToolColors[3], FActiveTool = ttLemBridge, FLemBridgeAmmo);
    DrawBtnWithAmmo(4, 0, BtnW1, 'Climb', ToolColors[4], FActiveTool = ttClimber, FClimberAmmo);
    DrawBtnWithAmmo(5, 0, BtnW1, 'Block', ToolColors[5], FActiveTool = ttBlockerTool, FBlockerAmmo);

    // Row 2 (Weapons/Utilities)
    DrawBtnWithAmmo(0, 1, BtnW2, 'Bazooka', ToolColors[6], FActiveTool = ttBazooka, FBazookaAmmo);
    DrawBtnWithAmmo(1, 1, BtnW2, 'Eraser', ToolColors[7], FActiveTool = ttEraser, FEraserAmmo);
    DrawBtnWithAmmo(2, 1, BtnW2, 'UserBrg', ToolColors[8], FActiveTool = ttUserBridge, FBridgeAmmo);
    DrawBtnWithAmmo(3, 1, BtnW2, 'Portal', ToolColors[9], FActiveTool = ttPortal, FPortalAmmo);
    DrawBtnWithAmmo(4, 1, BtnW2, 'Grab', ToolColors[10], FActiveTool = ttGrab, FGrabAmmo);

    // Unlimited & Menu (Gray utility buttons, no ammo count)
    if FUnlimited then
      DrawBtn(5, 1, BtnW2, 'UNL: ON', $FF888888, FActiveTool = ttUnlimited)
    else
      DrawBtn(5, 1, BtnW2, 'UNL: OFF', $FF888888, FActiveTool = ttUnlimited);

    DrawBtn(6, 1, BtnW2, 'MENU', $FF888888, FMenuActive);

    FToolbarImg := LSurf.MakeImageSnapshot;
  finally
    LFontObj.Free;
  end;
end;

procedure TSkiaLemmings.RenderAvatarCache;
var
  LSurf: ISkSurface;
  LCanvas: ISkCanvas;
  LPaint: ISkPaint;
  PB: ISkPathBuilder;
  BodyRect, HeadRect: TRectF;
begin
  // Draw Cat Avatar
  LSurf := TSkSurface.MakeRaster(32, 32);
  LCanvas := LSurf.Canvas;
  LCanvas.Clear($00000000);
  LPaint := TSkPaint.Create;
  LPaint.AntiAlias := True;
  LPaint.Style := TSkPaintStyle.Fill;
  LPaint.Color := $FF333333;

  // FIX: Moved Cat body 4 pixels up (Y from 10 to 6)
  BodyRect := RectF(8, 6, 24, 18);
  LCanvas.DrawOval(BodyRect, LPaint);

  LPaint.Style := TSkPaintStyle.Stroke;
  LPaint.StrokeWidth := 2.5;
  LPaint.StrokeCap := TSkStrokeCap.Round;
  // FIX: Moved Cat legs 4 pixels up to match body
  LCanvas.DrawLine(PointF(12, 18), PointF(12, 24), LPaint);
  LCanvas.DrawLine(PointF(20, 18), PointF(20, 24), LPaint);

  LPaint.Style := TSkPaintStyle.Fill;
  HeadRect := RectF(16, 4, 26, 14); // Head stays relative to body
  LCanvas.DrawOval(HeadRect, LPaint);

  PB := TSkPathBuilder.Create;
  PB.MoveTo(17, 6);
  PB.LineTo(19, 0);
  PB.LineTo(21, 6);
  PB.MoveTo(23, 6);
  PB.LineTo(25, 0);
  PB.LineTo(27, 6);
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  LPaint.Style := TSkPaintStyle.Stroke;
  LCanvas.DrawLine(PointF(8, 16), PointF(2, 10), LPaint);
  LPaint.Style := TSkPaintStyle.Fill;
  LPaint.Color := TAlphaColors.Yellow;
  LCanvas.DrawCircle(PointF(19, 9), 1.5, LPaint);
  LCanvas.DrawCircle(PointF(23, 9), 1.5, LPaint);
  FCatImg := LSurf.MakeImageSnapshot;

  // Draw Human Avatar
  LSurf := TSkSurface.MakeRaster(32, 32);
  LCanvas := LSurf.Canvas;
  LCanvas.Clear($00000000);
  LPaint.Style := TSkPaintStyle.Stroke;
  LPaint.StrokeWidth := 2.5;
  LPaint.StrokeCap := TSkStrokeCap.Round;
  LPaint.Color := $FF2A2A2A;
  PB := TSkPathBuilder.Create;

  // FIX: Moved Human body and legs 4 pixels up (Y from 20 to 16, 28 to 24)
  PB.MoveTo(13, 16);
  PB.LineTo(13, 24); // Legs
  PB.MoveTo(19, 16);
  PB.LineTo(19, 24);
  PB.MoveTo(16, 8);
  PB.LineTo(16, 16);  // Body (also moved 4 up)
  PB.MoveTo(16, 10);
  PB.LineTo(11, 14); // Arms (also moved 4 up)
  PB.MoveTo(16, 10);
  PB.LineTo(21, 14);

  LCanvas.DrawPath(PB.Snapshot, LPaint);

  // Head (moved 4 up: Y from 8 to 4)
  LPaint.Style := TSkPaintStyle.Fill;
  LPaint.Color := $FFD2B48C;
  LCanvas.DrawCircle(PointF(16, 4), 4.5, LPaint);
  LPaint.Color := TAlphaColors.Black;
  LCanvas.DrawCircle(PointF(18, 3), 1, LPaint); // Eye (moved 4 up)
  FHumanImg := LSurf.MakeImageSnapshot;

  // Parachute (stays same, only used when falling)
  LSurf := TSkSurface.MakeRaster(48, 48);
  LCanvas := LSurf.Canvas;
  LCanvas.Clear($00000000);
  LPaint.Style := TSkPaintStyle.Stroke;
  LPaint.StrokeWidth := 1.5;
  LPaint.Color := $FF444444;
  LCanvas.DrawLine(PointF(10, 18), PointF(16, 30), LPaint);
  LCanvas.DrawLine(PointF(38, 18), PointF(32, 30), LPaint);
  LPaint.Style := TSkPaintStyle.Fill;
  LPaint.Color := $FFE0E0E0;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(4, 18);
  PB.QuadTo(24, -4, 44, 18);
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  LPaint.Style := TSkPaintStyle.Stroke;
  LPaint.Color := $FF886644;
  LPaint.StrokeWidth := 1;
  LCanvas.DrawPath(PB.Snapshot, LPaint);
  FParaImg := LSurf.MakeImageSnapshot;
end;


{ --- LEVEL GENERATION --- }
procedure TSkiaLemmings.GenerateProceduralMap;
var
  C, R: Integer;
  DirtTile, StoneTile, SteelTile: TTile;
  Loot: TLoot;
  E: TEnemy;
begin
  DirtTile.TileType := ttDirt;
  DirtTile.Solid := True;
  DirtTile.DigTime := 0.5;
  StoneTile.TileType := ttStone;
  StoneTile.Solid := True;
  StoneTile.DigTime := 2.0;
  SteelTile.TileType := ttSteel;
  SteelTile.Solid := True;
  SteelTile.DigTime := -1;

  for R := 0 to FMapRows - 1 do
    for C := 0 to FMapCols - 1 do
      FTiles[R * FMapCols + C] := DirtTile;

  for C := 0 to FMapCols - 1 do
  begin
    FTiles[(FMapRows - 1) * FMapCols + C] := SteelTile;
    FTiles[(FMapRows - 2) * FMapCols + C] := SteelTile;
  end;
  for R := 0 to FMapRows - 1 do
  begin
    FTiles[R * FMapCols + 0] := SteelTile;
    FTiles[R * FMapCols + 1] := SteelTile;
    FTiles[R * FMapCols + (FMapCols - 1)] := SteelTile;
    FTiles[R * FMapCols + (FMapCols - 2)] := SteelTile;
  end;

  for R := 0 to 3 do
    for C := 2 to FMapCols - 3 do
      FTiles[R * FMapCols + C] := CEmptyTile;

  var SurfaceY := 4;
  var SkipUntil := 0;
  for C := 2 to FMapCols - 3 do
  begin
    if C < SkipUntil then
      Continue;
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

  for var I := 0 to 20 do
  begin
    var CaveX := 4 + Random(FMapCols - 8);
    var CaveY := 8 + Random(FMapRows - 12);
    var CaveW := 3 + Random(6);
    var CaveH := 2 + Random(4);
    for var CY := 0 to CaveH do
      for var CX := 0 to CaveW do
        if (CaveX + CX < FMapCols - 2) and (CaveY + CY < FMapRows - 3) then
          FTiles[(CaveY + CY) * FMapCols + (CaveX + CX)] := CEmptyTile;

    if Random(2) = 0 then
    begin
      Loot.Pos := PointF((CaveX + CaveW / 2) * TILE_SIZE, (CaveY + CaveH / 2) * TILE_SIZE);
      Loot.Kind := Random(11); // 0 to 10
      Loot.Collected := False;
      Loot.Phase := 0;

      // Make sure it's not stuck in the ground
      while IsSolidTile(FTiles, FMapCols, FMapRows, Loot.Pos.X, Loot.Pos.Y) do
        Loot.Pos.Y := Loot.Pos.Y - 4.0;

      FLoot.Add(Loot);
    end;

    if (CaveY > 10) and (FEnemies.Count < 3) and (Random(2) = 0) then
    begin
      E.Pos := PointF((CaveX + 1) * TILE_SIZE, (CaveY + 1) * TILE_SIZE);
      E.Vel := PointF(15 + Random(10), 0);
      if Random(2) = 0 then
        E.Vel.X := -E.Vel.X;
      E.Width := 24;
      E.Height := 24;
      E.Phase := Random(100);
      E.Alive := True;
      FEnemies.Add(E);
    end;
  end;

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
  for var ty := GateY - 5 to FMapRows - 3 do
    for var tx := FMapCols - 11 to FMapCols - 4 do
      FTiles[ty * FMapCols + tx] := CEmptyTile;

  for var tx := FMapCols - 11 to FMapCols - 4 do
    for var ty := FMapRows - 3 to FMapRows - 1 do
      FTiles[ty * FMapCols + tx] := StoneTile;

  // Lowered Gate so bottom circle touches the ground
  FGate.Pos := PointF((FMapCols - 9) * TILE_SIZE, (FMapRows - 3) * TILE_SIZE - 64);
  FGate.Width := 64;
  FGate.Height := 64;
  FGate.Phase := 0;

  FSpawnPoint.Pos := PointF(4 * TILE_SIZE, 2 * TILE_SIZE);
  FSpawnPoint.Timer := 0;
  FSpawnPoint.Spawned := 0;

  FScore := 0;
  FGameState := gsPlaying;
  FLemmings.Clear;

  // Initial Ammo for all tools
  FDigAmmo := 5;
  FMineAmmo := 5;
  FBombAmmo := 3;
  FLemBridgeAmmo := 5;
  FClimberAmmo := 3;
  FBlockerAmmo := 3;
  FBazookaAmmo := 2;
  FEraserAmmo := 5;
  FBridgeAmmo := 3;
  FPortalAmmo := 2;
  FGrabAmmo := 3;

  ResetPortals;
  CalculateViewMetrics;
end;

procedure TSkiaLemmings.GenerateBackgroundElements;
var
  I: Integer;
begin
  SetLength(FBgClouds, 30);
  for I := 0 to High(FBgClouds) do
    FBgClouds[I] := PointF(Random(FMapCols * TILE_SIZE * 2), Random(300) + 20);
end;

{ --- GAME LOGIC --- }
procedure TSkiaLemmings.KillLemming(var L: TLemming);
begin
  L.Alive := False;
  SpawnExplosion(L.Pos.X + L.Width / 2, L.Pos.Y + L.Height / 2, TAlphaColors.Red);
  PlayEffect(3);
end;

procedure TSkiaLemmings.SpawnExplosion(const X, Y: Single; Color: TAlphaColor; Size: Single = 4.0);
var
  I: Integer;
  P: TParticle;
begin
  for I := 0 to 15 do
  begin
    P.Pos := PointF(X, Y);
    P.Vel := PointF((Random - 0.5) * 400, (Random - 0.5) * 400 - 100);
    P.Life := 0.8;
    P.Color := Color;
    P.Size := Size + Random * 4;
    FParticles.Add(P);
  end;
  FShakeTime := 0.3;
  FShakeIntensity := Min(15, Size * 2);
end;

procedure TSkiaLemmings.FireBazooka(const TargetX, TargetY: Single);
var
  L: TLemming;
  B: TBazooka;
  DX, DY, Len, Power: Single;
begin
  if FAimLemmingIndex = -1 then
    Exit;
  L := FLemmings[FAimLemmingIndex];
  DX := TargetX - (L.Pos.X + L.Width / 2);
  DY := TargetY - (L.Pos.Y - 4); // Match simulation start Y
  Len := Sqrt(DX * DX + DY * DY);
  if Len = 0 then
    Len := 1;
  Power := Min(1500, Len * 5);
  // Shoot exactly from FAimStart position
  B.Pos := PointF(L.Pos.X + L.Width / 2, L.Pos.Y - 4);
  B.Vel := PointF((DX / Len) * Power, (DY / Len) * Power);
  B.Active := True;
  FBazookas.Add(B);
  FGameState := gsPlaying;
  if not FUnlimited then
    Dec(FBazookaAmmo);
  RenderToolbarCache;
  PlayEffect(3);
end;

procedure TSkiaLemmings.EraserAt(const X, Y: Single);
begin
  ExplodeTerrain(FTiles, FMapCols, FMapRows, X, Y, 1.5);
  SpawnExplosion(X, Y, TAlphaColors.White, 2.0);
  PlayEffect(1);
end;

procedure TSkiaLemmings.BuildBridge(const P1, P2: TPointF);
var
  DX, DY, Dist, StepX, StepY, CurX, CurY: Single;
  Steps, I: Integer;
begin
  DX := P2.X - P1.X;
  DY := P2.Y - P1.Y;
  Dist := Sqrt(DX * DX + DY * DY);
  if Dist > TILE_SIZE then
  begin
    Steps := Trunc(Dist / (TILE_SIZE * 0.5));
    StepX := DX / Steps;
    StepY := DY / Steps;
    CurX := P1.X;
    CurY := P1.Y;
    for I := 0 to Steps do
    begin
      if not IsSolidTile(FTiles, FMapCols, FMapRows, CurX, CurY) then
        SetTile(FTiles, FMapCols, FMapRows, CurX, CurY, CBridgeTile);
      CurX := CurX + StepX;
      CurY := CurY + StepY;
    end;
    if not FUnlimited then
      Dec(FBridgeAmmo);
    PlayEffect(1);
  end;
end;

procedure TSkiaLemmings.UpdateLemmings(DeltaSec: Double);
var
  I: Integer;
  L: TLemming;
  T: TTile;
begin
  if FSpawnPoint.Spawned < FMaxLemmings then
  begin
    FSpawnPoint.Timer := FSpawnPoint.Timer + DeltaSec;
    if FSpawnPoint.Timer > 0.8 then
    begin
      FSpawnPoint.Timer := 0;
      L.Pos := FSpawnPoint.Pos;
      L.Vel := PointF(0, 0);
      L.Width := 16;
      L.Height := 24;
      L.State := lsFalling;
      L.Dir := 1;
      L.DigTimer := 0;
      L.BombTimer := 0;
      L.FallDistance := 0;
      L.Alive := True;
      L.AnimPhase := Random(10);
      L.BridgeStep := 0;
      L.IsClimber := False;
      L.MineDir := PointF(0, 0);
      FLemmings.Add(L);
      Inc(FSpawnPoint.Spawned);
    end;
  end;

  for I := FLemmings.Count - 1 downto 0 do
  begin
    L := FLemmings[I];
    if not L.Alive then
    begin
      FLemmings.Delete(I);
      Continue;
    end;
    L.AnimPhase := L.AnimPhase + DeltaSec * 10;

    if L.State = lsGrabbed then
    begin
      var TargetPos := ScreenToWorld(FMouseScreen) - L.GrabOffset;
      if not IsSolidTile(FTiles, FMapCols, FMapRows, TargetPos.X, TargetPos.Y, True) then
        L.Pos := TargetPos;
      FLemmings[I] := L;
      Continue;
    end;

    if L.State = lsSucked then
    begin
      FLemmings[I] := L;
      Continue;
    end;

    if L.State = lsMiningDir then
    begin
      var Step := L.MineDir * 2.0;
      var NextPos := L.Pos + Step;
      T := GetTile(FTiles, FMapCols, FMapRows, NextPos.X + L.Width / 2, NextPos.Y + L.Height / 2);
      if T.Solid and (T.DigTime >= 0) and (T.TileType <> ttBlocker) then
        SetTile(FTiles, FMapCols, FMapRows, NextPos.X + L.Width / 2, NextPos.Y + L.Height / 2, CEmptyTile);
      L.Pos := NextPos;
      L.DigTimer := L.DigTimer - DeltaSec;
      if L.DigTimer <= 0 then
        L.State := lsWalking;
      FLemmings[I] := L;
      Continue;
    end;

    case L.State of
      lsWalking:
        begin
          L.Vel.X := LEMMING_SPEED * L.Dir;
          L.Pos.X := L.Pos.X + L.Vel.X;
          if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir = 1, L.Width, 0)), L.Pos.Y + L.Height - 2, True) then
          begin
            if L.IsClimber then
              L.State := lsClimbing
            else
            begin
              L.Dir := -L.Dir;
              L.Pos.X := L.Pos.X + (L.Dir * 2);
            end;
          end;
          if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y + L.Height + 1, True) then
          begin
            L.Pos.Y := Trunc((L.Pos.Y + L.Height) / TILE_SIZE) * TILE_SIZE - L.Height;
            L.FallDistance := 0;
          end
          else
            L.State := lsFalling;
        end;
      lsFalling:
        begin
          L.Vel.Y := L.Vel.Y + GRAVITY * DeltaSec;
          if L.Vel.Y > 4.0 then
            L.Vel.Y := 4.0;
          L.Pos.Y := L.Pos.Y + L.Vel.Y * TILE_SIZE * DeltaSec;
          L.FallDistance := L.FallDistance + (L.Vel.Y * TILE_SIZE * DeltaSec);
          if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y + L.Height + 1, True) then
          begin
            L.Pos.Y := Trunc((L.Pos.Y + L.Height) / TILE_SIZE) * TILE_SIZE - L.Height;
            L.State := lsWalking;
            L.Vel.Y := 0;
            L.FallDistance := 0;
          end;
        end;
      lsClimbing:
        begin
          L.Vel.Y := -LEMMING_SPEED;
          L.Pos.Y := L.Pos.Y - 1;
          if L.Dir = 1 then
            L.Pos.X := Trunc((L.Pos.X + L.Width) / TILE_SIZE) * TILE_SIZE - L.Width - 1
          else
            L.Pos.X := Trunc(L.Pos.X / TILE_SIZE) * TILE_SIZE + 1;
          if not IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir = 1, L.Width, 0)), L.Pos.Y + L.Height - 2, True) then
            L.State := lsWalking;
          if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y - 2, True) then
            L.State := lsWalking;
        end;
      lsDigging:
        begin
          L.Vel.X := 0;
          T := GetTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y + L.Height + 2);
          if T.Solid and (T.DigTime >= 0) and (T.TileType <> ttBlocker) then
          begin
            L.DigTimer := L.DigTimer + DeltaSec;
            if L.DigTimer >= T.DigTime then
            begin
              SetTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y + L.Height + 2, CEmptyTile);
              L.DigTimer := 0;
              L.Pos.Y := L.Pos.Y + 4;
              L.State := lsFalling;
            end;
          end
          else
            L.State := lsWalking;
        end;
      lsBombing:
        begin
          L.Vel.X := 0;
          L.BombTimer := L.BombTimer - DeltaSec;
          if L.BombTimer <= 0 then
          begin
            ExplodeTerrain(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y + L.Height / 2, 2.5);
            KillLemming(L);
          end;
        end;
      lsBridging:
        begin
          L.Vel.X := 0;
          L.DigTimer := L.DigTimer + DeltaSec;
          if L.DigTimer >= 0.5 then
          begin
            L.DigTimer := 0;
            var PlaceX := L.Pos.X + (ifthen(L.Dir = 1, L.Width, -1));
            var PlaceY := L.Pos.Y + L.Height - 4;
            if not IsSolidTile(FTiles, FMapCols, FMapRows, PlaceX, PlaceY, True) then
            begin
              SetTile(FTiles, FMapCols, FMapRows, PlaceX, PlaceY, CBridgeTile);
              L.Pos.X := L.Pos.X + (L.Dir * 8);
              L.Pos.Y := L.Pos.Y - 8;
              Inc(L.BridgeStep);
              if (L.BridgeStep >= 12) or IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y - 2, True) then
                L.State := lsWalking;
            end
            else
              L.State := lsWalking;
          end;
        end;
      lsBlocking:
        begin
          if not IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + L.Width / 2, L.Pos.Y + L.Height + 1, True) then
            L.State := lsFalling;
        end;
    end;

    if FPortals[0].Active and FPortals[1].Active then
    begin
      var LC := PointF(L.Pos.X + L.Width / 2, L.Pos.Y + L.Height / 2);
      if PtDistance(LC, FPortals[0].Pos) < 16 then
      begin
        L.Pos := FPortals[1].Pos - PointF(L.Width / 2, L.Height / 2);
        L.Pos.Y := L.Pos.Y - 20;
        L.Vel.Y := 0;
      end
      else if PtDistance(LC, FPortals[1].Pos) < 16 then
      begin
        L.Pos := FPortals[0].Pos - PointF(L.Width / 2, L.Height / 2);
        L.Pos.Y := L.Pos.Y - 20;
        L.Vel.Y := 0;
      end;
    end;

    FLemmings[I] := L;
  end;
end;

procedure TSkiaLemmings.UpdateBazookas(DeltaSec: Double);
var
  I, J: Integer;
  B: TBazooka;
  E: TEnemy;
begin
  for I := FBazookas.Count - 1 downto 0 do
  begin
    B := FBazookas[I];
    if not B.Active then
    begin
      FBazookas.Delete(I);
      Continue;
    end;
    B.Vel.Y := B.Vel.Y + 400 * DeltaSec;
    B.Pos := B.Pos + B.Vel * DeltaSec;

    if FPortals[0].Active and FPortals[1].Active then
    begin
      if PtDistance(B.Pos, FPortals[0].Pos) < 16 then
        B.Pos := FPortals[1].Pos - PointF(0, 20)
      else if PtDistance(B.Pos, FPortals[1].Pos) < 16 then
        B.Pos := FPortals[0].Pos - PointF(0, 20);
    end;

    var HitTerrain := IsSolidTile(FTiles, FMapCols, FMapRows, B.Pos.X, B.Pos.Y);
    var HitEnemy := False;
    for J := 0 to FEnemies.Count - 1 do
    begin
      E := FEnemies[J];
      if E.Alive and (PtDistance(B.Pos, PointF(E.Pos.X + E.Width / 2, E.Pos.Y + E.Height / 2)) < 20) then
      begin
        HitEnemy := True;
        E.Alive := False;
        FEnemies[J] := E;
        Break;
      end;
    end;

    if HitTerrain or HitEnemy then
    begin
      ExplodeTerrain(FTiles, FMapCols, FMapRows, B.Pos.X, B.Pos.Y, 2.5);
      SpawnExplosion(B.Pos.X, B.Pos.Y, TAlphaColors.Orange, 6.0);
      PlayEffect(3);
      B.Active := False;
    end
    else if (B.Pos.X < 0) or (B.Pos.X > FMapCols * TILE_SIZE) or (B.Pos.Y > FMapRows * TILE_SIZE) then
      B.Active := False;

    FBazookas[I] := B;
  end;
end;

procedure TSkiaLemmings.UpdateEnemies(DeltaSec: Double);
var
  I: Integer;
  E: TEnemy;
begin
  for I := FEnemies.Count - 1 downto 0 do
  begin
    E := FEnemies[I];
    if not E.Alive then
    begin
      FEnemies.Delete(I);
      Continue;
    end;
    E.Phase := E.Phase + DeltaSec * 5;
    E.Pos.X := E.Pos.X + E.Vel.X * DeltaSec;
    E.Pos.Y := E.Pos.Y + 15 * DeltaSec;
    if IsSolidTile(FTiles, FMapCols, FMapRows, E.Pos.X + E.Width / 2, E.Pos.Y + E.Height) then
    begin
      E.Pos.Y := Trunc((E.Pos.Y + E.Height) / TILE_SIZE) * TILE_SIZE - E.Height;
      if IsSolidTile(FTiles, FMapCols, FMapRows, E.Pos.X + E.Width / 2 + Sign(E.Vel.X) * 10, E.Pos.Y + E.Height / 2) then
        E.Vel.X := -E.Vel.X;
    end;
    FEnemies[I] := E;
  end;
end;

procedure TSkiaLemmings.CheckGateCollisions;
var
  I: Integer;
  L: TLemming;
  R, R2, MagnetR: TRectF;
  Center: TPointF;
begin
  if FGameState <> gsPlaying then
    Exit;
  R2 := TRectF.Create(FGate.Pos.X, FGate.Pos.Y, FGate.Pos.X + FGate.Width, FGate.Pos.Y + FGate.Height);
  MagnetR := TRectF.Create(FGate.Pos.X - TILE_SIZE, FGate.Pos.Y - TILE_SIZE, FGate.Pos.X + FGate.Width + TILE_SIZE, FGate.Pos.Y + FGate.Height + TILE_SIZE);
  Center := PointF(FGate.Pos.X + FGate.Width / 2, FGate.Pos.Y + FGate.Height / 2);

  for I := FLemmings.Count - 1 downto 0 do
  begin
    L := FLemmings[I];
    if not L.Alive then
      Continue;
    R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);

    if R.IntersectsWith(R2) then
    begin
      SpawnExplosion(Center.X, Center.Y, TAlphaColors.Aqua);
      SpawnExplosion(Center.X, Center.Y, TAlphaColors.White);
      FLemmings.Delete(I);
      Inc(FScore);
      Inc(FPoints, 100 + Max(0, 60 - Trunc(FWinTime)));
      PlayEffect(4);
      if FScore >= FMaxLemmings then
      begin
        FGameState := gsWin;
        FWinTime := 3.0;
      end;
    end
    else if R.IntersectsWith(MagnetR) then
    begin
      L.State := lsSucked;
      var LC := PointF(L.Pos.X + L.Width / 2, L.Pos.Y + L.Height / 2);
      var Dir := Center - LC;
      var Len := Sqrt(Dir.X * Dir.X + Dir.Y * Dir.Y);
      if Len > 0 then
      begin
        L.Pos.X := L.Pos.X + (Dir.X / Len) * 4.0;
        L.Pos.Y := L.Pos.Y + (Dir.Y / Len) * 4.0;
      end;
      FLemmings[I] := L;
    end;
  end;
end;

procedure TSkiaLemmings.CheckLootCollisions;
var
  I, J: Integer;
  L: TLemming;
  Lo: TLoot;
  R, R2: TRectF;
begin
  for I := 0 to FLoot.Count - 1 do
  begin
    if FLoot[I].Collected then
      Continue;
    Lo := FLoot[I];
    R2 := TRectF.Create(Lo.Pos.X - 16, Lo.Pos.Y - 16, Lo.Pos.X + 16, Lo.Pos.Y + 16);
    for J := 0 to FLemmings.Count - 1 do
    begin
      L := FLemmings[J];
      if not L.Alive then
        Continue;
      R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);
      if R.IntersectsWith(R2) then
      begin
        Lo.Collected := True;
        case Lo.Kind of
          0:
            Inc(FDigAmmo, 3);
          1:
            Inc(FMineAmmo, 3);
          2:
            Inc(FBombAmmo, 2);
          3:
            Inc(FLemBridgeAmmo, 3);
          4:
            Inc(FClimberAmmo, 2);
          5:
            Inc(FBlockerAmmo, 2);
          6:
            Inc(FBazookaAmmo, 3);
          7:
            Inc(FEraserAmmo, 2);
          8:
            Inc(FBridgeAmmo, 3);
          9:
            Inc(FPortalAmmo, 2);
          10:
            Inc(FGrabAmmo, 2);
        end;
        RenderToolbarCache;
        SpawnExplosion(Lo.Pos.X, Lo.Pos.Y, ToolColors[Lo.Kind], 2.0);
        PlayEffect(4);
        Break;
      end;
    end;
    FLoot[I] := Lo;
  end;
end;

procedure TSkiaLemmings.CheckEnemyCollisions;
var
  I, J: Integer;
  L: TLemming;
  E: TEnemy;
  R, R2: TRectF;
begin
  for I := 0 to FEnemies.Count - 1 do
  begin
    E := FEnemies[I];
    if not E.Alive then
      Continue;
    R2 := TRectF.Create(E.Pos.X, E.Pos.Y, E.Pos.X + E.Width, E.Pos.Y + E.Height);
    for J := 0 to FLemmings.Count - 1 do
    begin
      L := FLemmings[J];
      if not L.Alive then
        Continue;
      R := TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height);
      if R.IntersectsWith(R2) then
      begin
        KillLemming(L);
        FLemmings[J] := L;
        E.Alive := False;
        FEnemies[I] := E;
        SpawnExplosion(E.Pos.X + E.Width / 2, E.Pos.Y + E.Height / 2, TAlphaColors.Fuchsia, 6.0);
        Break;
      end;
    end;
  end;
end;

{ --- USER INPUT --- }
procedure TSkiaLemmings.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  WorldP: TPointF;
  L: TLemming;
  BestL, I: Integer;
  BestDist, Dist: Single;
  R: TRectF;
begin
  inherited;

  if FMenuActive then
  begin
    var CenterX := Width / 2;
    var CenterY := Height / 2;
    var BtnW := 200;
    var BtnH := 40;
    var BtnX := CenterX - BtnW / 2;
    var BtnY := CenterY - 20;

    if PtInRect(PointF(X, Y), RectF(BtnX, BtnY, BtnX + BtnW, BtnY + BtnH)) then
      FMenuActive := False
    else if PtInRect(PointF(X, Y), RectF(BtnX, BtnY + BtnH + 10, BtnX + BtnW, BtnY + 2 * BtnH + 10)) then
    begin
      GenerateProceduralMap;
      FMenuActive := False;
      FGameState := gsPlaying;
    end
    else if PtInRect(PointF(X, Y), RectF(BtnX, BtnY + 2 * (BtnH + 10), BtnX + BtnW, BtnY + 3 * BtnH + 20)) then
    begin
      Inc(FLevel);
      GenerateProceduralMap;
      FMenuActive := False;
      FGameState := gsPlaying;
    end;
    Exit;
  end;

  // Toolbar clicks
  if Y >= Height - 200 then
  begin
    if Y < Height - 100 then // Row 1
    begin
      var BtnW := Width / 6;
      if X < BtnW then
        FActiveTool := ttDig
      else if X < BtnW * 2 then
        FActiveTool := ttMine
      else if X < BtnW * 3 then
        FActiveTool := ttBomb
      else if X < BtnW * 4 then
        FActiveTool := ttLemBridge
      else if X < BtnW * 5 then
        FActiveTool := ttClimber
      else
        FActiveTool := ttBlockerTool;
    end
    else // Row 2
    begin
      var BtnW := Width / 7;
      if X < BtnW then
        FActiveTool := ttBazooka
      else if X < BtnW * 2 then
        FActiveTool := ttEraser
      else if X < BtnW * 3 then
        FActiveTool := ttUserBridge
      else if X < BtnW * 4 then
        FActiveTool := ttPortal
      else if X < BtnW * 5 then
        FActiveTool := ttGrab
      else if X < BtnW * 6 then
      begin
        FUnlimited := not FUnlimited;
        FActiveTool := ttUnlimited;
      end
      else
      begin
        FMenuActive := not FMenuActive; // Menu Button
      end;
    end;
    RenderToolbarCache;
    Exit;
  end;

  WorldP := ScreenToWorld(PointF(X, Y));

  if (FActiveTool = ttGrab) and (FGrabbedLemming <> -1) then
  begin
    L := FLemmings[FGrabbedLemming];
    L.State := lsFalling;
    FLemmings[FGrabbedLemming] := L;
    FGrabbedLemming := -1;
    if not FUnlimited then
      Dec(FGrabAmmo);
    RenderToolbarCache;
    Exit;
  end;

  if FGameState = gsAiming then
  begin
    if FActiveTool = ttBazooka then
      FireBazooka(WorldP.X, WorldP.Y);
    Exit;
  end;

  if FActiveTool = ttBazooka then
  begin
    if FUnlimited or (FBazookaAmmo > 0) then
    begin
      BestL := -1;
      BestDist := 9999;
      for I := 0 to FLemmings.Count - 1 do
      begin
        L := FLemmings[I];
        if not L.Alive then
          Continue;
        Dist := Sqrt(Sqr(L.Pos.X - WorldP.X) + Sqr(L.Pos.Y - WorldP.Y));
        if Dist < BestDist then
        begin
          BestDist := Dist;
          BestL := I;
        end;
      end;
      if BestL <> -1 then
      begin
        FAimLemmingIndex := BestL;
        FAimStart := PointF(FLemmings[BestL].Pos.X + FLemmings[BestL].Width / 2, FLemmings[BestL].Pos.Y - 4);
        FAimEnd := WorldP;
        FGameState := gsAiming;
      end;
    end;
  end
  else if FActiveTool = ttEraser then
  begin
    if FUnlimited or (FEraserAmmo > 0) then
    begin
      EraserAt(WorldP.X, WorldP.Y);
      if not FUnlimited then
        Dec(FEraserAmmo);
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
        SpawnExplosion(WorldP.X, WorldP.Y, ToolColors[9], 2.0);
      end
      else if not FPortals[1].Active then
      begin
        FPortals[1].Pos := WorldP;
        FPortals[1].Active := True;
        SpawnExplosion(WorldP.X, WorldP.Y, $FFFF8800, 2.0);
        if not FUnlimited then
          Dec(FPortalAmmo);
        RenderToolbarCache;
      end
      else
      begin
        ResetPortals;
        SpawnExplosion(WorldP.X, WorldP.Y, TAlphaColors.White, 2.0);
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
        if not L.Alive then
          Continue;
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
      if not L.Alive then
        Continue;
      if R.IntersectsWith(TRectF.Create(L.Pos.X, L.Pos.Y, L.Pos.X + L.Width, L.Pos.Y + L.Height)) then
      begin
        var LemToChange := FLemmings[I];
        var CanApply := False;

        if FActiveTool = ttDig then
        begin
          if FUnlimited or (FDigAmmo > 0) then
          begin
            LemToChange.State := lsDigging;
            CanApply := True;
            if not FUnlimited then
              Dec(FDigAmmo);
          end;
        end
        else if FActiveTool = ttMine then
        begin
          if FUnlimited or (FMineAmmo > 0) then
          begin
            FIsAimingMine := True;
            FMineLemmingIndex := I;
            FTouchStart := PointF(L.Pos.X + L.Width / 2, L.Pos.Y + L.Height / 2);
            FTouchEnd := WorldP;
            Exit;
          end;
        end
        else if FActiveTool = ttBomb then
        begin
          if FUnlimited or (FBombAmmo > 0) then
          begin
            LemToChange.State := lsBombing;
            LemToChange.BombTimer := 2.0;
            CanApply := True;
            if not FUnlimited then
              Dec(FBombAmmo);
          end;
        end
        else if FActiveTool = ttLemBridge then
        begin
          if FUnlimited or (FLemBridgeAmmo > 0) then
          begin
            LemToChange.State := lsBridging;
            LemToChange.BridgeStep := 0;
            CanApply := True;
            if not FUnlimited then
              Dec(FLemBridgeAmmo);
          end;
        end
        else if FActiveTool = ttClimber then
        begin
          if FUnlimited or (FClimberAmmo > 0) then
          begin
            LemToChange.IsClimber := True;
            if IsSolidTile(FTiles, FMapCols, FMapRows, L.Pos.X + (ifthen(L.Dir = 1, L.Width, 0)), L.Pos.Y + L.Height - 2, True) then
              LemToChange.State := lsClimbing;
            CanApply := True;
            if not FUnlimited then
              Dec(FClimberAmmo);
          end;
        end
        else if FActiveTool = ttBlockerTool then
        begin
          if FUnlimited or (FBlockerAmmo > 0) then
          begin
            LemToChange.State := lsBlocking;
            SetTile(FTiles, FMapCols, FMapRows, LemToChange.Pos.X + LemToChange.Width / 2, LemToChange.Pos.Y + LemToChange.Height / 2, CBlockerTile);
            CanApply := True;
            if not FUnlimited then
              Dec(FBlockerAmmo);
          end;
        end;

        if CanApply then
        begin
          FLemmings[I] := LemToChange;
          Break;
        end;
      end;
    end;
  end;
end;

procedure TSkiaLemmings.MouseMove(Shift: TShiftState; X, Y: Single);
begin
  inherited;
  FMouseScreen := PointF(X, Y);
  if (FGameState = gsAiming) or FIsDrawingBridge or FIsAimingMine then
  begin
    FTouchEnd := ScreenToWorld(FMouseScreen);
    if FGameState = gsAiming then
      FAimEnd := FTouchEnd;
  end;
end;

procedure TSkiaLemmings.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  DX, DY, Len: Single;
  L: TLemming;
begin
  inherited;
  if FIsDrawingBridge then
  begin
    FIsDrawingBridge := False;
    BuildBridge(FTouchStart, FTouchEnd);
    RenderToolbarCache;
  end;
  if FIsAimingMine then
  begin
    FIsAimingMine := False;
    if FMineLemmingIndex <> -1 then
    begin
      DX := FTouchEnd.X - FTouchStart.X;
      DY := FTouchEnd.Y - FTouchStart.Y;
      Len := Sqrt(DX * DX + DY * DY);
      if (Len > 5) and (FUnlimited or (FMineAmmo > 0)) then
      begin
        L := FLemmings[FMineLemmingIndex];
        L.State := lsMiningDir;
        L.MineDir := PointF(DX / Len, DY / Len);
        L.DigTimer := 3.0;
        FLemmings[FMineLemmingIndex] := L;
        if not FUnlimited then
          Dec(FMineAmmo);
      end;
    end;
    FMineLemmingIndex := -1;
  end;
end;

procedure TSkiaLemmings.MouseWheel(Shift: TShiftState; WheelDelta: Integer; var Handled: Boolean);
begin
  inherited;
  if WheelDelta > 0 then
    ApplyZoom(FZoom * 1.1)
  else
    ApplyZoom(FZoom / 1.1);
  Handled := True;
end;

procedure TSkiaLemmings.KeyDown(var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
begin
  inherited;
  if (Key = vkEscape) or (KeyChar = 'M') or (KeyChar = 'm') then
  begin
    if FGameState = gsAiming then
      FGameState := gsPlaying
    else
      FMenuActive := not FMenuActive;
    Exit;
  end;
  if FMenuActive then
    Exit;
  if (KeyChar = 'C') or (KeyChar = 'c') then
    FUseCatAvatar := not FUseCatAvatar;
  if (KeyChar = 'V') or (KeyChar = 'v') then
  begin
    FVisualMode := FVisualMode + 1;
    if FVisualMode > 1 then
      FVisualMode := 0;
    InitProceduralTextures;
  end;
  if (KeyChar = 'F') or (KeyChar = 'f') then
  begin
    FFilterMode := FFilterMode + 1;
    if FFilterMode > 2 then
      FFilterMode := 0;
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
  RenderToolbarCache;
end;

{ --- PHYSICS LOOP --- }
procedure TSkiaLemmings.UpdateParticles(DeltaTime: Single);
var
  I: Integer;
  P: TParticle;
begin
  for I := FParticles.Count - 1 downto 0 do
  begin
    P := FParticles[I];
    P.Pos.X := P.Pos.X + P.Vel.X * DeltaTime;
    P.Pos.Y := P.Pos.Y + P.Vel.Y * DeltaTime;
    P.Life := P.Life - (0.8 * DeltaTime);
    if P.Life <= 0 then
      FParticles.Delete(I)
    else
      FParticles[I] := P;
  end;
end;

procedure TSkiaLemmings.DoPhysicsUpdate(DeltaSec: Double);
begin
  if not FActive or FMenuActive or (FGameState = gsAiming) then
    Exit;
  DeltaSec := DeltaSec * FGameSpeed;

  if FShakeTime > 0 then
    FShakeTime := FShakeTime - DeltaSec;

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

  FLock.Acquire;
  try
    UpdateLemmings(DeltaSec);
    UpdateBazookas(DeltaSec);
    UpdateEnemies(DeltaSec);
    CheckGateCollisions;
    CheckLootCollisions;
    CheckEnemyCollisions;
    UpdateParticles(DeltaSec);

    if (FGameState = gsPlaying) and (FSpawnPoint.Spawned >= FMaxLemmings) and (FLemmings.Count = 0) then
    begin
      FGameState := gsWin;
      FWinTime := 3.0;
    end;
  finally
    FLock.Release;
  end;
end;

{ --- RENDERING --- }
procedure TSkiaLemmings.DrawBackgrounds(const ACanvas: ISkCanvas; const ADest: TRectF);
var
  Paint: ISkPaint;
  Colors: TArray<TAlphaColor>;
  I: Integer;
  ParallaxX, CloudX, CloudY: Single;
begin
  Colors := [$FF05050A, $FF0A0A12, $FF020205];
  Paint := TSkPaint.Create;
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, ADest.Height - 200), Colors, nil, TSkTileMode.Clamp);
  ACanvas.DrawPaint(Paint);

  ParallaxX := -FCameraX * 0.1 * FZoom;
  Paint.AntiAlias := True;
  Paint.MaskFilter := nil;
  for I := 0 to High(FBgClouds) do
  begin
    CloudX := (FBgClouds[I].X * FZoom) + ParallaxX;
    CloudY := FBgClouds[I].Y * FZoom;
    if CloudX < -200 then
      CloudX := CloudX + (FMapCols * TILE_SIZE * 2 * FZoom);
    Paint.Color := $FF1A1A2A;
    Paint.Alpha := 80;
    ACanvas.DrawCircle(PointF(CloudX, CloudY), 60 * FZoom, Paint);
  end;
end;

procedure TSkiaLemmings.DrawTileMap(const ACanvas: ISkCanvas);
var
  Paint, OutlinePaint: ISkPaint;
  TileRect: TRectF;
  C, R: Integer;
  VariantX: Single;
  MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale: Single;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  OutlinePaint := TSkPaint.Create(TSkPaintStyle.Stroke);
  OutlinePaint.StrokeWidth := 1.0;
  OutlinePaint.Color := $AA000000;

  MapWidth := FMapCols * TILE_SIZE;
  MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width;
  ScreenH := Height - 200;
  BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  ActualScale := BaseScale * FZoom;

  var StartCol := Max(0, Trunc(FCameraX / TILE_SIZE));
  var EndCol := Min(FMapCols - 1, Trunc((FCameraX + ScreenW / ActualScale) / TILE_SIZE));
  var StartRow := Max(0, Trunc(FCameraY / TILE_SIZE));
  var EndRow := Min(FMapRows - 1, Trunc((FCameraY + ScreenH / ActualScale) / TILE_SIZE));

  for R := StartRow to EndRow do
    for C := StartCol to EndCol do
    begin
      if not FTiles[R * FMapCols + C].Solid then
        Continue;
      TileRect := TRectF.Create(C * TILE_SIZE, R * TILE_SIZE, (C + 1) * TILE_SIZE, (R + 1) * TILE_SIZE);
      var TargetShader: ISkShader := nil;
      case FTiles[R * FMapCols + C].TileType of
        ttDirt, ttBridge:
          TargetShader := FDirtShader;
        ttStone:
          TargetShader := FStoneShader;
        ttSteel:
          TargetShader := FSteelShader;
      end;
      if Assigned(TargetShader) then
      begin
        ACanvas.Save;
        try
          ACanvas.ClipRect(TileRect);
          VariantX := ((C * 13 + R * 7) mod 8) * 32;
          ACanvas.Translate(C * TILE_SIZE - VariantX, R * TILE_SIZE);
          Paint.Shader := TargetShader;
          ACanvas.DrawRect(RectF(0, 0, 256, 32), Paint);
          Paint.Shader := nil;
        finally
          ACanvas.Restore;
        end;
      end;
      ACanvas.DrawRect(TileRect, OutlinePaint);
    end;
end;

procedure TSkiaLemmings.DrawSpawnGate(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  Center: TPointF;
begin
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Center := PointF(FSpawnPoint.Pos.X + 8, FSpawnPoint.Pos.Y - 10);
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 10.0);
  Paint.Color := $FF00FF00;
  Paint.Alpha := 150;
  ACanvas.DrawRect(RectF(Center.X - 12, Center.Y - 15, Center.X + 12, Center.Y + 15), Paint);
  Paint.Color := $FF050510;
  ACanvas.DrawRect(RectF(Center.X - 8, Center.Y - 10, Center.X + 8, Center.Y + 10), Paint);
end;

procedure TSkiaLemmings.DrawGate(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  Center: TPointF;
  PhaseOffset: Single;
begin
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Center := PointF(FGate.Pos.X + FGate.Width / 2, FGate.Pos.Y + FGate.Height / 2);
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 25.0);
  Paint.Color := ifthen(Sin(FGate.Phase * 2) > 0, $FF00FFFF, $FFFF00FF);
  Paint.Alpha := 180;
  PhaseOffset := Sin(FGate.Phase) * 0.2;
  ACanvas.Save;
  ACanvas.Translate(Center.X, Center.Y);
  ACanvas.Scale(1.0 + PhaseOffset, 1.0 - PhaseOffset);
  ACanvas.DrawOval(TRectF.Create(-32, -32, 32, 32), Paint);
  ACanvas.Restore;
  Paint.Color := $FF050510;
  ACanvas.DrawOval(TRectF.Create(Center.X - 16, Center.Y - 16, Center.X + 16, Center.Y + 16), Paint);
end;

procedure TSkiaLemmings.DrawLoot(const ACanvas: ISkCanvas);
var
  I: Integer;
  Lo: TLoot;
  Paint: ISkPaint;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.MaskFilter := nil;
  for I := 0 to FLoot.Count - 1 do
  begin
    Lo := FLoot[I];
    if Lo.Collected then
      Continue;
    Lo.Phase := Lo.Phase + 0.05;
    var Offset := Sin(Lo.Phase) * 5.0;
    Paint.Color := ToolColors[Lo.Kind];
    ACanvas.DrawCircle(PointF(Lo.Pos.X, Lo.Pos.Y + Offset), 8, Paint);
    FLoot[I] := Lo;
  end;
end;

procedure TSkiaLemmings.DrawBazookas(const ACanvas: ISkCanvas);
var
  B: TBazooka;
  Paint: ISkPaint;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.Color := $FF222222;
  for B in FBazookas do
  begin
    if not B.Active then
      Continue;
    ACanvas.DrawCircle(B.Pos, 4, Paint);
    Paint.Color := $FFFF0000;
    ACanvas.DrawCircle(PointF(B.Pos.X - B.Vel.X * 0.02, B.Pos.Y - B.Vel.Y * 0.02), 2, Paint);
    Paint.Color := $FF222222;
  end;
end;

procedure TSkiaLemmings.DrawPortals(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  I: Integer;
begin
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 10.0);
  for I := 0 to 1 do
  begin
    if not FPortals[I].Active then
      Continue;
    if I = 0 then
      Paint.Color := $FF0000FF
    else
      Paint.Color := $FFFF8800;
    Paint.Alpha := 180;
    ACanvas.DrawOval(TRectF.Create(FPortals[I].Pos.X - 16, FPortals[I].Pos.Y - 24, FPortals[I].Pos.X + 16, FPortals[I].Pos.Y + 24), Paint);
  end;
end;

procedure TSkiaLemmings.DrawEnemies(const ACanvas: ISkCanvas);
var
  E: TEnemy;
  Paint, GlowPaint: ISkPaint;
  Center: TPointF;
  Offset: Single;
begin
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  GlowPaint := TSkPaint.Create(Paint);
  GlowPaint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Solid, 6.0);
  GlowPaint.Color := TAlphaColors.Purple;
  for E in FEnemies do
  begin
    if not E.Alive then
      Continue;
    Center := PointF(E.Pos.X + E.Width / 2, E.Pos.Y + E.Height / 2);
    Offset := Sin(E.Phase) * 3.0;
    Paint.Color := TAlphaColors.Fuchsia;
    ACanvas.DrawOval(TRectF.Create(Center.X - 14, Center.Y - 12 + Offset, Center.X + 14, Center.Y + 12 + Offset), GlowPaint);
    ACanvas.DrawOval(TRectF.Create(Center.X - 12, Center.Y - 10 + Offset, Center.X + 12, Center.Y + 10 + Offset), Paint);
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawCircle(PointF(Center.X - 4, Center.Y - 2 + Offset), 3, Paint);
    ACanvas.DrawCircle(PointF(Center.X + 4, Center.Y - 2 + Offset), 3, Paint);
    Paint.Color := TAlphaColors.Black;
    ACanvas.DrawCircle(PointF(Center.X - 4, Center.Y - 2 + Offset), 1.5, Paint);
    ACanvas.DrawCircle(PointF(Center.X + 4, Center.Y - 2 + Offset), 1.5, Paint);
  end;
end;

procedure TSkiaLemmings.DrawAimReticle(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  PB: ISkPathBuilder;
  I: Integer;
  SimPos, SimVel: TPointF;
begin
  if FGameState <> gsAiming then
    Exit;
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 2;
  Paint.Color := $FFFF0000;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(FAimStart.X, FAimStart.Y);
  PB.LineTo(FAimEnd.X, FAimEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);

  SimPos := FAimStart;
  SimVel := PointF(FAimEnd.X - FAimStart.X, FAimEnd.Y - FAimStart.Y);
  var Len := Sqrt(SimVel.X * SimVel.X + SimVel.Y * SimVel.Y);
  if Len > 0 then
  begin
    SimVel.X := (SimVel.X / Len) * Min(1500, Len * 5);
    SimVel.Y := (SimVel.Y / Len) * Min(1500, Len * 5);
  end;
  Paint.Color := $FFFFFFFF;
  for I := 0 to 30 do
  begin
    SimVel.Y := SimVel.Y + 400 * 0.05;
    SimPos := SimPos + SimVel * 0.05;
    if I mod 2 = 0 then
      ACanvas.DrawCircle(SimPos, 2, Paint);
    if IsSolidTile(FTiles, FMapCols, FMapRows, SimPos.X, SimPos.Y) then
      Break;
  end;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 2;
  Paint.Color := $FF00FF00;
  ACanvas.DrawCircle(FAimEnd, 15, Paint);
  ACanvas.DrawLine(PointF(FAimEnd.X - 20, FAimEnd.Y), PointF(FAimEnd.X + 20, FAimEnd.Y), Paint);
  ACanvas.DrawLine(PointF(FAimEnd.X, FAimEnd.Y - 20), PointF(FAimEnd.X, FAimEnd.Y + 20), Paint);
end;

procedure TSkiaLemmings.DrawBridgePreview(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  PB: ISkPathBuilder;
begin
  if not FIsDrawingBridge then
    Exit;
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3;
  Paint.Color := $FFDEB887;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(FTouchStart.X, FTouchStart.Y);
  PB.LineTo(FTouchEnd.X, FTouchEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);
end;

procedure TSkiaLemmings.DrawMinePreview(const ACanvas: ISkCanvas);
var
  Paint: ISkPaint;
  PB: ISkPathBuilder;
begin
  if not FIsAimingMine then
    Exit;
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3;
  Paint.Color := $FFFF0000;
  PB := TSkPathBuilder.Create;
  PB.MoveTo(FTouchStart.X, FTouchStart.Y);
  PB.LineTo(FTouchEnd.X, FTouchEnd.Y);
  ACanvas.DrawPath(PB.Snapshot, Paint);
  var Ang := ArcTan2(FTouchEnd.Y - FTouchStart.Y, FTouchEnd.X - FTouchStart.X);
  PB.MoveTo(FTouchEnd.X, FTouchEnd.Y);
  PB.LineTo(FTouchEnd.X - 10 * Cos(Ang - 0.4), FTouchEnd.Y - 10 * Sin(Ang - 0.4));
  PB.MoveTo(FTouchEnd.X, FTouchEnd.Y);
  PB.LineTo(FTouchEnd.X - 10 * Cos(Ang + 0.4), FTouchEnd.Y - 10 * Sin(Ang + 0.4));
  ACanvas.DrawPath(PB.Snapshot, Paint);
end;

procedure TSkiaLemmings.DrawLemmings(const ACanvas: ISkCanvas);
var
  L: TLemming;
  Img: ISkImage;
  Bounce: Single;
  Paint: ISkPaint;
begin
  Paint := TSkPaint.Create;
  for L in FLemmings do
  begin
    if not L.Alive then
      Continue;
    if FUseCatAvatar then
      Img := FCatImg
    else
      Img := FHumanImg;
    if not Assigned(Img) then
      Continue;
    Bounce := 0;
    if L.State = lsWalking then
      Bounce := Abs(Sin(L.AnimPhase * 2)) * 1.5;
    ACanvas.Save;
    try
      ACanvas.Translate(L.Pos.X, L.Pos.Y - Bounce);
      if L.Dir = -1 then
      begin
        ACanvas.Scale(-1, 1);
        ACanvas.Translate(-L.Width, 0);
      end;
      ACanvas.DrawImage(Img, 0, 0, Paint);
    finally
      ACanvas.Restore;
    end;
    if (L.State = lsFalling) and (L.Vel.Y > 2.0) and Assigned(FParaImg) then
      ACanvas.DrawImage(FParaImg, L.Pos.X - 8, L.Pos.Y - 20, Paint);
    if L.State = lsBombing then
    begin
      Paint.Style := TSkPaintStyle.Fill;
      Paint.Color := TAlphaColors.Red;
      ACanvas.DrawCircle(L.Pos.X + L.Width / 2, L.Pos.Y - 4, 3, Paint);
    end;
  end;
end;

procedure TSkiaLemmings.DrawParticles(const ACanvas: ISkCanvas);
var
  P: TParticle;
  Paint: ISkPaint;
  AlphaVal: Integer;
begin
  if FParticles.Count = 0 then
    Exit;
  Paint := TSkPaint.Create(TSkPaintStyle.Fill);
  Paint.AntiAlias := True;
  Paint.MaskFilter := nil;
  for P in FParticles do
  begin
    Paint.Color := P.Color;
    AlphaVal := Round(P.Life * 180);
    if AlphaVal > 255 then
      AlphaVal := 255;
    if AlphaVal < 0 then
      AlphaVal := 0;
    Paint.Alpha := AlphaVal;
    ACanvas.DrawCircle(P.Pos, P.Size * P.Life, Paint);
  end;
end;

procedure TSkiaLemmings.DrawToolbar(const ACanvas: ISkCanvas; const ADest: TRectF);
var
  Paint: ISkPaint;
begin
  if Assigned(FToolbarImg) then
  begin
    Paint := TSkPaint.Create;
    ACanvas.DrawImage(FToolbarImg, 0, ADest.Height - 200, Paint);
  end;
end;

procedure TSkiaLemmings.DrawUI(const ACanvas: ISkCanvas);
var
  Font: TSkFont;
  Paint: ISkPaint;
  Txt: string;
begin
  Txt := 'Saved: ' + IntToStr(FScore) + '/' + IntToStr(FMaxLemmings) + ' | Level: ' + IntToStr(FLevel) + ' | Points: ' + IntToStr(FPoints);
  Txt := Txt + ' | Zoom: ' + FloatToStrF(FZoom, ffFixed, 2, 1) + 'x';
  if FGameSpeed < 1.0 then
    Txt := Txt + ' [SLOW-MO]';
  if FGameState = gsAiming then
    Txt := Txt + ' [AIMING - Click to fire!]';
  if FUnlimited then
    Txt := Txt + ' [UNLIMITED]';
  if FUseCatAvatar then
    Txt := Txt + ' [CAT]'
  else
    Txt := Txt + ' [HUMAN]';

  Font := TSkFont.Create;
  try
    Paint := TSkPaint.Create;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.AntiAlias := True;
    Paint.Color := TAlphaColors.Black;
    Paint.Alpha := 150;
    ACanvas.DrawSimpleText(Txt, 12, 32, Font, Paint);
    Paint.Color := TAlphaColors.Yellow;
    Paint.Alpha := 255;
    ACanvas.DrawSimpleText(Txt, 10, 30, Font, Paint);

  finally
    Font.Free;
  end;
end;

procedure TSkiaLemmings.DrawMenu(const ACanvas: ISkCanvas; const ADest: TRectF);
var
  Paint: ISkPaint;
  Font: TSkFont;
  Rect: TRectF;
  CenterX, CenterY: Single;
  BtnW, BtnH, BtnX, BtnY: Single;
begin
  Paint := TSkPaint.Create;
  Paint.Color := $AA000000;
  ACanvas.DrawPaint(Paint);
  CenterX := ADest.Width / 2;
  CenterY := ADest.Height / 2;
  Rect := TRectF.Create(CenterX - 150, CenterY - 150, CenterX + 150, CenterY + 150);
  Paint.Color := $FF333344;
  Paint.AntiAlias := True;
  ACanvas.DrawRoundRect(Rect, 20, 20, Paint);
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3;
  Paint.Color := $FFFFFFFF;
  ACanvas.DrawRoundRect(Rect, 20, 20, Paint);

  Font := TSkFont.Create;
  try
    Paint := TSkPaint.Create(TSkPaintStyle.Fill);
    Paint.AntiAlias := True;
    Paint.Color := TAlphaColors.White;
    ACanvas.DrawSimpleText('PAUSED', CenterX - 70, CenterY - 100, Font, Paint);

    BtnW := 200;
    BtnH := 40;
    BtnX := CenterX - BtnW / 2;
    BtnY := CenterY - 20;

    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := $FF222233;
    ACanvas.DrawRect(RectF(BtnX, BtnY, BtnX + BtnW, BtnY + BtnH), Paint);
    ACanvas.DrawRect(RectF(BtnX, BtnY + BtnH + 10, BtnX + BtnW, BtnY + 2 * BtnH + 10), Paint);
    ACanvas.DrawRect(RectF(BtnX, BtnY + 2 * (BtnH + 10), BtnX + BtnW, BtnY + 3 * BtnH + 20), Paint);

    Paint.Color := TAlphaColors.Yellow;
    ACanvas.DrawSimpleText('Resume', BtnX + 60, BtnY + 25, Font, Paint);
    ACanvas.DrawSimpleText('Reset Level', BtnX + 45, BtnY + BtnH + 35, Font, Paint);
    ACanvas.DrawSimpleText('New Level', BtnX + 50, BtnY + 2 * BtnH + 45, Font, Paint);
  finally
    Font.Free;
  end;
end;

procedure TSkiaLemmings.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
var
  MapWidth, MapHeight, ScreenW, ScreenH, BaseScale, ActualScale: Single;
  ShakeX, ShakeY: Single;
begin
  DrawBackgrounds(ACanvas, ADest);
  MapWidth := FMapCols * TILE_SIZE;
  MapHeight := FMapRows * TILE_SIZE;
  ScreenW := Width;
  ScreenH := Height - 200;
  BaseScale := Min(ScreenW / MapWidth, ScreenH / MapHeight);
  ActualScale := BaseScale * FZoom;

  ShakeX := 0;
  ShakeY := 0;
  if FShakeTime > 0 then
  begin
    ShakeX := (Random - 0.5) * FShakeIntensity;
    ShakeY := (Random - 0.5) * FShakeIntensity;
  end;

  ACanvas.Save;
  ACanvas.Translate(FViewOffsetX + ShakeX, FViewOffsetY + ShakeY);
  ACanvas.Scale(ActualScale, ActualScale);
  ACanvas.Translate(-FCameraX, -FCameraY);

  FLock.Acquire;
  try
    DrawTileMap(ACanvas);
    DrawSpawnGate(ACanvas);
    DrawLoot(ACanvas);
    DrawGate(ACanvas);
    DrawPortals(ACanvas);
    DrawBazookas(ACanvas);
    DrawEnemies(ACanvas);
    DrawLemmings(ACanvas);

    if FGameState = gsAiming then
      DrawAimReticle(ACanvas);
    if FIsDrawingBridge then
      DrawBridgePreview(ACanvas);
    if FIsAimingMine then
      DrawMinePreview(ACanvas);
    DrawParticles(ACanvas);
    FGate.Phase := FGate.Phase + 0.05;
  finally
    FLock.Release;
    ACanvas.Restore;
  end;

  DrawToolbar(ACanvas, ADest);
  DrawUI(ACanvas);
  if FMenuActive then
    DrawMenu(ACanvas, ADest);

  if FGameState = gsWin then
  begin
    var LPaint: ISkPaint := TSkPaint.Create(TSkPaintStyle.Fill);
    LPaint.Color := $AA000000;
    ACanvas.DrawRect(ADest, LPaint);
    var LFont: TSkFont := TSkFont.Create;
    try
      LPaint.Color := TAlphaColors.Aqua;
      ACanvas.DrawSimpleText('LEVEL COMPLETE!', ADest.Width / 2 - 150, ADest.Height / 2 - 40, LFont, LPaint);
      LPaint.Color := TAlphaColors.Yellow;
      ACanvas.DrawSimpleText('Saved: ' + IntToStr(FScore) + ' / ' + IntToStr(FMaxLemmings), ADest.Width / 2 - 120, ADest.Height / 2, LFont, LPaint);
      ACanvas.DrawSimpleText('Points: ' + IntToStr(FPoints), ADest.Width / 2 - 80, ADest.Height / 2 + 40, LFont, LPaint);
    finally
      LFont.Free;
    end;
  end;

  if FFilterMode > 0 then
  begin
    var LPaint: ISkPaint := TSkPaint.Create(TSkPaintStyle.Fill);
    LPaint.AntiAlias := True;
    if FFilterMode = 1 then
    begin
      if Assigned(FGrainShader) then
      begin
        LPaint.Shader := FGrainShader;
        LPaint.Alpha := 100;
        ACanvas.DrawRect(ADest, LPaint);
        LPaint.Shader := nil;
      end;
      LPaint.Alpha := 255;
      LPaint.Color := $22FFD700;
      ACanvas.DrawRect(ADest, LPaint);
    end
    else if FFilterMode = 2 then
    begin
      LPaint.Color := $55FFD700;
      ACanvas.DrawRect(ADest, LPaint);
      if Assigned(FGrainShader) then
      begin
        LPaint.Shader := FGrainShader;
        LPaint.Alpha := 100;
        ACanvas.Save;
        ACanvas.Translate(Random(50) - 25, Random(50) - 25);
        ACanvas.DrawRect(RectF(-50, -50, ADest.Width + 100, ADest.Height + 100), LPaint);
        ACanvas.Restore;
        LPaint.Shader := nil;
        LPaint.Alpha := 255;
      end;
      LPaint.Shader := TSkShader.MakeGradientRadial(ADest.CenterPoint, ADest.Width * 0.7, [$00000000, $00000000, $99000000], [0, 0.7, 1], TSkTileMode.Clamp);
      ACanvas.DrawRect(ADest, LPaint);
    end;
  end;
end;

{ --- LIFECYCLE & THREADING --- }
procedure TSkiaLemmings.SafeInvalidate;
begin
  if csDestroying in ComponentState then
    Exit;
  TThread.Queue(nil,
    procedure
    begin
      if not (csDestroying in ComponentState) and Assigned(Self) then
      begin
        Redraw;
        Repaint;
      end;
    end);
end;

procedure TSkiaLemmings.StartThread;
begin
  if Assigned(FThread) then
    Exit;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime, DeltaMS: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated do
      begin
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then
          DeltaMS := 1;
        LastTime := NowTime;
        if FActive then
        begin
          DoPhysicsUpdate(DeltaMS / 1000);
          SafeInvalidate;
        end;
        Sleep(33);
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
    Sleep(50);
  end;
end;

constructor TSkiaLemmings.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  FParticles := TList<TParticle>.Create;
  FLemmings := TList<TLemming>.Create;
  FLoot := TList<TLoot>.Create;
  FBazookas := TList<TBazooka>.Create;
  FEnemies := TList<TEnemy>.Create;

  Align := TAlignLayout.Client;
  HitTest := True;
  CanFocus := True;
  TabStop := True;

  FActive := True;
  FLevel := 1;
  FMapCols := 64;
  FMapRows := 32;
  FCameraX := 0;
  FCameraY := 0;
  FZoom := 1.0;
  FGameSpeed := 1.0;
  FShakeTime := 0;
  FShakeIntensity := 0;

  FActiveTool := ttDig;
  FMenuActive := False;
  FUseCatAvatar := True;
  FVisualMode := 0;
  FFilterMode := 0;
  FUnlimited := False;

  FDigAmmo := 5;
  FMineAmmo := 5;
  FBombAmmo := 3;
  FLemBridgeAmmo := 5;
  FClimberAmmo := 3;
  FBlockerAmmo := 3;
  FBazookaAmmo := 2;
  FEraserAmmo := 5;
  FBridgeAmmo := 3;
  FPortalAmmo := 2;
  FGrabAmmo := 3;

  FGrabbedLemming := -1;
  FMaxLemmings := INITIAL_MAX_LEMMINGS;
  FGameState := gsPlaying;

  SetLength(FTiles, FMapCols * FMapRows);
  InitProceduralTextures;
  RenderAvatarCache;
  GenerateBackgroundElements;
  GenerateProceduralMap;
  CalculateViewMetrics;
  RenderToolbarCache;

  StartThread;
end;

destructor TSkiaLemmings.Destroy;
begin
  StopThread;
  FreeAndNil(FLock);
  FreeAndNil(FParticles);
  FreeAndNil(FLemmings);
  FreeAndNil(FLoot);
  FreeAndNil(FBazookas);
  FreeAndNil(FEnemies);
  inherited;
end;

procedure TSkiaLemmings.PlayEffect(Effect: Integer);
var
  FileName, BasePath: string;
  Flags: Cardinal;
begin
  BasePath := ExtractFilePath(ParamStr(0));
  case Effect of
    1:
      FileName := 'Game Design Sound Effects - Pavs Music\05 - Equip.wav';
    3:
      FileName := 'Game Design Sound Effects - Pavs Music\03 - Crush.wav';
    4:
      FileName := 'Game Design Sound Effects - Pavs Music\12 - TingaLing.wav';
  else
    FileName := '';
  end;
  if FileName = '' then
    Exit;
  FileName := BasePath + FileName;
  if not FileExists(FileName) then
    Exit;
  Flags := SND_ASYNC or SND_FILENAME or SND_NODEFAULT;
  PlaySound(PChar(FileName), 0, Flags);
end;

end.

