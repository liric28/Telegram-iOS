import Foundation
import UIKit
import Postbox
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import MediaResources
import WallpaperResources
import AccountContext

private final class ThemeUpdateManagerContext {
    let themeReference: PresentationThemeReference
    private let disposable: Disposable
    let isAutoNight: Bool
    
    init(themeReference: PresentationThemeReference, disposable: Disposable, isAutoNight: Bool) {
        self.themeReference = themeReference
        self.disposable = disposable
        self.isAutoNight = isAutoNight
    }
    
    deinit {
        self.disposable.dispose()
    }
}

final class ThemeUpdateManagerImpl: ThemeUpdateManager {
    private let sharedContext: SharedAccountContext
    private let account: Account
    private var contexts: [Int64: ThemeUpdateManagerContext] = [:]
    private let queue = Queue()
    
    private var disposable: Disposable?
    private var currentThemeSettings: PresentationThemeSettings?
    
    init(sharedContext: SharedAccountContext, account: Account) {
        self.sharedContext = sharedContext
        self.account = account
        
        self.disposable = (sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.presentationThemeSettings])
        |> map { sharedData -> PresentationThemeSettings in
            return (sharedData.entries[ApplicationSpecificSharedDataKeys.presentationThemeSettings] as? PresentationThemeSettings) ?? PresentationThemeSettings.defaultSettings
        }
        |> deliverOn(queue)).start(next: { [weak self] themeSettings in
            self?.presentationThemeSettingsUpdated(themeSettings)
        })
    }
    
    deinit {
        self.disposable?.dispose()
    }
    
    private func presentationThemeSettingsUpdated(_ themeSettings: PresentationThemeSettings) {
        let previousThemeSettings = self.currentThemeSettings
        self.currentThemeSettings = themeSettings
        
        var previousIds = Set<Int64>()
        if let previousThemeSettings = previousThemeSettings {
            previousIds.insert(previousThemeSettings.theme.index)
        }
        
        var validIds = Set<Int64>()
        var themes: [Int64: (PresentationThemeReference, Bool)] = [:]
        if case .cloud = themeSettings.theme {
            validIds.insert(themeSettings.theme.index)
            themes[themeSettings.theme.index] = (themeSettings.theme, false)
        }
        
        if previousIds != validIds {
            for id in validIds {
                if let _ = self.contexts[id] {
                } else if let (theme, isAutoNight) = themes[id], case let .cloud(info) = theme {
                    var currentTheme = theme
                    let account = self.account
                    let accountManager = self.sharedContext.accountManager
                    let disposable = (actualizedTheme(account: account, accountManager: accountManager, theme: info.theme)
                    |> mapToSignal { theme -> Signal<(PresentationThemeReference, PresentationTheme?), NoError> in
                        guard let file = theme.file else {
                            return .complete()
                        }
                        return telegramThemeData(account: account, accountManager: accountManager, resource: file.resource)
                        |> mapToSignal { data -> Signal<(PresentationThemeReference, PresentationTheme?), NoError> in
                            guard let data = data, let presentationTheme = makePresentationTheme(data: data) else {
                                return .complete()
                            }
                            
                            let resolvedWallpaper: Signal<TelegramWallpaper?, NoError>
                            if case let .file(file) = presentationTheme.chat.defaultWallpaper, file.id == 0 {
                                resolvedWallpaper = cachedWallpaper(account: account, slug: file.slug)
                                |> map { wallpaper in
                                    return wallpaper?.wallpaper
                                }
                            } else {
                                resolvedWallpaper = .single(nil)
                            }
                            
                            return resolvedWallpaper
                            |> mapToSignal { wallpaper -> Signal<(PresentationThemeReference, PresentationTheme?), NoError> in
                                if let wallpaper = wallpaper, case let .file(file) = wallpaper {
                                    var convertedRepresentations: [ImageRepresentationWithReference] = []
                                    convertedRepresentations.append(ImageRepresentationWithReference(representation: TelegramMediaImageRepresentation(dimensions: CGSize(width: 100.0, height: 100.0), resource: file.file.resource), reference: .media(media: .standalone(media: file.file), resource: file.file.resource)))
                                    return wallpaperDatas(account: account, accountManager: accountManager, fileReference: .standalone(media: file.file), representations: convertedRepresentations, alwaysShowThumbnailFirst: false, thumbnail: false, onlyFullSize: true, autoFetchFullSize: true, synchronousLoad: false)
                                    |> mapToSignal { _, fullSizeData, complete -> Signal<(PresentationThemeReference, PresentationTheme?), NoError> in
                                        guard complete, let fullSizeData = fullSizeData else {
                                            return .complete()
                                        }
                                        accountManager.mediaBox.storeResourceData(file.file.resource.id, data: fullSizeData)
                                        return .single((.cloud(PresentationCloudTheme(theme: theme, resolvedWallpaper: wallpaper)), presentationTheme))
                                    }
                                } else {
                                    return .single((.cloud(PresentationCloudTheme(theme: theme, resolvedWallpaper: nil)), presentationTheme))
                                }
                            }
                        }
                    }).start(next: { updatedTheme, presentationTheme in
                        if updatedTheme != currentTheme {
                            currentTheme = updatedTheme
                            
                            let _ = (accountManager.transaction { transaction -> Void in
                                transaction.updateSharedData(ApplicationSpecificSharedDataKeys.presentationThemeSettings, { entry in
                                    let current: PresentationThemeSettings
                                    if let entry = entry as? PresentationThemeSettings {
                                        current = entry
                                    } else {
                                        current = PresentationThemeSettings.defaultSettings
                                    }
                                    
                                    let chatWallpaper: TelegramWallpaper
                                    if let themeSpecificWallpaper = current.themeSpecificChatWallpapers[updatedTheme.index] {
                                        chatWallpaper = themeSpecificWallpaper
                                    } else if let presentationTheme = presentationTheme {
                                        if case let .cloud(info) = updatedTheme, let resolvedWallpaper = info.resolvedWallpaper {
                                            chatWallpaper = resolvedWallpaper
                                        } else {
                                            chatWallpaper = presentationTheme.chat.defaultWallpaper
                                        }
                                    } else {
                                        chatWallpaper = current.chatWallpaper
                                    }
                                    
                                    return PresentationThemeSettings(chatWallpaper: chatWallpaper, theme: updatedTheme, themeSpecificAccentColors: current.themeSpecificAccentColors, themeSpecificChatWallpapers: current.themeSpecificChatWallpapers, fontSize: current.fontSize, automaticThemeSwitchSetting: current.automaticThemeSwitchSetting, largeEmoji: current.largeEmoji, disableAnimations: current.disableAnimations)
                                })
                            }).start()
                        }
                    })
                    self.contexts[id] = ThemeUpdateManagerContext(themeReference: theme, disposable: disposable, isAutoNight: isAutoNight)
                }
            }
            
            for id in previousIds {
                if !validIds.contains(id) {
                    self.contexts[id] = nil
                }
            }
        }
    }
}