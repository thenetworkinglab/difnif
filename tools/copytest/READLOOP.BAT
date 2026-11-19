@ECHO OFF
REM DifNif: reads D:\T2.BIN over and over, for scope measurements.
REM Ctrl-C to stop. SMARTDRV is off for C: and D: so every read uses the disk.
BREAK ON
PATH C:\DOS;%PATH%
SMARTDRV C- D- > NUL
:LOOP
COPY D:\T2.BIN NUL > NUL
GOTO LOOP
