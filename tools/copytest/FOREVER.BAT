@ECHO OFF
REM DifNif copy test, until stopped with Ctrl-C: runs ROUND.BAT over and over,
REM logging to D:\FCLOG.TXT like TEST.BAT (delete the old log first).
REM BREAK ON lets Ctrl-C work during disk activity; the time at the start
REM of each round shows it is still running.
BREAK ON
PATH C:\DOS;%PATH%
SMARTDRV C- D- > NUL
IF NOT EXIST C:\DNTEST\NUL MD C:\DNTEST
:LOOP
ECHO.|TIME|FIND "Current"
CALL D:\ROUND.BAT N
GOTO LOOP
