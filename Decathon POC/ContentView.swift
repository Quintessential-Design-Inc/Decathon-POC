//
//  ContentView.swift
//  Decathon POC
//
//  Created by Rushikesh Suradkar  on 07/10/26.
//

import SwiftUI
import QuinKitBLE
import QuinKitPermissions

struct ContentView: View {
    let session: BluetoothSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity)

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        introduction
                        bluetoothCard
                        helmetGuide
                        discoveryAction
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Image("QuinLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 50)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your\nQUIN PRO.")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)

            Text("Review your helmet's offline events and device information, all in one place.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var bluetoothCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: session.readiness.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.16), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Bluetooth")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(session.readiness.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if session.readiness.isWaiting {
                    ProgressView()
                        .accessibilityLabel(session.readiness.title)
                }
            }

            Text(session.readiness.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(spacing: 12) {
                statusRow("App permission", value: permissionLabel)
                statusRow("Bluetooth availability", value: availabilityLabel)
            }

            permissionAction
        }
        .padding(20)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch session.readiness {
        case .needsPermission:
            POCActionButton(title: "Allow Bluetooth", systemImage: "antenna.radiowaves.left.and.right") {
                Task { await session.requestPermissionIfNeeded() }
            }
        case .permissionDenied:
            POCActionButton(title: "Open Settings", systemImage: "gearshape") {
                session.openSettings()
            }
        case .poweredOff:
            POCActionButton(title: "Refresh status", systemImage: "arrow.clockwise", prominence: .secondary) {
                session.refresh()
            }
        case .requestingPermission, .starting, .resetting, .unsupported, .ready:
            EmptyView()
        }
    }

    private var helmetGuide: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Get your helmet ready")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            guideRow("1", title: "Wake your helmet", detail: "If it is asleep, gently move it to wake it.")
            guideRow("2", title: "Double-tap the helmet", detail: "This makes it discoverable for about 20 seconds.")
            guideRow("3", title: "Keep it nearby", detail: "Keep your helmet close to your iPhone when connecting.")
        }
    }

    private var discoveryAction: some View {
        VStack(spacing: 12) {
            POCActionButton(title: "Scan for helmets", systemImage: "magnifyingglass") {}
                .disabled(true)
                .opacity(0.55)
                .accessibilityHint("Device scanning is not available in this build.")

            Text("Device scanning is not available in this build.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statusRow(_ title: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).fontWeight(.medium)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Text(value).fontWeight(.medium)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func guideRow(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.subheadline.weight(.semibold))
                .frame(width: 30, height: 30)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var permissionLabel: String {
        switch session.permissionStatus {
        case .granted: "Allowed"
        case .denied: "Not allowed"
        case .notDetermined: "Not requested"
        }
    }

    private var availabilityLabel: String {
        switch session.bluetoothState {
        case .unknown: "Not checked"
        case .resetting: "Restarting"
        case .unsupported: "Unavailable"
        case .unauthorized: "Access blocked"
        case .poweredOff: "Off"
        case .poweredOn: "On"
        }
    }
}

#Preview {
    ContentView(session: BluetoothSession())
        .tint(.accentColor)
}
