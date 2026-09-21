import UIKit
import React
import React_RCTAppDelegate
import ReactAppDependencyProvider

/// UIScene entry point. Apps built with the iOS 27 SDK must adopt the scene lifecycle:
/// UIKit traps at launch (EXC_BREAKPOINT in
/// ___UIApplicationEvaluateRuntimeIssueForNoSceneLifecycleAdoption) when an iOS 27 SDK
/// build has no UIApplicationSceneManifest. 0.3.9 (15), the first Xcode 27 build, crashed on
/// every cold start because of this. The window and React Native root are created here
/// instead of in AppDelegate; AppDelegate keeps ownership of the factory so the rest of the
/// app is unchanged.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let windowScene = scene as? UIWindowScene else { return }
    guard let appDelegate = UIApplication.shared.delegate as? AppDelegate else { return }

    let window = UIWindow(windowScene: windowScene)
    appDelegate.reactNativeFactory.startReactNative(
      withModuleName: "OpenRung",
      in: window,
      launchOptions: appDelegate.launchOptions
    )
    self.window = window
    appDelegate.window = window
  }
}
