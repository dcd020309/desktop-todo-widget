Option Explicit

Dim shell, fileSystem, projectDirectory, scriptPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(projectDirectory, "TodoWidget.ps1")
command = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"

' Window style 0 starts PowerShell completely hidden. False means the launcher
' exits immediately instead of keeping a shell window alive.
shell.Run command, 0, False

