Option Explicit

Dim shell, fileSystem, projectDirectory, updaterPath, windowsDirectory, powershellPath, expectedVersion, sourceProcessId, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

expectedVersion = WScript.Arguments(0)
sourceProcessId = "0"
If WScript.Arguments.Count >= 2 Then
    sourceProcessId = WScript.Arguments(1)
End If
projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
updaterPath = fileSystem.BuildPath(projectDirectory, "Update-Todo.ps1")
windowsDirectory = shell.ExpandEnvironmentStrings("%WINDIR%")
If windowsDirectory = "%WINDIR%" Or Len(windowsDirectory) = 0 Then
    windowsDirectory = fileSystem.GetSpecialFolder(0).Path
End If
powershellPath = fileSystem.BuildPath(windowsDirectory, "System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fileSystem.FileExists(updaterPath) Or Not fileSystem.FileExists(powershellPath) Then
    WScript.Quit 1
End If

shell.CurrentDirectory = projectDirectory
command = """" & powershellPath & """ -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & updaterPath & _
          """ -TargetDirectory """ & projectDirectory & """ -ExpectedVersion """ & expectedVersion & """ -SourceProcessId " & sourceProcessId
shell.Run command, 0, False
