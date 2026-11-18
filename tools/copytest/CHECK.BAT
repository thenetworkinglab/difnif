@ECHO OFF
ECHO Round %1 %2 %3 >> D:\FCLOG.TXT
FC /B %2 %3 | FIND /C "no differences" >> D:\FCLOG.TXT
