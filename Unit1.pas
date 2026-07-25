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
  public
  end;
var
  Form1: TForm1;
implementation
{$R *.fmx}

procedure TForm1.FormCreate(Sender: TObject);
var
  Layout: TLayout;
  Btn: TSpeedButton;
begin
  Self.Fill.Color := TAlphaColorRec.Black;
  // 1. Create and anchor the game engine to fill the screen
  FLemmingsView := TSkiaLemmings.Create(Self);
  FLemmingsView.Parent := Self;
end;

end.
