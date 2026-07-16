Option Explicit

Dim shell, fileSystem, projectDirectory, launcherPath
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
launcherPath = fileSystem.BuildPath(projectDirectory, "Start-Todo.vbs")

' Give the old process time to save state and release the single-instance lock.
WScript.Sleep 1200
If fileSystem.FileExists(launcherPath) Then
    shell.Run """" & launcherPath & """", 0, False
End If
