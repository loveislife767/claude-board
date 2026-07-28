' Starts the board with no console window flashing up first.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "pwsh.exe -sta -NoProfile -WindowStyle Hidden -File """ & here & "\ClaudeBoard.ps1""", 0, False
