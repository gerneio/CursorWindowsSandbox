:: fixes a 30 second startup delay for powershell
ren C:\Windows\System32\catroot2 catroot2.old

IF "%~1"=="CURSOR" (
    set script=Install-Cursor
    :: expecting cursor commit hash
    set "scriptArgs=%~2"
) ELSE (
    :: TODO: add others...
    set "script="
)

if "%script%"=="" (
    start powershell -NoExit -NoLogo -NoProfile -ExecutionPolicy Unrestricted -Command "echo 'Nothing executed'"
) else (
    start powershell -NoExit -NoLogo -NoProfile -ExecutionPolicy Unrestricted -File "C:\Users\WDAGUtilityAccount\.sandbox\%script%.ps1" "%scriptArgs%"
)