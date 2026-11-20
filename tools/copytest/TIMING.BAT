@ECHO OFF
REM DifNif: times 5 reads, 5 copies and 5 compares of the 1 MB D:\T2.BIN.
REM Compare the times on each machine. SMARTDRV is off for C: and D:.
PATH C:\DOS;%PATH%
SMARTDRV C- D- > NUL
ECHO.|TIME|FIND "Current"
FOR %%N IN (1 2 3 4 5) DO COPY D:\T2.BIN NUL > NUL
ECHO.|TIME|FIND "Current"
FOR %%N IN (1 2 3 4 5) DO COPY D:\T2.BIN D:\W.BIN > NUL
ECHO.|TIME|FIND "Current"
FOR %%N IN (1 2 3 4 5) DO FC /B D:\T2.BIN D:\R2.BIN > NUL
ECHO.|TIME|FIND "Current"
