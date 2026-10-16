// swift-tools-version: 6.0
// Created by Amirali Yazdani on 10/16/26.
import PackageDescription

let package = Package(
    name: "MultiPascalMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MPWinCore", targets: ["MPWinCore"]),
        .executable(name: "mpwin", targets: ["mpwin"]),
        .executable(name: "MultiPascalMac", targets: ["MultiPascalMac"]),
    ],
    targets: [
        .target(name: "MPWinCore"),
        .executableTarget(name: "mpwin", dependencies: ["MPWinCore"]),
        .executableTarget(
            name: "MultiPascalMac",
            dependencies: ["MPWinCore"],
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            linkerSettings: [
                // Embeds Info.plist directly into the binary's __TEXT,__info_plist
                // section. Without this, running the raw executable (which is what
                // Xcode's default scheme for a SwiftPM executable target does) has
                // no CFBundleIdentifier, which breaks window-tab restoration, the
                // Intents/Shortcuts registration, and NSApplication's activation
                // handling — the process never reliably becomes the frontmost,
                // key-focused app, so the editor can appear "stuck" and refuse
                // keyboard input. Embedding the plist fixes this even without
                // wrapping the binary in a full .app bundle (BuildMacApp.command
                // still does that for a distributable, double-clickable app).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MultiPascalMac/Info.plist",
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(name: "MPWinCoreTests", dependencies: ["MPWinCore"]),
    ]
)
