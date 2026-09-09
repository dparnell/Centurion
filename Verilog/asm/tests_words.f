5 ' DUP EXECUTE . .
: SQ DUP * ;
6 ' SQ EXECUTE .
\ a whole line comment
7 ( inline ) .
: X [ 2 3 + ] LITERAL ;
X .
: Y ( a comment while compiling ) 9 ;
Y .
