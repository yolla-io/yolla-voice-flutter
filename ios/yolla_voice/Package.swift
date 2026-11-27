// swift-tools-version: 5.9
//
// Copyright (c) 2026 Yolla Calls International OÜ. All rights reserved.
// Author: Sergei Popov
//
// The iOS side of the Yolla Voice plugin for Flutter.

import PackageDescription

// The Yolla Voice iOS SDK this plugin wraps: the binary package from GitHub. For work on the SDK and the plugin
// together, `YOLLA_VOICE_IOS_SDK_PATH=<checkout of the SDK's sources>` in the environment of the build
// (`flutter build ios`, `flutter run`) takes the SDK from that checkout instead.
let localSDK = Context.environment["YOLLA_VOICE_IOS_SDK_PATH"].flatMap { $0.isEmpty ? nil : $0 }
let sdk: Package.Dependency = localSDK.map { .package(name: "yolla-voice-ios", path: $0) }
    ?? .package(url: "https://github.com/yolla-io/yolla-voice-ios", from: "0.1.1")

let package = Package(
    name: "yolla_voice",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .library(name: "yolla-voice", targets: ["yolla_voice"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        sdk,
    ],
    targets: [
        .target(
            name: "yolla_voice",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "YollaVoiceSDK", package: "yolla-voice-ios"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
