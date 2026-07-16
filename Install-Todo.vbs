Option Explicit

Dim shell, fileSystem, projectDirectory, launcherPath, iconPath
Dim desktopDirectory, shortcutPath, wscriptPath, shortcut

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
launcherPath = fileSystem.BuildPath(projectDirectory, "Start-Todo.vbs")
iconPath = fileSystem.BuildPath(projectDirectory, "assets\todo-icon.ico")
wscriptPath = fileSystem.BuildPath(shell.ExpandEnvironmentStrings("%WINDIR%"), "System32\wscript.exe")

If Not fileSystem.FileExists(launcherPath) Then
    MsgBox "Start-Todo.vbs was not found. Keep all downloaded files in the same folder.", 16, "Desktop Todo"
    WScript.Quit 1
End If

If Not fileSystem.FileExists(iconPath) Then
    MsgBox "The application icon was not found: " & iconPath, 16, "Desktop Todo"
    WScript.Quit 1
End If

desktopDirectory = shell.SpecialFolders("Desktop")
shortcutPath = fileSystem.BuildPath(desktopDirectory, "Desktop Todo.lnk")
Set shortcut = shell.CreateShortcut(shortcutPath)
shortcut.TargetPath = wscriptPath
shortcut.Arguments = """" & launcherPath & """"
shortcut.WorkingDirectory = projectDirectory
shortcut.IconLocation = iconPath & ",0"
shortcut.WindowStyle = 7
shortcut.Description = "Desktop Todo"
shortcut.Save

MsgBox "Desktop Todo shortcut created on the desktop." & vbCrLf & _
       "Use this shortcut to start without a shell window.", 64, "Desktop Todo"
