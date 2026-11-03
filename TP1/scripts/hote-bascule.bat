@echo off
rem hote-bascule.bat — a lancer sur le PC HOTE (Windows), pas dans la VM.
rem Coupe (off) ou retablit (on) la carte 3 de srv-core = 1er port du bond (enp0s9).
rem Usage : hote-bascule.bat off     puis     hote-bascule.bat on
rem Si ta VM ne s'appelle pas exactement "srv-core" dans VirtualBox, change VM ci-dessous.

set VM=srv-core
set CARTE=3
set VBM="%ProgramFiles%\Oracle\VirtualBox\VBoxManage.exe"

if /I "%~1"=="off" goto go
if /I "%~1"=="on"  goto go
echo Usage : %~nx0 off^|on
exit /b 1

:go
%VBM% controlvm %VM% setlinkstate%CARTE% %~1
if errorlevel 1 (
    echo Echec : verifie le nom de la VM avec  %VBM% list runningvms
    exit /b 1
)
echo Carte %CARTE% de %VM% : lien %~1
