@echo off
REM Vendor Performance Intelligence Engine — dev container wrapper (Windows cmd).
REM
REM Windows cmd.exe forwarder for bin/dc. Git Bash / WSL users should call
REM bin/dc directly; this .cmd is only for native cmd/PowerShell invocations.
REM
REM Usage:
REM   bin\dc                      :: interactive bash shell
REM   bin\dc bin/rails test       :: run a command inside the container

if "%~1"=="" (
  docker compose run --rm --service-ports dev bash
) else (
  docker compose run --rm dev %*
)
