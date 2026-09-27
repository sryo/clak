import SwiftUI

// MARK: - Preferences View

struct PreferencesView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            ShortcutsSettingsView()
                .tabItem { Label("Shortcuts", systemImage: "command") }
                .tag(1)

            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(2)
        }
        .frame(width: 450, height: 380)
        .padding()
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @State private var launchAtLogin = AppPreferences.shared.launchAtLogin
    @State private var forwardingByDefault = AppPreferences.shared.forwardingEnabled
    @State private var trackpadScroll = AppPreferences.shared.trackpadScrollEnabled
    @State private var permissions = PermissionSnapshot.current

    var body: some View {
        Form {
            Section {
                LabeledContent("Launch at login") {
                    Toggle("", isOn: $launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: launchAtLogin) { _, newValue in
                            AppPreferences.shared.launchAtLogin = newValue
                            // Registration can fail (e.g. user denied in System Settings)
                            launchAtLogin = AppPreferences.shared.launchAtLogin
                        }
                }

                LabeledContent("Start forwarding when Clak opens") {
                    Toggle("", isOn: $forwardingByDefault)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: forwardingByDefault) { _, newValue in
                            AppPreferences.shared.forwardingEnabled = newValue
                        }
                }

                LabeledContent {
                    Toggle("", isOn: $trackpadScroll)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: trackpadScroll) { _, newValue in
                            AppPreferences.shared.trackpadScrollEnabled = newValue
                            if newValue {
                                if PermissionChecker.hasAccessibilityPermission {
                                    ScrollEnhancer.shared.start()
                                } else {
                                    PermissionChecker.requestAccessibilityPermission()
                                }
                            } else {
                                ScrollEnhancer.shared.stop()
                            }
                        }
                } label: {
                    Text("Trackpad-style scrolling from Clak Remote")
                    Text("Smooths and adds momentum to scrolling when this Mac is controlled from the iPhone app. Requires Accessibility.")
                }
            } header: {
                Text("Behavior")
            }

            Section {
                PermissionRow(
                    icon: "keyboard.badge.eye",
                    title: "Input Monitoring",
                    description: "Lets Clak read your keys to send them to your device.",
                    isGranted: permissions.inputMonitoring,
                    openSettingsAction: {
                        PermissionChecker.openInputMonitoringSettings()
                    }
                )

                PermissionRow(
                    icon: "accessibility",
                    title: "Accessibility",
                    description: "Lets Global Forwarding type from any app, without Clak in front.",
                    isGranted: permissions.accessibility,
                    openSettingsAction: {
                        PermissionChecker.openAccessibilitySettings()
                    }
                )

                PermissionRow(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Bluetooth",
                    description: "Lets Clak show up as a keyboard on your device.",
                    isGranted: permissions.bluetooth,
                    openSettingsAction: {
                        PermissionChecker.openBluetoothPrivacySettings()
                    }
                )
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions = .current }
        // Permissions are granted in System Settings; re-read them on return
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions = .current
        }
    }
}

struct PermissionSnapshot: Equatable {
    var inputMonitoring: Bool
    var accessibility: Bool
    var bluetooth: Bool

    static var current: PermissionSnapshot {
        PermissionSnapshot(
            inputMonitoring: PermissionChecker.hasInputMonitoringPermission,
            accessibility: PermissionChecker.hasAccessibilityPermission,
            bluetooth: PermissionChecker.isBluetoothAuthorized
        )
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    var openSettingsAction: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isGranted ? .green : .orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)

                    Spacer()

                    Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isGranted ? .green : .orange)
                        .font(.body)
                }

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !isGranted, let openSettingsAction {
                    Button("Open Settings") {
                        openSettingsAction()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(isGranted ? "allowed" : "not allowed")")
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    private let manager = KeyboardShortcutManager.shared
    @State private var refreshToken = UUID()

    var body: some View {
        Form {
            Section {
                ForEach(ShortcutAction.allCases, id: \.rawValue) { action in
                    LabeledContent {
                        ShortcutRecorderView(
                            action: action,
                            currentShortcut: manager.registeredShortcuts.first { $0.action == action },
                            onRecord: { keyCode, modifiers in
                                if manager.conflictingAction(keyCode: keyCode, modifiers: modifiers, excluding: action) != nil {
                                    return false
                                }
                                manager.updateShortcut(action: action, keyCode: keyCode, modifiers: modifiers)
                                refreshToken = UUID()
                                return true
                            }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.displayName)
                                .font(.body)
                            Text(action.displayDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Keyboard Shortcuts")
            }
            .id(refreshToken)

            Section {
                Button("Reset to Defaults") {
                    manager.resetToDefaults()
                    refreshToken = UUID()
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Clak")
                .font(.title)
                .bold()

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Your Mac keyboard, on your iPhone.")
                .font(.body)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Previews

#Preview("Preferences") {
    PreferencesView()
}
