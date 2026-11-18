@ECHO OFF
REM DifNif copy test: copies D:\T1.BIN, T2.BIN and P1.BIN to C:\DNTEST and
REM back to D: as R1.BIN, R2.BIN and RP1.BIN, comparing every copy, 20 times.
REM D:\FCLOG.TXT gets a line per comparison, then 1 if the files are
REM identical or 0 if they differ.
REM FC, FIND and SMARTDRV live in C:\DOS
PATH C:\DOS;%PATH%
REM Turn off SMARTDRV caching for C: and D: so comparisons read the disk.
SMARTDRV C- D- > NUL
IF NOT EXIST C:\DNTEST\NUL MD C:\DNTEST
ECHO DifNif copy test >> D:\FCLOG.TXT
FOR %%R IN (1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20) DO CALL D:\ROUND.BAT %%R
ECHO Done >> D:\FCLOG.TXT
ECHO Done. Results are in D:\FCLOG.TXT
