@echo off
rem validate-windows.bat — one-shot Windows validation for the Racket port.
rem Assumes Racket (official win32-cs) is installed and on PATH (see VALIDATION.md
rem step 1). Run by double-clicking or: racket\validate-windows.bat
rem
rem Does: deps -> byte-compile -> run the test suite -> build a standalone .exe
rem and run it. Stops at the first real failure.
setlocal EnableExtensions

where racket >nul 2>nul || (echo [X] Racket not found on PATH. See racket\VALIDATION.md step 1. & exit /b 1)
for /f "delims=" %%v in ('racket --version') do echo [i] %%v

set "SCRIPT_DIR=%~dp0"
set "ROOT=%SCRIPT_DIR%.."

echo.
echo == 1/4  dependencies ==
rem Official/full Racket bundles web-server/db/rackunit; only a MINIMAL Racket
rem needs them. Install ONLY if missing, and never abort — trying to install a
rem bundled package fails with "installed in a wider scope".
racket -e "(require web-server/servlet-env db rackunit)" >nul 2>nul
if errorlevel 1 goto installdeps
echo [ok] web-server/db/rackunit already present - skipping catalog install
goto linkkits
:installdeps
echo [i] core libs missing - installing from catalog ...
raco pkg install --auto --batch web-server-lib db-lib
:linkkits
echo [i] linking local packages cli-kit/db-kit/web-kit ...
pushd "%ROOT%" || exit /b 1
raco pkg install --link --batch --skip-installed racket\pkgs\cli-kit racket\pkgs\db-kit racket\pkgs\web-kit
popd

pushd "%SCRIPT_DIR%" || exit /b 1

echo.
echo == 2/4  byte-compile (explicit list; cmd/PowerShell don't expand *.rkt) ==
rem raco make follows requires transitively, so the agent CLI + test suite pull
rem in domain/{tasks,integrations,documents,settings-tool,util}.rkt and
rem domain/{tools,agent}/*.rkt automatically.
raco make config.rkt cli/odysseus-logs.rkt cli/odysseus-preset.rkt cli/odysseus-signature.rkt cli/odysseus-notes.rkt cli/odysseus-sessions.rkt cli/odysseus-tasks.rkt cli/odysseus-research.rkt cli/odysseus-mcp.rkt cli/odysseus-calendar.rkt cli/odysseus-agent.rkt domain/notes.rkt domain/sessions.rkt server/main.rkt server/proxy.rkt test/run-tests.rkt test/seed-db.rkt || (echo [X] BUILD FAILED & popd & exit /b 1)
echo [ok] build clean
racket cli/odysseus-agent.rkt --version || (echo [X] agent CLI failed to load & popd & exit /b 1)

echo.
echo == 3/4  test suite (expect: 23 success) ==
racket test/run-tests.rkt || (echo [X] TESTS FAILED & popd & exit /b 1)

echo.
echo == 4/4  packaging: raco exe + run the binary (the key Windows check) ==
if not exist dist mkdir dist
raco exe -o dist\odysseus-logs.exe cli/odysseus-logs.rkt || (echo [X] raco exe FAILED & popd & exit /b 1)
dist\odysseus-logs.exe --version || (echo [X] standalone binary CRASHED on run & popd & exit /b 1)

popd
echo.
echo =====================================================
echo  ALL GREEN - racket port validates on this Windows box
echo  Report: version OK, build OK, suite=23, raco exe runs.
echo =====================================================
endlocal
