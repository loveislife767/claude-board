' Runs the /rename harvest with no console window - it fires every minute, so a
' flashing window would be unbearable.
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "pwsh.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & here & "\SessionNames.ps1"" -Sync", 0, False
