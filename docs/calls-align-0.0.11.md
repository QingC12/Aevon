| 判定 | 调用 | 母本自有 | 逆向记录 | 本机实测 |
|---|---|---|---|---|
| PRESENT | `__swift_objectForKeyedSubscript:` |  | NSDictionary NSMutableDictionary | @24@0:8@16 @24@0:8@16 |
| PRESENT | `_activateBundleID:requestID:isTrusted:options:source:originalSource:withResult:` |  | FBSystemService | v68@0:8@16@24B32@36@44@52@?60 |
| PRESENT | `_addAppLayoutToFront:` |  | SBMainSwitcherControllerCoordinator | v24@0:8@16 |
| PRESENT | `_applicationIconImageForBundleIdentifier:format:scale:` |  | UIImage | @36@0:8@16i24d28 |
| MATCH | `_createSceneWithDefinition:settings:initialClientSettings:transitionContext:fromRemnant:usingClientProvider:completion:` |  | FBSceneManager | @72@0:8@16@24@32@40@48@56@?64 |
| PRESENT | `_didExitWithContext:` |  | SBApplication | v24@0:8@16 |
| OUT-OF-SCOPE | `_dismissPresentable:withReason:animated:userInfo:` |  | - | - |
| PRESENT | `_handleClickAndDragHomeGesture:` |  | SBFluidSwitcherGestureManager | v24@0:8@16 |
| PRESENT | `_handleDeckSwitcherPanGesture:` |  | SBFluidSwitcherGestureManager | v24@0:8@16 |
| PRESENT | `_handlePan:` |  | _UISheetPresentationInteraction UIKeyboardCameraOverlayPresentationController UIPopoverPresentationController | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| PRESENT | `_handlePullGesture:` |  | SBGrabberTongue | v24@0:8@16 |
| OUT-OF-SCOPE | `_handleTapOnView:` |  | - | - |
| PRESENT | `_killForReason:andReport:withDescription:completion:` |  | FBProcess | v44@0:8q16B24@28@?36 |
| MATCH | `_scene:interceptUpdateWithNewSettings:` |  | v32@0:8@16@24 | v32@0:8@16@24 |
| MATCH | `_setDeactivationReasons:onScene:withSettings:reason:` |  | v48@0:8Q16@24@32@40 | v48@0:8Q16@24@32@40 |
| PRESENT | `addObserverForName:object:queue:usingBlock:` |  | NSNotificationCenter NSDistributedNotificationCenter | @48@0:8@16@24@32@?40 @48@0:8@16@24@32@?40 |
| PRESENT | `applicationDidFinishLaunching:` |  | SpringBoard | v24@0:8@16 |
| PRESENT | `applicationProxyForIdentifier:` |  | LSApplicationProxy | @24@0:8@16 |
| MATCH | `applicationWithBundleIdentifier:` |  | SBApplicationController | @24@0:8@16 |
| PRESENT | `bezierPathWithRoundedRect:cornerRadius:` |  | UIBezierPath | @56@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16d48 |
| PRESENT | `client:didUpdateClientSettings:withDiff:transitionContext:` |  | FBScene | v48@0:8@16@24@32@40 |
| PRESENT | `closeAndReturnError:` |  | NSFileHandle NSNullFileHandle NSConcreteFileHandle | B24@0:8o^@16 B24@0:8o^@16 B24@0:8o^@16 |
| PRESENT | `conformsToProtocol:` |  | NSProxy NSProxy NSProtocolChecker | B24@0:8@16 B24@0:8@16 B24@0:8@16 |
| PRESENT | `containsPoint:` |  | UIPDFAnnotation UIRegion NSTextContainer | B32@0:8{CGPoint=dd}16 B32@0:8{CGPoint=dd}16 B32@0:8{CGPoint=dd}16 |
| PRESENT | `createFileAtPath:contents:attributes:` |  | NSFileManager | B40@0:8@16@24@32 |
| MATCH | `createPresenterWithIdentifier:priority:` |  | UIScenePresentationManager | @32@0:8@16q24 |
| PRESENT | `dataWithJSONObject:options:error:` |  | NSJSONSerialization | @40@0:8@16Q24^@32 |
| MATCH | `deactivateWithTransitionContext:` |  | FBScene | v24@0:8@16 |
| PRESENT | `dictionaryWithObject:forKey:` |  | NSDictionary | @32@0:8@16@24 |
| PRESENT | `displayItemWithType:bundleIdentifier:uniqueIdentifier:` |  | SBDisplayItem | @40@0:8q16@24@32 |
| PRESENT | `enumerateApplicationsOfType:block:` |  | LSApplicationWorkspace | v32@0:8Q16@?24 |
| MATCH | `enumerateScenesWithBlock:` |  | FBSceneManager | v24@0:8@?16 |
| PRESENT | `fileExistsAtPath:` |  | NSFileManager | B24@0:8@16 |
| PRESENT | `fileHandleForWritingAtPath:` |  | NSFileHandle | @24@0:8@16 |
| PRESENT | `frontDisplayDidChange:` |  | SpringBoard | v24@0:8@16 |
| PRESENT | `functionWithName:` |  | CAValueFunction CAMediaTimingFunction | @24@0:8@16 @24@0:8@16 |
| PRESENT | `gestureRecognizer:shouldBeRequiredToFailByGestureRecognizer:` |  | _UIPassthroughScrollInteraction _UIForceClickInteractionDriver UIWindowSceneActivationInteraction | B32@0:8@16@24 B32@0:8@16@24 B32@0:8@16@24 |
| PRESENT | `gestureRecognizer:shouldReceiveEvent:` |  | _UIContextMenuPanController | B32@0:8@16@24 |
| OUT-OF-SCOPE | `gestureRecognizer:shouldReceivePress:` |  | - | - |
| PRESENT | `gestureRecognizer:shouldReceiveTouch:` |  | SBHomeScreenOverlayController SBInteractiveScreenshotGestureManager SBPIPInteractionController | B32@0:8@16@24 B32@0:8@16@24 B32@0:8@16@24 |
| PRESENT | `gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:` |  | SBPIPInteractionController SBUISystemApertureElementSource _UIPassthroughScrollInteraction | B32@0:8@16@24 B32@0:8@16@24 B32@0:8@16@24 |
| PRESENT | `gestureRecognizer:shouldRequireFailureOfGestureRecognizer:` |  | _UIPassthroughScrollInteraction _UIFocusEventRecognizer UISplitViewControllerPanelImpl | B32@0:8@16@24 B32@0:8@16@24 B32@0:8@16@24 |
| PRESENT | `gestureRecognizerShouldBegin:` | 是 | SBHomeScreenOverlayController SBInteractiveScreenshotGestureManager SBPIPInteractionController | B24@0:8@16 B24@0:8@16 B24@0:8@16 |
| PRESENT | `handleTransitionRequestForGestureComplete:` |  | SBFluidSwitcherGestureManager | v24@0:8@16 |
| PRESENT | `hasSuffix:` |  | NSString NSSimpleCString | B24@0:8@16 B24@0:8@16 |
| PRESENT | `hitTest:withEvent:` | 是 | _UIFlocker UIView SBPortalView | @40@0:8{CGPoint=dd}16@32 @40@0:8{CGPoint=dd}16@32 @40@0:8{CGPoint=dd}16@32 |
| OUT-OF-SCOPE | `iconManager:launchIconForIconView:withActions:` |  | - | - |
| PRESENT | `impactOccurredWithIntensity:` |  | UIImpactFeedbackGenerator _UIFeedbackImpactBehavior | v24@0:8d16 v24@0:8d16 |
| PRESENT | `initWithArray:` |  | SBSHomeScreenServiceArrayOfNumbers SBSHomeScreenServiceArrayOfStrings NSOrderedSet | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `initWithCGImage:scale:orientation:` |  | UIImage | @40@0:8^{CGImage=}16d24q32 |
| PRESENT | `initWithCoder:` | 是 | NSSSizeVector NSSUsageBundleCategory NSSUsageBundle | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `initWithFrame:` | 是 | UIKBWatch10KeyLayout _UIFocusRegion _UIFocusSpeedBumpRegion | @48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16 @48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16 @48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16 |
| PRESENT | `initWithImage:` |  | _UIImageSerializationWrapper _UICellAccessoryConfigurationOutlineDisclosure SBUISystemApertureImageContentProvider | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `initWithItemsForLayoutRoles:configuration:environment:preferredDisplayOrdinal:` |  | SBAppLayout | @48@0:8@16q24q32q40 |
| PRESENT | `initWithPath:` |  | NSFileWatcherObservations NSHTTPCookie2Storage NSPersistentHTTPCookie2Storage | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| MATCH | `initWithSceneLayer:` |  | _UIContextLayerHostView | @24@0:8@16 |
| PRESENT | `initWithString:` |  | NSURLSessionWebSocketMessage _UIFocusDebuggerStringOutput CATAddress | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `initWithStyle:` |  | UISSlotStyle SBLockOverlayStylePropertiesFactory SBUILegibilitySettings | @24@0:8@16 @24@0:8Q16 @24@0:8q16 |
| PRESENT | `initWithSuiteName:` |  | NSUserDefaults | @24@0:8@16 |
| PRESENT | `initWithTarget:` |  | CATStateMachine UIAnimation UIFrameAnimation | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `initWithURL:` |  | SBCursiveTextPath SBLockScreenPluginCallAction NSURLRequest | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `initWithURL:workspaceOriginatingProcess:` |  | UISOpenURLAction | @32@0:8@16@24 |
| PRESENT | `initWithWindowScene:` | 是 | SBExternalDisplayWallpaperController SBFluidSwitcherModifierTimelineController SBExternalDisplayCoverSheetController | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `insertSubview:atIndex:` |  | UIView SBFTouchPassThroughClippingView | v32@0:8@16q24 v32@0:8@16q24 |
| OUT-OF-SCOPE | `isApplicationForeground:` |  | - | - |
| PRESENT | `isApplicationRunningAsViewService:` |  | SBMainWorkspace | B24@0:8@16 |
| PRESENT | `isEqual:` |  | NSProxy NSProxy _UIActivityPlaceholderItemProxy | B24@0:8@16 B24@0:8@16 B24@0:8@16 |
| PRESENT | `isKindOfClass:` |  | NSProxy NSProxy NSUndoManagerProxy | B24@0:8#16 B24@0:8#16 B24@0:8#16 |
| PRESENT | `isMemberOfClass:` |  | NSProxy NSProxy FBSComponentScene | B24@0:8#16 B24@0:8#16 B24@0:8#16 |
| PRESENT | `launchApplicationWithIdentifier:suspended:` |  | UIApplication SpringBoard | B28@0:8@16B24 B28@0:8@16B24 |
| PRESENT | `loadNibNamed:owner:options:` |  | NSBundle | @40@0:8@16@24@32 |
| PRESENT | `localizedStringForKey:value:table:` |  | NSBundle | @40@0:8@16@24@32 |
| PRESENT | `locationInView:` |  | _UIScrollViewMockPanGestureRecognizer UIKBTouchState UIKeyboardSyntheticTouch | {CGPoint=dd}24@0:8@16 {CGPoint=dd}24@0:8@16 {CGPoint=dd}24@0:8@16 |
| OUT-OF-SCOPE | `materialViewWithRecipe:configuration:initialWeighting:` |  | - | - |
| PRESENT | `noteActiveInterfaceOrientationWillChangeToOrientation:` |  | UIApplication UISystemShellApplication | v24@0:8q16 v24@0:8q16 |
| PRESENT | `numberWithInt:` |  | NSNumber NSDecimalNumber | @20@0:8i16 @20@0:8i16 |
| PRESENT | `objectAtIndexedSubscript:` |  | NSOrderedSet NSArray NSConstantArray | @24@0:8Q16 @24@0:8Q16 @24@0:8Q16 |
| PRESENT | `objectForInfoDictionaryKey:` |  | NSExtension NSBundle | @24@0:8@16 @24@0:8@16 |
| PRESENT | `pathForResource:ofType:` |  | NSBundle | @32@0:8@16@24 |
| PRESENT | `performSelector:` |  | NSProxy NSProxy NSObject | @24@0:8:16 @24@0:8:16 @24@0:8:16 |
| PRESENT | `performSelector:withObject:` |  | NSProxy NSProxy NSObject | @32@0:8:16@24 @32@0:8:16@24 @32@0:8:16@24 |
| PRESENT | `performSelector:withObject:withObject:` |  | NSProxy NSProxy NSObject | @40@0:8:16@24@32 @40@0:8:16@24@32 @40@0:8:16@24@32 |
| OUT-OF-SCOPE | `presentPresentable:withOptions:userInfo:` |  | - | - |
| PRESENT | `removePersistentDomainForName:` |  | NSUserDefaults | v24@0:8@16 |
| PRESENT | `respondsToSelector:` |  | NSProxy NSProxy _UIQueueingProxy | B24@0:8:16 B24@0:8:16 B24@0:8:16 |
| PRESENT | `setAnimationSettings:` |  | SBSwitcherTransitionRequest SBPasscodeKeyboardAnimator SBWorkspaceTransitionContext | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| PRESENT | `setAutoresizingMask:` |  | UIView | v24@0:8Q16 |
| PRESENT | `setBackgroundColor:` |  | NSRTFReader NSTextBlock _UIContextMenuBackgroundDescriptor | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| PRESENT | `setCancelsTouchesInView:` |  | _UIForceClickInteractionDriver _UITouchDownClickInteractionDriver _UISecondaryClickClickInteractionDriver | v20@0:8B16 v20@0:8B16 v20@0:8B16 |
| PRESENT | `setClipsToBounds:` |  | SBMainWorkspaceApplicationSceneLayoutElementViewController UIView _UIImageViewOverlayView | v20@0:8B16 v20@0:8B16 v20@0:8B16 |
| PRESENT | `setContentMode:` |  | UIWebClip UIView UIStatusBarItemView | v24@0:8Q16 v24@0:8q16 v24@0:8q16 |
| PRESENT | `setContentScaleFactor:` |  | UIView UIKBKeyplaneView UIKeyboardEmojiCollectionInputView | v24@0:8d16 v24@0:8d16 v24@0:8d16 |
| PRESENT | `setDateFormat:` |  | NSDateFormatter | v24@0:8@16 |
| PRESENT | `setForeground:` |  | SBSceneSettingsUpdater FBSSceneSettingsCore FBSSceneSettings | v20@0:8B16 v20@0:8B16 v20@0:8B16 |
| PRESENT | `setFrame:` |  | SBSwitcherLayoutCalculations FBSSceneSnapshotContext _UIStackedImageSimpleImage | v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16 v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16 v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16 |
| OUT-OF-SCOPE | `setHandleClick:` |  | - | - |
| PRESENT | `setHidden:` |  | SBLockScreenPluginAppearanceContext SBLockScreenElementOverride NSFileProviderDomain | v20@0:8B16 v20@0:8B16 v20@0:8B16 |
| PRESENT | `setImage:` |  | UIIndexBarEntry UIIndexBarDisplayEntry_LegacyIOS _UIContentViewImageViewConfiguration | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| PRESENT | `setInterfaceOrientation:` |  | BKSDisplayRenderOverlayDescriptor UIInputResponderController XBLaunchStateRequest | v24@0:8q16 v24@0:8q16 v24@0:8q16 |
| PRESENT | `setInterfaceOrientationMode:` |  | UIMutableApplicationSceneSettings | v24@0:8q16 |
| PRESENT | `setResizesHostedContext:` |  | SBShelfLiveContentOverlay SBFluidSwitcherPortaledSceneLiveContentOverlay SBFluidSwitcherAppClipLiveContentOverlay | v20@0:8B16 v20@0:8B16 v20@0:8B16 |
| PRESENT | `setRootViewController:` |  | SBExternalDisplayCoverSheetController SBIconController SBHIconManager | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| PRESENT | `setState:` |  | SBPressGestureStateInfo SBIconDragContext BKSAlternateSystemApp | v24@0:8q16 v24@0:8q16 v24@0:8q16 |
| PRESENT | `setUserInteractionEnabled:` |  | UIViewPropertyAnimatorTrackingState UISliderDataModel _UIFluidSliderInteraction | v20@0:8B16 v20@0:8B16 v20@0:8B16 |
| PRESENT | `setUserInterfaceStyle:` |  | UISMutableSlotStyle _UIPopoverHostManagerPopoverCreationConfiguration _UIKeyShortcutHUDClientTraits | v24@0:8Q16 v24@0:8q16 v24@0:8q16 |
| PRESENT | `setWindowLevel:` |  | SBWallpaperController UIWindow UIRemoteKeyboardWindow | v24@0:8d16 v24@0:8d16 v24@0:8d16 |
| PRESENT | `setWindowScene:` |  | SBMutableTransientOverlayPresentationRequest SBPIPContentContext SBRemoteTransientOverlayPresentationRequest | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| OUT-OF-SCOPE | `settingsWithDuration:timingFunction:` |  | - | - |
| PRESENT | `storyboardWithName:bundle:` |  | UIStoryboard | @32@0:8@16@24 |
| PRESENT | `stringFromDate:` |  | NSISO8601DateFormatter NSDateFormatter | @24@0:8@16 @24@0:8@16 |
| PRESENT | `stringWithFormat:` |  | NSString | @24@0:8@16 |
| PRESENT | `stringWithUTF8String:` |  | NSString | @24@0:8r*16 |
| PRESENT | `touchesBegan:withEvent:` |  | _UIDigitizerGestureRecognizerImp UITapRecognizer UIGestureRecognizer | v32@0:8@16@24 v32@0:8@16@24 v32@0:8@16@24 |
| PRESENT | `touchesCancelled:withEvent:` |  | _UIDigitizerGestureRecognizerImp UITapRecognizer UIGestureRecognizer | v32@0:8@16@24 v32@0:8@16@24 v32@0:8@16@24 |
| PRESENT | `touchesEnded:withEvent:` |  | _UIDigitizerGestureRecognizerImp UITapRecognizer UIGestureRecognizer | v32@0:8@16@24 v32@0:8@16@24 v32@0:8@16@24 |
| PRESENT | `touchesMoved:withEvent:` |  | _UIDigitizerGestureRecognizerImp UITapRecognizer UIGestureRecognizer | v32@0:8@16@24 v32@0:8@16@24 v32@0:8@16@24 |
| PRESENT | `translationInView:` |  | _UIScrollViewMockPanGestureRecognizer SBHomeGestureInteraction SBFluidScrunchGestureRecognizer | {CGPoint=dd}24@0:8@16 {CGPoint=dd}24@0:8@16 {CGPoint=dd}24@0:8@16 |
| PRESENT | `uninstallApplication:` |  | SBApplicationController | v24@0:8@16 |
| PRESENT | `updateSettings:withTransitionContext:completion:` |  | FBScene | v40@0:8@16@24@?32 |
| PRESENT | `valueForKey:` |  | NSObject NSMetadataItem CAEmitterBehavior | @24@0:8@16 @24@0:8@16 @24@0:8@16 |
| PRESENT | `velocityInView:` |  | _UIScrollViewMockPanGestureRecognizer _UIFocusEngineFakePanGestureRecognizer SBHomeGestureInteraction | {CGPoint=dd}24@0:8@16 {CGPoint=dd}24@0:8@16 {CGPoint=dd}24@0:8@16 |
| PRESENT | `writeData:` |  | NSFileHandle NSNullFileHandle NSConcreteFileHandle | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
| PRESENT | `zStackParticipantDidChange:` |  | SBExternalDisplayWallpaperController SBPlatterHomeGestureContext SBDashBoardHomeAffordanceControllerClientBridge | v24@0:8@16 v24@0:8@16 v24@0:8@16 |
