//
//  BoringHeader.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Defaults
import SwiftUI

struct BoringHeader: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var batteryModel = BatteryStatusViewModel.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @StateObject var tvm = ShelfStateViewModel.shared
    var body: some View {
        HStack(spacing: 0) {
            HStack {
                if tabs.count > 1 && (!tvm.isEmpty || coordinator.alwaysShowTabs || Defaults[.clipboardHistoryEnabled] || Defaults[.todayTabEnabled] || Defaults[.notchNotificationsEnabled] || Defaults[.quickNotesEnabled] || Defaults[.tasksEnabled]) {
                    TabSelectionView()
                } else if vm.notchState == .open {
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)

            if vm.notchState == .open {
                Rectangle()
                    .fill(NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0 > 0 ? .black : .clear)
                    .frame(width: vm.closedNotchSize.width)
                    .mask {
                        NotchShape()
                    }
            }

            HStack(spacing: 4) {
                if vm.notchState == .open {
                    if isHUDType(coordinator.sneakPeek.type) && coordinator.sneakPeek.show && Defaults[.showOpenNotchHUD] {
                        OpenNotchHUD(type: $coordinator.sneakPeek.type, value: $coordinator.sneakPeek.value, icon: $coordinator.sneakPeek.icon)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        if Defaults[.weatherEnabled] && Defaults[.showWeatherInHeader] {
                            WeatherHeaderChip()
                                .fixedSize()
                        }
                        if Defaults[.showMirror] {
                            Button(action: {
                                // The mirror lives on the Home tab: switch there when turning it on.
                                if !vm.isCameraExpanded {
                                    withAnimation(.smooth) { coordinator.currentView = .home }
                                }
                                vm.toggleCameraPreview()
                            }) {
                                Capsule()
                                    .fill(vm.isCameraExpanded ? Color.white.opacity(0.2) : .black)
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        Image(systemName: "web.camera")
                                            .foregroundColor(.white)
                                            .imageScale(.small)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Mirror")
                        }
                        if Defaults[.showCleanerButton] {
                            Button(action: {
                                withAnimation(.smooth) {
                                    coordinator.currentView = coordinator.currentView == .cleaner ? .home : .cleaner
                                }
                            }) {
                                Capsule()
                                    .fill(coordinator.currentView == .cleaner ? Color.white.opacity(0.2) : .black)
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        Image(systemName: "sparkles")
                                            .foregroundColor(.white)
                                            .imageScale(.small)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                            .help("Clean app caches")
                        }
                        if Defaults[.settingsIconInNotch] {
                            Button(action: {
                                DispatchQueue.main.async {
                                    SettingsWindowController.shared.showWindow()
                                }
                                
                            }) {
                                Capsule()
                                    .fill(.black)
                                    .frame(width: 26, height: 26)
                                    .overlay {
                                        Image(systemName: "gear")
                                            .foregroundColor(.white)
                                            .imageScale(.small)
                                    }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        if Defaults[.showBatteryIndicator] {
                            BoringBatteryView(
                                batteryWidth: 30,
                                isCharging: batteryModel.isCharging,
                                isInLowPowerMode: batteryModel.isInLowPowerMode,
                                isPluggedIn: batteryModel.isPluggedIn,
                                levelBattery: batteryModel.levelBattery,
                                maxCapacity: batteryModel.maxCapacity,
                                timeToFullCharge: batteryModel.timeToFullCharge,
                                isForNotification: false
                            )
                            .fixedSize()
                        }
                    }
                }
            }
            .font(.system(.headline, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(vm.notchState == .closed ? 0 : 1)
            .blur(radius: vm.notchState == .closed ? 20 : 0)
            .zIndex(2)
        }
        .foregroundColor(.gray)
        .environmentObject(vm)
    }

    func isHUDType(_ type: SneakContentType) -> Bool {
        switch type {
        case .volume, .brightness, .backlight, .mic:
            return true
        default:
            return false
        }
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
