// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "macbeeb",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BeebCore", targets: ["BeebCore"]),
        .executable(name: "beeb-bench", targets: ["beeb-bench"]),
        .executable(name: "m6502-gen", targets: ["m6502-gen"]),
    ],
    targets: [
        // The emulation core: pure Swift, no UI or platform frameworks.
        //
        // Runtime exclusivity checks on class properties cost ~6x in the
        // per-cycle hot loop, so they're off for the core. (Compile-time
        // checks still apply.)
        .target(
            name: "BeebCore",
            swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked"])]
        ),

        // 6502 state machine generator. Run `swift run m6502-gen` after
        // changing M6502GenKit; a test checks the output is up to date.
        .target(name: "M6502GenKit"),
        .executableTarget(name: "m6502-gen", dependencies: ["M6502GenKit"]),

        .executableTarget(name: "beeb-bench", dependencies: ["BeebCore"]),

        .testTarget(
            name: "BeebCoreTests",
            dependencies: ["BeebCore", "M6502GenKit"],
            resources: [.copy("Resources")]
        ),

        // perfect6502 (MIT): a transistor-level NMOS 6502 simulation, used
        // only as a test oracle.
        .target(
            name: "Perfect6502",
            path: "Tests/Perfect6502",
            exclude: ["LICENSE", "README.md"],
            cSettings: [.unsafeFlags(["-O2", "-w"])]
        ),
        .testTarget(
            name: "Oracle6502Tests",
            dependencies: ["BeebCore", "Perfect6502"]
        ),
    ]
)
