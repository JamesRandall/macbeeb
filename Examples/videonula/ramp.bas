10 REM VideoNuLA: sixteen shades from red to yellow
20 MODE 2
30 VDU 23,1,0;0;0;0;
40 FOR C%=0 TO 15
50 GCOL 0,C%:X%=C%*80
60 MOVE X%,0:MOVE X%,1023:PLOT 85,X%+79,0:PLOT 85,X%+79,1023
70 NEXT
80 REM Colour C%: red 15, green C%, blue 0
90 FOR C%=0 TO 15
100 ?&FE23=C%*16+15
110 ?&FE23=C%*16
120 NEXT
130 REM ?&FE22=&40 puts the standard colours back
