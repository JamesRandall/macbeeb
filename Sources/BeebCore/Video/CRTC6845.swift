// Hitachi 6845 CRTC.
//
// A port of b2's crtc.cpp (Copyright (C) Tom Seddon, GPLv3), which models
// the Hitachi part's behaviour in detail: vertical adjust latching,
// interlace, and the dummy raster.

public struct CRTC6845: Codable, Sendable {
    public struct Output: Codable, Sendable {
        public var hsync = false
        public var vsync = false
        /// If set, fetch from `address`/`raster` and use as display data.
        public var display = false
        public var cudisp = false
        /// 14-bit memory address.
        public var address: UInt16 = 0
        /// Current character row raster, 5 bits.
        public var raster: UInt8 = 0
    }

    // Bottom 8 bits are the data mask.
    private static let canRead: UInt16 = 256
    private static let canWrite: UInt16 = 512
    private static let registerInfo: [UInt16] = [
        0xFF | canWrite, 0xFF | canWrite, 0xFF | canWrite, 0xFF | canWrite,
        0x7F | canWrite, 0x1F | canWrite, 0x7F | canWrite, 0x7F | canWrite,
        0xF3 | canWrite, 0x1F | canWrite, 0x7F | canWrite, 0x1F | canWrite,
        0x3F | canWrite | canRead, 0xFF | canWrite | canRead,
        0x3F | canWrite | canRead, 0xFF | canWrite | canRead,
        canRead, canRead,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ]

    /// R0-R17.
    public internal(set) var registers = InlineArray<18, UInt8>(repeating: 0)
    var address: UInt8 = 0

    // Internal state.
    var column: UInt8 = 0
    var row: UInt8 = 0
    var raster: UInt8 = 0
    var vsyncCounter: Int8 = -1
    var hsyncCounter: Int8 = -1
    var vadjCounter: Int8 = -1
    var hdisp = true
    var vdisp = true
    var lineAddress: UInt16 = 0
    var nextLineAddress: UInt16 = 0
    var charAddress: UInt16 = 0
    var skewedDisplay: UInt8 = 0
    var skewedCudisp: UInt8 = 0
    var checkVadj = false
    var inVadj = false
    var endOfVadjLatched = false
    var hadVsyncThisRow = false
    var endOfMainLatched = false
    var doEvenFrameLogic = false
    var firstScanline = false
    var inDummyRaster = false
    var endOfFrameLatched = false
    var cursor = false
    var oldLightpen = false
    /// Incremented each field, for even/odd and cursor blink timing.
    var numFrames: UInt8 = 0

    public init() {}

    // Register fields.
    private var r3HSyncWidth: UInt8 { registers[3] & 0x0F }
    private var r3VSyncWidth: UInt8 { registers[3] >> 4 }
    private var r8Interlace: Bool { registers[8] & 0x01 != 0 }
    private var r8Video: Bool { registers[8] & 0x02 != 0 }
    private var r8DisplaySkew: UInt8 { registers[8] >> 4 & 3 }
    private var r8CursorSkew: UInt8 { registers[8] >> 6 & 3 }
    private var r10CursorStart: UInt8 { registers[10] & 0x1F }
    private var r10CursorMode: UInt8 { registers[10] >> 5 & 3 }

    // MARK: Registers

    public func readAddress() -> UInt8 { 0 }

    public mutating func writeAddress(_ value: UInt8) {
        address = value & 31
    }

    public func readData() -> UInt8 {
        let info = Self.registerInfo[Int(address)]
        return info & Self.canRead != 0 ? registers[Int(address)] : 0
    }

    public mutating func writeData(_ value: UInt8) {
        let info = Self.registerInfo[Int(address)]
        if info & Self.canWrite != 0 {
            registers[Int(address)] = value & UInt8(truncatingIfNeeded: info)
        }
    }

    // MARK: Clock

    /// Advances one character clock.
    @inline(__always)
    public mutating func update(lightpen: Bool) -> Output {
        if lightpen && !oldLightpen {
            registers[17] = UInt8(truncatingIfNeeded: charAddress)
            registers[16] = UInt8(truncatingIfNeeded: charAddress >> 8)
        }
        oldLightpen = lightpen

        // Handle hsync.
        if hsyncCounter >= 0 {
            hsyncCounter = (hsyncCounter + 1) & 0xF
            if UInt8(hsyncCounter) == r3HSyncWidth {
                hsyncCounter = -1
            }
        }

        // Handle end of horizontal displayed.
        if column == registers[1] {
            // Latch next line address in case this is the last line of a
            // character row.
            nextLineAddress = charAddress
            hdisp = false
        }

        // The last column never displays.
        if column == registers[0] {
            hdisp = false
        }

        // Initiate hsync.
        if column == registers[2] && hsyncCounter < 0 {
            hsyncCounter = 0
        }

        // Handle vsync.
        let halfR0Hit = column == registers[0] >> 1
        let isVsyncPoint = !r8Interlace || !doEvenFrameLogic || halfR0Hit
        var vsyncEnding = false
        var vsyncStarting = false
        if vsyncCounter >= 0 && UInt8(vsyncCounter) == r3VSyncWidth && isVsyncPoint {
            vsyncEnding = true
            vsyncCounter = -1
        }
        if row == registers[7] && vsyncCounter < 0 && !hadVsyncThisRow && isVsyncPoint {
            vsyncStarting = true
        }

        // A vsync will initiate at any character and scanline position,
        // provided there isn't one in progress and there wasn't already one
        // in this character row.
        if vsyncStarting && !vsyncEnding {
            hadVsyncThisRow = true
            vsyncCounter = 0
        }

        let usedCharAddress = charAddress
        var output = Output()
        output.address = usedCharAddress & 0x3FFF
        output.raster = raster

        // MA always increments, display or not.
        charAddress &+= 1

        // The Hitachi 6845 decides to end (or never enter) vertical adjust
        // here, one clock after checking whether to enter it.
        if checkVadj {
            checkVadj = false
            if endOfMainLatched {
                if vadjCounter == Int8(registers[5]) {
                    endOfVadjLatched = true
                }
                vadjCounter = (vadjCounter + 1) & 0x1F
            }
        }

        // The Hitachi 6845 appears to latch some form of "last scanline of
        // the frame" state.
        if column == 1 {
            if row == registers[4] && raster == registers[9] {
                endOfMainLatched = true
                vadjCounter = 0
            }
            checkVadj = true
        }

        // Handle horizontal total.
        if column == registers[0] {
            endOfScanline()
            column = 0
            hdisp = true
        } else {
            if hdisp && vdisp {
                if r8DisplaySkew != 3 {
                    skewedDisplay |= 1 << r8DisplaySkew
                }

                if usedCharAddress == (UInt16(registers[14]) << 8 | UInt16(registers[15])) {
                    cursor = raster >= r10CursorStart && raster <= registers[11]
                    if cursor && r8CursorSkew != 3 {
                        switch r10CursorMode {
                        case 0: // on
                            skewedCudisp |= 1 << r8CursorSkew
                        case 1: // off
                            break
                        case 2: // blink, 8 frames on, 8 off
                            if numFrames & 8 != 0 {
                                skewedCudisp |= 1 << r8CursorSkew
                            }
                        default: // blink, 16 frames on, 16 off
                            if numFrames & 16 != 0 {
                                skewedCudisp |= 1 << r8CursorSkew
                            }
                        }
                    }
                }
            }
            column &+= 1
        }

        // Handle end of vertical displayed.
        let r6Hit = row == registers[6]
        if r6Hit && !firstScanline && vdisp {
            vdisp = false
            numFrames &+= 1
        }

        let r7Hit = row == registers[7]
        if r6Hit || r7Hit {
            doEvenFrameLogic = numFrames & 1 != 0
        }

        output.display = skewedDisplay & 1 != 0
        skewedDisplay >>= 1
        output.cudisp = skewedCudisp & 1 != 0
        skewedCudisp >>= 1
        output.hsync = hsyncCounter >= 0
        output.vsync = vsyncCounter >= 0
        return output
    }

    private mutating func endOfFrame() {
        row = 0
        firstScanline = true
        nextLineAddress = UInt16(registers[12]) << 8 | UInt16(registers[13])
        lineAddress = nextLineAddress
        vdisp = true
        hdisp = false
        if vsyncCounter < 0 {
            doEvenFrameLogic = false
        }
    }

    private mutating func endOfRow() {
        row &+= 1
        raster = 0
        hadVsyncThisRow = false
    }

    private mutating func endOfScanline() {
        firstScanline = false

        if vsyncCounter >= 0 {
            vsyncCounter = (vsyncCounter + 1) & 0xF
        }

        // Increment scanline and check R9.
        let r9Hit: Bool
        if r8Interlace && r8Video {
            // Judging by MODE7:?&FE00=9:?&FE01=17, the real hardware must do
            // something similar when comparing.
            r9Hit = raster >> 1 == registers[9] >> 1
            raster &+= 2
        } else {
            r9Hit = raster == registers[9]
            raster &+= 1
        }
        raster &= 0x1F

        if r9Hit {
            lineAddress = nextLineAddress
        }

        if !inVadj && r9Hit {
            endOfRow()
        }

        if endOfMainLatched && !endOfVadjLatched {
            inVadj = true
        }

        var endOfFrameNow = endOfFrameLatched
        if endOfVadjLatched {
            inVadj = false
            if r8Interlace && doEvenFrameLogic {
                inDummyRaster = true
                endOfFrameLatched = true
            } else {
                endOfFrameNow = true
            }
        }

        if endOfFrameNow {
            endOfMainLatched = false
            endOfVadjLatched = false
            endOfFrameLatched = false
            inDummyRaster = false
            endOfRow()
            endOfFrame()
        }

        charAddress = lineAddress
    }
}
