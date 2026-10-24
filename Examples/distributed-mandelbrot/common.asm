\ Distributed Mandelbrot: what every program shares. See protocol.md.

OSASCI = &FFE3
OSWRCH = &FFEE
OSWORD = &FFF1
OSBYTE = &FFF4
OSCLI  = &FFF7
BRKV   = &0202

\ Ports (application choices, not Acorn's).
PORT_COORD    = &B0     \ the coordinator, MANDEL
PORT_WORKER   = &B1     \ a worker
PORT_LAUNCHER = &B2     \ CLUSTER, WORKERS, STOPWK
PORT_MGMT     = &B3     \ a worker: DISCOVER, START, STOP

\ Message types.
T_HELLO = 1 : T_WELCOME = 2 : T_READY = 3 : T_ASSIGN = 4 : T_RESULT = 5 : T_ACK = 6
T_COMPLETE = 8 : T_DISCOVER = 11 : T_BOOT_HELLO = 12 : T_START = 13 : T_START_ACK = 14
T_LAUNCH_ERROR = 15 : T_STOP = 16 : T_STATUS = 17

HEADER = 14             \ bytes before a message's payload
FRAME  = 192            \ the largest frame, and each receive buffer

\ The image: 160 x 256 in 16 x 8 tiles, Q8.8 from -2.25+1.5i in steps
\ of 5/256 and -3/256.
TILES = 320 : TILE_COLUMNS = 10 : TILE_W = 16 : TILE_H = 8
REAL0 = -576 : IMAG0 = 384 : STEP_REAL = 5 : STEP_IMAG = -3
MAX_ITERATIONS = 64

\ What a remote start leaves for WORKER (BASIC's user zero page; see
\ remote.asm).
HANDOFF_COORD = &70     \ coordinator station
HANDOFF_NONCE = &71     \ launcher's nonce, 4 bytes
HANDOFF_LAUNCHER = &75  \ launcher station
HANDOFF_MARK = &76      \ 'W' when the above are set

\ Zero page the library uses.
ptr  = &78              \ the frame being built or read
sptr = &7A              \ pstr's string
tm   = &7C              \ elapsed's start time

\ Where each program lives (MODE 7's screen is at &7C00, MODE 5's at &5800,
\ MODE 2's at &3000).
WORKER_ORG = &3000 : SQUARES = &4000    \ S(a) low bytes &4000, high &4800
TOOL_ORG   = &3000
MANDEL_ORG = &3000
MANDEL2_ORG = &1B00    \ PAGE on a Model B with DNFS

\ Sends the VDU codes that follow (length first).
MACRO VDUS n
    JSR vdus : EQUB n
ENDMACRO
