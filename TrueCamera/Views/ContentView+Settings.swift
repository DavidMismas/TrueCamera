import SwiftUI
import Photos

extension ContentView {
    var settingsSheet: some View {
        NavigationStack {
            Form {
                Section {
                    if premiumManager.hasPremiumAccess {
                        Label("Grejn Pro unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(themeTeal)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Unlock full-resolution Apple ProRAW capture and unlimited saved presets.")
                                .font(.subheadline)
                            Button("Unlock Grejn Pro") {
                                premiumManager.presentPaywall(for: .all)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(themeTeal)
                        }
                    }
                } header: {
                    Text("Grejn Pro")
                }

                Section("Sound & Haptics") {
                    Toggle("Haptic Feedback", isOn: $cameraService.hapticsEnabled)
                    if cameraService.isShutterSoundToggleAvailable {
                        Toggle("Shutter Sound", isOn: $cameraService.shutterSoundEnabled)
                        Picker("Shutter Tone", selection: $cameraService.shutterSoundProfile) {
                            ForEach(CameraShutterSoundProfile.allCases) { tone in
                                Text(tone.label).tag(tone)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(!cameraService.shutterSoundEnabled)
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Photo Priority")
                            .font(.subheadline.weight(.semibold))
                        Text("Choose whether the camera should save a little faster or spend more time getting the cleanest result.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("Photo Priority", selection: $cameraService.capturePriority) {
                            ForEach(PhotoCapturePriority.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Max Resolution")
                            .font(.subheadline.weight(.semibold))
                        Text("Full keeps the most detail. 12 MP is quicker to save and uses less storage.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("Max Resolution", selection: resolutionCapBinding) {
                            ForEach(PhotoResolutionCap.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)

                        if !premiumManager.hasPremiumAccess {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .foregroundStyle(themePink.opacity(0.9))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Full resolution is part of Grejn Pro.")
                                        .font(.footnote.weight(.semibold))
                                    Text("Free mode uses 12 MP. Upgrade to unlock the full-resolution option.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Button("Unlock") {
                                    premiumManager.presentPaywall(for: .fullResolution)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Save Original RAW (.dng)", isOn: $cameraService.saveRAWToLibrary)
                        Text("Keeps the untouched DNG from the camera in your Photos library.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Capture")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Processing Source")
                            .font(.subheadline.weight(.semibold))
                        Text("Choose which version the app uses to create your styled photo.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("Styled Processing Source", selection: $cameraService.styledProcessingSource) {
                            ForEach(StyledProcessingSource.allCases) { source in
                                Text(source.shortLabel).tag(source)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HEIF Bit Depth")
                            .font(.subheadline.weight(.semibold))
                        Text("10-bit keeps smoother color gradients. 8-bit exports faster and makes smaller files.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Picker("Styled HEIF Bit Depth", selection: $cameraService.styledHEIFBitDepth) {
                            ForEach(StyledHEIFBitDepth.allCases) { bitDepth in
                                Text(bitDepth.shortLabel).tag(bitDepth)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("HEIF Compression")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(Int((cameraService.styledHEIFCompressionQuality * 100).rounded()))%")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(themeTextSecondary)
                        }
                        Text("Move right for higher quality and larger files. Move left for smaller files and faster saves.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        ThemedSlider(
                            value: heifCompressionPercentBinding,
                            range: StyledHEIFExportDefaults.compressionQualityRange.lowerBound * 100...StyledHEIFExportDefaults.compressionQualityRange.upperBound * 100,
                            minimumTrackColor: themeTeal,
                            maximumTrackColor: themePink.opacity(0.22),
                            thumbColor: themePink
                        )
                        .frame(height: 28)

                        HStack {
                            Text("85%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(themeTextSecondary.opacity(0.8))
                            Spacer()
                            Text("100%")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                                .foregroundStyle(themeTextSecondary.opacity(0.8))
                        }
                    }
                } header: {
                    Text("Styled Export")
                }

                Section {
                    if premiumManager.hasPremiumAccess {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Live Preset Preview", isOn: livePresetPreviewBinding)
                            Text("Shows your preset's tone and color changes directly in the camera preview. Grain, bloom, and vignette are still applied after capture.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.fill")
                                .foregroundStyle(themePink.opacity(0.9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Live Preset Preview is part of Grejn Pro.")
                                    .font(.footnote.weight(.semibold))
                                Text("See tone and color changes on the live camera view before you shoot. Grain, bloom, and vignette are still added after capture.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Unlock") {
                                premiumManager.presentPaywall(for: .livePresetPreview)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                } header: {
                    Text("Preview")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Show Exposure Slider", isOn: $cameraService.exposureSliderVisible)
                        Text("Shows or hides the manual exposure control under the camera preview.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Controls")
                }

                if !cameraService.appleProRAWSupported {
                    Section("Compatibility") {
                        Text("ProRAW is not supported on the current device/lens.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Info") {
                    Text("Photo Priority: Balanced is usually faster. Quality can help in low light or fine detail, but it may take longer to save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Max Resolution: Full keeps maximum detail. 12 MP is lighter, faster, and easier on storage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Processing Source: ProRAW gives the best base quality for styled exports. Processed is the faster option.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("HEIF Bit Depth: 10-bit keeps smoother gradients. 8-bit saves faster and uses less space.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("HEIF Compression: 100% keeps the largest files and the least compression. Around 85% usually saves a lot of space with only a small quality drop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Live Preset Preview: Shows your preset's tone and color adjustments in real time. Grain, bloom, and vignette stay capture-only so preview remains responsive.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Capture uses Apple ProRAW at \(cameraService.resolutionCap.label) resolution.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("If Save Original RAW is on, the untouched DNG is also stored in Photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(themeTeal)
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [themeBackgroundTop, themeBackgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSettingsSheet = false }
                        .foregroundStyle(themePink)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $premiumManager.isPaywallPresented) {
            PremiumPaywallView()
                .environmentObject(premiumManager)
        }
    }
}
