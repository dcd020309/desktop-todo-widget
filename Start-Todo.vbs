Option Explicit

Dim shell, fileSystem, projectDirectory, scriptPath, windowsDirectory, powershellPath, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fileSystem.BuildPath(projectDirectory, "TodoWidget.ps1")
windowsDirectory = shell.ExpandEnvironmentStrings("%WINDIR%")
powershellPath = fileSystem.BuildPath(windowsDirectory, "System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fileSystem.FileExists(scriptPath) Then
    MsgBox "TodoWidget.ps1 was not found. Keep all downloaded files in the same folder.", 16, "Desktop Todo"
    WScript.Quit 1
End If

If Not fileSystem.FileExists(powershellPath) Then
    MsgBox "Windows PowerShell was not found: " & powershellPath, 16, "Desktop Todo"
    WScript.Quit 1
End If

shell.CurrentDirectory = projectDirectory
command = """" & powershellPath & """ -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & scriptPath & """"

' WScript launches the process without creating cmd.exe. Window style 0 keeps
' Windows PowerShell hidden; False lets this launcher exit immediately.
shell.Run command, 0, False
