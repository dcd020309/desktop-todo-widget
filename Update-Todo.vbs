Option Explicit

Dim shell, fileSystem, projectDirectory, updaterPath, powershellPath, expectedVersion, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

If WScript.Arguments.Count < 1 Then
    WScript.Quit 1
End If

expectedVersion = WScript.Arguments(0)
projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
updaterPath = fileSystem.BuildPath(projectDirectory, "Update-Todo.ps1")
powershellPath = fileSystem.BuildPath(shell.ExpandEnvironmentStrings("%WINDIR%"), "System32\WindowsPowerShell\v1.0\powershell.exe")

If Not fileSystem.FileExists(updaterPath) Or Not fileSystem.FileExists(powershellPath) Then
    WScript.Quit 1
End If

shell.CurrentDirectory = projectDirectory
command = """" & powershellPath & """ -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & updaterPath & _
          """ -TargetDirectory """ & projectDirectory & """ -ExpectedVersion """ & expectedVersion & """"
shell.Run command, 0, False
