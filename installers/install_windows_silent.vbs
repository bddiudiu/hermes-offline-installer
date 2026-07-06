Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim psScript
Dim command
Dim index
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "install_windows_silent.ps1")
If Not fso.FileExists(psScript) Then
  psScript = fso.BuildPath(scriptDir, "installers\install_windows_silent.ps1")
End If

If Not fso.FileExists(psScript) Then
  WScript.Quit 1
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArg(psScript)
For index = 0 To WScript.Arguments.Count - 1
  command = command & " " & QuoteArg(WScript.Arguments(index))
Next

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArg(value)
  QuoteArg = """" & Replace(value, """", """""") & """"
End Function
