# TapCub (iOS)

TapCub analytics SDK for iOS 13+ / tvOS 13+, Swift 5.9. Works with SwiftPM and CocoaPods; Objective-C code uses `TapCubSDK`.

## Install

SwiftPM: in Xcode, choose Add Package Dependencies, enter `https://github.com/tapcub/tapcub-ios` and pick the `TapCub` product.

CocoaPods:

```ruby
pod 'TapCub', :git => 'https://github.com/tapcub/tapcub-ios.git', :tag => '0.1.0'
```

## Quick start

```swift
import TapCub

func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    // Only stores the config and hooks lifecycles: no collection, no device reads, no network
    TapCub.preInit(TapCubConfig(siteKey: "s_xxx"))
    return true
}

// After the user accepts the privacy policy (call right after preInit if the site does not require consent)
TapCub.initialize()
```

`appId`, `appVersion` and `appBuild` default to the values in Info.plist. Call `preInit` on the main thread.

## Common calls

```swift
TapCub.track("checkout", props: ["amount": 99.0, "currency": "CNY"])
TapCub.trackScreen("Checkout")
TapCub.login("u_123")                      // type: login | email | mobile | unionid | openid | custom
TapCub.setProps(["plan": "pro"])           // user properties
TapCub.registerSuperProps(["channel": "appstore"])
TapCub.grantConsent(["analytics"])         // analytics | functional | marketing
TapCub.optOut()
TapCub.trackPurchase(["product_id": "vip_month", "amount": 30, "currency": "CNY"])
TapCub.trackDeeplink(url.absoluteString)
TapCub.flush()
let did = TapCub.getDeviceId()
```

Every call runs on the SDK's own serial queue, so it can be made from any thread and returns immediately. Callbacks (`onConsentChange`, `onSessionStart`, `onError`, `initialize(completion:)`) run on the main thread.

## Automatic collection

| Event | Source | How to turn off |
| --- | --- | --- |
| `$app_start` / `$app_end`, sessions | Foreground / background notifications | Always on |
| `$screen_view` | UIViewController `viewDidAppear` (skips containers, child controllers, system classes and alerts) | `autoTrackScreens: false` |
| `$app_click` | `UIApplication.sendAction` and tap gestures | `autoTrack: false` or remote config |
| `$app_crashed` | Mach signals and NSException, reported on the next launch with the original crash time | `crashReport: false` |
| `$ui_freeze` | Main thread blocked for ≥ 2 s | Same as above |
| `$fps_sample` / `$memory_sample` | Once per session, 10 s of sampling | `perf: true` or remote `rc.perf` |

Launch time is in `$duration_ms` on `$app_start` (cold starts only, prewarmed launches are excluded). On iOS 14+ the SDK also receives MetricKit crash and hang diagnostics and de-duplicates them against crashes it recorded itself.

Screen names and click customization:

```swift
final class OrderVC: UIViewController, TapCubScreenNaming {
    var wcScreenName: String? { "Order" }      // defaults to the class name
}
TapCub.ignoreScreen(SplashVC.self)

buyButton.tapcubElementId = "buy"                  // defaults to accessibilityIdentifier
secretField.wcIgnoreClicks = true

// SwiftUI views are not collected automatically
Text("Checkout").wcScreen("Checkout")
```

Crash stacks are recorded as `image name + 0x offset`; symbolication needs the dSYM for the matching build.

## Storage and privacy

- Plain keys go to UserDefaults (prefix `tapcub.`); the event queue is one file per chunk under `Application Support/TapCub/queue`, excluded from iCloud backup and capped by default at 8 MB / 10,000 events / 7 days.
- Device ID: `ios_idfv:<IDFV>`, mirrored to the keychain so it survives reinstalls. After `reset()` a new ID is generated and the SDK no longer falls back to the IDFV.
- The IDFA is never read, so no ATT prompt is needed. `PrivacyInfo.xcprivacy` ships with the package: UserDefaults reason `CA92.1`, system boot time reason `35F9.1` (hang detection timing); collected data types are device ID, product interaction, crash data and performance data, none linked to identity or used for tracking. If you call `login`, add User ID to your app's own privacy manifest.

## Objective-C

```objc
@import TapCub;
[TapCubSDK preInitWithSiteKey:@"s_xxx" endpoint:nil appId:nil];
[TapCubSDK start];
[TapCubSDK track:@"checkout" properties:@{@"amount": @99}];
```

## Development

In the SDK root (the directory with `Package.swift`):

```bash
swift test        # shared vectors + adapter tests, runs on macOS
swift build --triple arm64-apple-ios13.0-simulator --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" --target TapCub
```

`Sources/TapCubCore` is a line-by-line port of the TypeScript core (`packages/app-sdk/src/core` in [tapcub-sdk](https://github.com/tapcub/tapcub-sdk)): change the vectors and the TS first, then port the change here. Brand constants live in `Sources/TapCub/Brand.swift`.
