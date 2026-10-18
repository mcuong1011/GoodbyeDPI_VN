@ECHO OFF
PUSHD "%~dp0"
set _csc=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe
IF NOT EXIST "%_csc%" set _csc=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe

"%_csc%" /nologo /target:winexe /optimize+ /win32icon:goodbyedpi.ico /win32manifest:goodbyedpi_tray.manifest /r:System.Windows.Forms.dll /r:System.Drawing.dll /out:..\goodbyedpi_tray.exe goodbyedpi_tray.cs
IF ERRORLEVEL 1 pause

POPD
