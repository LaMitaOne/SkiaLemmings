unit Unit1;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  FMX.Types, FMX.Controls, FMX.Forms, FMX.Graphics, FMX.Dialogs, FMX.Layouts,
  FMX.StdCtrls,
  SkiaLemmings; // Custom Skia4Delphi game engine component

type
  /// <summary>
  /// Main application form. Acts as a container for the game engine
  /// and the toolbar used to select Lemming tools.
  /// </summary>
  TForm1 = class(TForm)
    procedure FormCreate(Sender: TObject);
  private
    FLemmingsView: TSkiaLemmings;

    /// <summary>Sets the active tool in the game engine to Dig.</summary>
    procedure BtnDigClick(Sender: TObject);
    /// <summary>Sets the active tool in the game engine to Bomb.</summary>
    procedure BtnBombClick(Sender: TObject);
    /// <summary>Sets the active tool in the game engine to Bridging.</summary>
    procedure BtnBridgeClick(Sender: TObject);
  public
  end;

var
  Form1: TForm1;

implementation

{$R *.fmx}

/// <summary>
/// Initializes the form, creates the Skia rendering control,
/// and dynamically generates the bottom toolbar with tool buttons.
/// </summary>
procedure TForm1.FormCreate(Sender: TObject);
var
  Layout: TLayout;
  Btn: TSpeedButton;
begin
  Self.Fill.Color := TAlphaColorRec.Black;

  // 1. Create and anchor the game engine to fill the screen
  FLemmingsView := TSkiaLemmings.Create(Self);
  FLemmingsView.Parent := Self;

  // 2. Create a bottom layout container for the UI buttons
  Layout := TLayout.Create(Self);
  Layout.Parent := Self;
  Layout.Align := TAlignLayout.Bottom;
  Layout.Height := 50;
  // HitTest must be True so the layout captures clicks and prevents
  // them from accidentally passing through to the game engine below
  Layout.HitTest := True;

  // Button 1: Dig Tool
  Btn := TSpeedButton.Create(Self);
  Btn.Parent := Layout;
  Btn.Text := 'Dig';
  Btn.Align := TAlignLayout.Left;
  Btn.Width := 150;
  Btn.OnClick := BtnDigClick;
  Btn.TextSettings.FontColor := TAlphaColorRec.White;
  Btn.StyleLookup := 'speedbuttonstyle';

  // Button 2: Bomb Tool
  Btn := TSpeedButton.Create(Self);
  Btn.Parent := Layout;
  Btn.Text := 'Bomb';
  Btn.Align := TAlignLayout.Left;
  Btn.Width := 150;
  Btn.OnClick := BtnBombClick;
  Btn.TextSettings.FontColor := TAlphaColorRec.White;

  // Button 3: Bridge Tool
  Btn := TSpeedButton.Create(Self);
  Btn.Parent := Layout;
  Btn.Text := 'Bridge';
  Btn.Align := TAlignLayout.Left;
  Btn.Width := 150;
  Btn.OnClick := BtnBridgeClick;
  Btn.TextSettings.FontColor := TAlphaColorRec.White;

  // Set Dig as the default active tool on application start
  BtnDigClick(nil);
end;

procedure TForm1.BtnDigClick(Sender: TObject);
begin
  if Assigned(FLemmingsView) then FLemmingsView.ActiveTool := ttDig;
end;

procedure TForm1.BtnBombClick(Sender: TObject);
begin
  if Assigned(FLemmingsView) then FLemmingsView.ActiveTool := ttBomb;
end;

procedure TForm1.BtnBridgeClick(Sender: TObject);
begin
  if Assigned(FLemmingsView) then FLemmingsView.ActiveTool := ttBridging;
end;

end.
