import CoreGraphics
import CoreImage
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ImageEditorView: View {
    struct ImportedPhoto: Identifiable, Equatable {
        let id = UUID()
        let rawData: Data?
        let processedData: Data?
        let processingSource: StyledProcessingSource
        let pixelSize: CGSize
        let originalFilename: String?

        var hasRAWSource: Bool { rawData != nil }
        var displayName: String {
            let trimmed = originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "Imported Photo" : trimmed
        }
        var aspectRatio: CGFloat {
            let width = max(pixelSize.width, 1)
            let height = max(pixelSize.height, 1)
            return width / height
        }
    }

    enum EffectGroup: String, CaseIterable, Hashable {
        case base
        case color
        case colorGrading
        case hslMix
        case stylization

        var title: String {
            switch self {
            case .base: return "Base"
            case .color: return "Color"
            case .colorGrading: return "Color Grading"
            case .hslMix: return "HSL Mix"
            case .stylization: return "Stylization"
            }
        }
    }

    private enum EditorStatus: Equatable {
        case idle
        case importing
        case exporting
    }

    @ObservedObject var cameraService: CameraService
    @Environment(\.dismiss) private var dismiss

    @State private var importedPhoto: ImportedPhoto?
    @State private var previewSourceImage: UIImage?
    @State private var editorSettings: PhotoEffectSettings
    @State private var renderedPreviewImage: UIImage?
    @State private var previewRenderTask: Task<Void, Never>?
    @State private var previewRenderGeneration: UInt64 = 0
    @State private var expandedGroups: Set<EffectGroup> = [.base]
    @State private var showPhotoPicker = false
    @State private var showExportSheet = false
    @State private var exportFormat: ProcessedImageExportFormat = .heic
    @State private var exportQuality: Double
    @State private var editorStatus: EditorStatus = .idle
    @State private var alertMessage: String?

    private let themeTeal = Color(red: 0.07, green: 0.74, blue: 0.70)
    private let themePink = Color(red: 0.95, green: 0.54, blue: 0.75)
    private let themeTextPrimary = Color.white.opacity(0.94)
    private let themeTextSecondary = Color(red: 0.82, green: 0.83, blue: 0.9)
    private let themeBackgroundTop = Color(red: 0.06, green: 0.09, blue: 0.13)
    private let themeBackgroundBottom = Color(red: 0.03, green: 0.05, blue: 0.08)
    private let previewHorizontalPadding: CGFloat = 16
    private let previewMaxPortraitHeightRatio: CGFloat = 0.48
    private let previewPlaceholderHeight: CGFloat = 280

    nonisolated private static let previewProcessor = PhotoEffectsProcessor()
    nonisolated private static let exportProcessor = PhotoEffectsProcessor()
    nonisolated private static let previewDebounceNanoseconds: UInt64 = 8_000_000
    nonisolated private static let interactivePreviewMaxDimension: CGFloat = 1200

    init(cameraService: CameraService, initialSettings: PhotoEffectSettings) {
        self.cameraService = cameraService
        _editorSettings = State(initialValue: initialSettings.clamped())
        _exportQuality = State(initialValue: cameraService.styledHEIFCompressionQuality)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    previewCard(availableSize: proxy.size)
                        .padding(.horizontal, previewHorizontalPadding)
                        .padding(.top, 12)
                        .padding(.bottom, 12)

                    ScrollView {
                        VStack(spacing: 16) {
                            importSummaryRow
                                .padding(.horizontal, previewHorizontalPadding)

                            effectSections
                                .padding(.horizontal, previewHorizontalPadding)
                                .padding(.bottom, 28)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .background(
                LinearGradient(
                    colors: [themeBackgroundTop, themeBackgroundBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
            .navigationTitle("Image Editor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                        .foregroundStyle(themePink)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Import") {
                        showPhotoPicker = true
                    }
                    .foregroundStyle(themeTeal)

                    Button("Save") {
                        showExportSheet = true
                    }
                    .disabled(importedPhoto == nil || editorStatus != .idle)
                    .foregroundStyle(importedPhoto == nil ? themeTextSecondary : themePink)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Reset") {
                        editorSettings = .neutral
                        schedulePreviewRender()
                    }
                    .disabled(importedPhoto == nil || editorStatus != .idle)
                    .foregroundStyle(themePink)
                }
            }
        }
        .tint(themeTeal)
        .sheet(isPresented: $showPhotoPicker) {
            EditorPhotoPicker { result in
                guard let result else { return }
                Task {
                    await importPhoto(from: result)
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            exportSheet
        }
        .alert("Image Editor", isPresented: alertPresentedBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .overlay {
            if editorStatus != .idle {
                progressOverlay
            }
        }
        .onDisappear {
            previewRenderGeneration &+= 1
            previewRenderTask?.cancel()
            previewRenderTask = nil
            previewSourceImage = nil
        }
    }

    private func previewCard(availableSize: CGSize) -> some View {
        let width = max(availableSize.width - (previewHorizontalPadding * 2), 0)
        let aspect = importedPhoto?.aspectRatio ?? (4.0 / 3.0)
        let unclampedHeight = width / max(aspect, 0.1)
        let maxPortraitHeight = max(availableSize.height * previewMaxPortraitHeightRatio, 220)
        let previewHeight = aspect >= 1 ? unclampedHeight : min(unclampedHeight, maxPortraitHeight)

        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(themeBackgroundBottom.opacity(0.58))

            if let image = renderedPreviewImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: importedPhoto == nil ? "photo.badge.plus" : "wand.and.stars")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(themeTeal)
                    Text(importedPhoto == nil ? "Import an image from Photos" : "Rendering preview")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeTextPrimary)
                    if importedPhoto == nil {
                        Button("Choose Photo") {
                            showPhotoPicker = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themePink)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: importedPhoto == nil ? previewPlaceholderHeight : previewHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(themeTeal.opacity(0.34), lineWidth: 1)
        )
    }

    private var importSummaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(importedPhoto?.displayName ?? "No image selected")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeTextPrimary)
                    .lineLimit(1)
                Spacer()
                if let importedPhoto {
                    if importedPhoto.hasRAWSource {
                        badge(title: "RAW", color: themePink)
                    }
                    badge(
                        title: "\(Int(importedPhoto.pixelSize.width))×\(Int(importedPhoto.pixelSize.height))",
                        color: themeTeal
                    )
                }
            }

            Text("Imports from Photos, edits with the same pipeline as camera presets, and exports at full resolution.")
                .font(.footnote)
                .foregroundStyle(themeTextSecondary)
        }
    }

    private var effectSections: some View {
        VStack(spacing: 14) {
            collapsibleSection(.base) {
                effectSlider(title: "Base Exposure", value: effectBinding(\.baseExposure), range: PhotoEffectSettings.baseExposureRange)
                effectSlider(title: "Contrast", value: effectBinding(\.contrast), range: PhotoEffectSettings.contrastRange)
                effectSlider(title: "Highlights", value: effectBinding(\.highlights), range: PhotoEffectSettings.highlightsRange)
                effectSlider(title: "Shadows", value: effectBinding(\.shadows), range: PhotoEffectSettings.shadowsRange)
                effectSlider(title: "Whites", value: effectBinding(\.whites), range: PhotoEffectSettings.whitesRange)
                effectSlider(title: "Blacks", value: effectBinding(\.blacks), range: PhotoEffectSettings.blacksRange)
                effectSlider(title: "White Fade", value: effectBinding(\.whiteFade), range: PhotoEffectSettings.whiteFadeRange)
                effectSlider(title: "Black Fade", value: effectBinding(\.blackFade), range: PhotoEffectSettings.blackFadeRange)
                effectSlider(title: "Clarity", value: effectBinding(\.clarity), range: PhotoEffectSettings.clarityRange)
                effectSlider(title: "Sharpness", value: effectBinding(\.sharpness), range: PhotoEffectSettings.sharpnessRange)
            }

            collapsibleSection(.color) {
                effectSlider(title: "Saturation", value: effectBinding(\.saturation), range: PhotoEffectSettings.saturationRange)
                effectSlider(title: "Vibrance", value: effectBinding(\.vibrance), range: PhotoEffectSettings.vibranceRange)
                effectSlider(
                    title: "Warmth",
                    value: effectBinding(\.warmth),
                    range: PhotoEffectSettings.warmthRange,
                    decimals: 0,
                    tint: warmthTintColor(value: editorSettings.warmth)
                )
                effectSlider(
                    title: "Tint",
                    value: effectBinding(\.tint),
                    range: PhotoEffectSettings.tintRange,
                    decimals: 0,
                    tint: tintAdjustmentColor(value: editorSettings.tint)
                )
            }

            collapsibleSection(.colorGrading) {
                effectSlider(
                    title: "Global Hue",
                    value: colorGradeBinding(\.global, \.hue),
                    range: PhotoEffectSettings.colorGradeHueRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.global.hue)
                )
                effectSlider(
                    title: "Global Amount",
                    value: colorGradeBinding(\.global, \.amount),
                    range: PhotoEffectSettings.colorGradeAmountRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.global.hue)
                )
                effectSlider(
                    title: "Shadows Hue",
                    value: colorGradeBinding(\.shadows, \.hue),
                    range: PhotoEffectSettings.colorGradeHueRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.shadows.hue)
                )
                effectSlider(
                    title: "Shadows Amount",
                    value: colorGradeBinding(\.shadows, \.amount),
                    range: PhotoEffectSettings.colorGradeAmountRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.shadows.hue)
                )
                effectSlider(
                    title: "Midtones Hue",
                    value: colorGradeBinding(\.midtones, \.hue),
                    range: PhotoEffectSettings.colorGradeHueRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.midtones.hue)
                )
                effectSlider(
                    title: "Midtones Amount",
                    value: colorGradeBinding(\.midtones, \.amount),
                    range: PhotoEffectSettings.colorGradeAmountRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.midtones.hue)
                )
                effectSlider(
                    title: "Highlights Hue",
                    value: colorGradeBinding(\.highlights, \.hue),
                    range: PhotoEffectSettings.colorGradeHueRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.highlights.hue)
                )
                effectSlider(
                    title: "Highlights Amount",
                    value: colorGradeBinding(\.highlights, \.amount),
                    range: PhotoEffectSettings.colorGradeAmountRange,
                    tint: gradeTintColor(hue: editorSettings.colorGrading.highlights.hue)
                )
            }

            collapsibleSection(.hslMix) {
                ForEach(HSLColorBand.allCases) { band in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(band.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(themeTextPrimary)
                        effectSlider(
                            title: "Hue",
                            value: hslBinding(for: band, \.hueShift),
                            range: PhotoEffectSettings.hslHueRange,
                            tint: hslHueTintColor(for: band, shift: editorSettings.hsl[band].hueShift)
                        )
                        effectSlider(
                            title: "Saturation",
                            value: hslBinding(for: band, \.saturationDelta),
                            range: PhotoEffectSettings.hslSaturationRange,
                            tint: hslSaturationTintColor(for: band, delta: editorSettings.hsl[band].saturationDelta)
                        )
                        effectSlider(
                            title: "Luminance",
                            value: hslBinding(for: band, \.lightnessDelta),
                            range: PhotoEffectSettings.hslLightnessRange,
                            tint: hslLuminanceTintColor(for: band, delta: editorSettings.hsl[band].lightnessDelta)
                        )
                    }
                    .padding(.vertical, 4)
                }
            }

            collapsibleSection(.stylization) {
                effectSlider(title: "Bloom Intensity", value: effectBinding(\.bloomIntensity), range: PhotoEffectSettings.bloomIntensityRange)
                effectSlider(title: "Bloom Radius", value: effectBinding(\.bloomRadius), range: PhotoEffectSettings.bloomRadiusRange, decimals: 1)
                effectSlider(title: "Vignette", value: effectBinding(\.vignetteIntensity), range: PhotoEffectSettings.vignetteIntensityRange)
                effectSlider(title: "Vignette Radius", value: effectBinding(\.vignetteRadius), range: PhotoEffectSettings.vignetteRadiusRange, decimals: 2)
                effectSlider(title: "Grain", value: effectBinding(\.grainAmount), range: PhotoEffectSettings.grainAmountRange)
                effectSlider(title: "Grain Size", value: effectBinding(\.grainSize), range: PhotoEffectSettings.grainSizeRange)
            }
        }
    }

    private var exportSheet: some View {
        NavigationStack {
            Form {
                Section("Format") {
                    Picker("Export Format", selection: $exportFormat) {
                        ForEach(ProcessedImageExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Quality") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Compression Quality")
                            Spacer()
                            Text(exportQuality, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(themeTextSecondary)
                        }
                        ThemedSlider(
                            value: $exportQuality,
                            range: 0.4...1.0,
                            minimumTrackColor: themeTeal,
                            maximumTrackColor: themePink.opacity(0.22),
                            thumbColor: themePink
                        )
                        .frame(height: 28)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    Text("Exports are rendered from the full-resolution source. RAW imports stay RAW-backed for development, then save as JPEG or HEIC.")
                        .font(.footnote)
                        .foregroundStyle(themeTextSecondary)
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
            .navigationTitle("Save Image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showExportSheet = false }
                        .foregroundStyle(themePink)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await exportEditedPhoto() }
                    }
                    .foregroundStyle(themePink)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var progressOverlay: some View {
        ZStack {
            Rectangle()
                .fill(themeBackgroundBottom.opacity(0.74))
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                    .tint(themeTeal)
                    .scaleEffect(1.2)
                Text(editorStatus == .importing ? "Importing photo" : "Saving full-resolution export")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeTextPrimary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .background(themeBackgroundTop.opacity(0.9), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(themeTeal.opacity(0.28), lineWidth: 1)
            )
        }
    }

    private var alertPresentedBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    alertMessage = nil
                }
            }
        )
    }

    private func badge(title: String, color: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.2), lineWidth: 1))
    }

    @ViewBuilder
    private func collapsibleSection<Content: View>(
        _ group: EffectGroup,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if expandedGroups.contains(group) {
                        expandedGroups.remove(group)
                    } else {
                        expandedGroups = [group]
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themePink.opacity(0.96))
                    Spacer()
                    Image(systemName: expandedGroups.contains(group) ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeTeal)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedGroups.contains(group) {
                content()
            }
        }
        .padding(14)
        .background(themeBackgroundTop.opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(themePink.opacity(0.14), lineWidth: 1)
        )
    }

    private func effectSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        decimals: Int = 2,
        tint: Color? = nil
    ) -> some View {
        let sliderTint = tint ?? themeTeal
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themePink.opacity(0.92))
                Spacer()
                Text(value.wrappedValue, format: .number.precision(.fractionLength(decimals)))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(themeTextSecondary)
            }
            ThemedSlider(
                value: value,
                range: range,
                minimumTrackColor: sliderTint,
                maximumTrackColor: themePink.opacity(0.22),
                thumbColor: themePink
            )
            .frame(height: 28)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .padding(.vertical, 2)
    }

    private func effectBinding(_ keyPath: WritableKeyPath<PhotoEffectSettings, Double>) -> Binding<Double> {
        Binding(
            get: { editorSettings[keyPath: keyPath] },
            set: { nextValue in
                editorSettings[keyPath: keyPath] = nextValue
                schedulePreviewRender()
            }
        )
    }

    private func hslBinding(
        for band: HSLColorBand,
        _ keyPath: WritableKeyPath<HSLBandAdjustment, Double>
    ) -> Binding<Double> {
        Binding(
            get: { editorSettings.hsl[band][keyPath: keyPath] },
            set: { nextValue in
                var adjustment = editorSettings.hsl[band]
                adjustment[keyPath: keyPath] = nextValue
                editorSettings.hsl[band] = adjustment
                schedulePreviewRender()
            }
        )
    }

    private func colorGradeBinding(
        _ toneKeyPath: WritableKeyPath<ColorGradingSettings, ColorGradeTone>,
        _ valueKeyPath: WritableKeyPath<ColorGradeTone, Double>
    ) -> Binding<Double> {
        Binding(
            get: { editorSettings.colorGrading[keyPath: toneKeyPath][keyPath: valueKeyPath] },
            set: { nextValue in
                var tone = editorSettings.colorGrading[keyPath: toneKeyPath]
                tone[keyPath: valueKeyPath] = nextValue
                editorSettings.colorGrading[keyPath: toneKeyPath] = tone
                schedulePreviewRender()
            }
        )
    }

    private func importPhoto(from result: PHPickerResult) async {
        guard editorStatus == .idle else { return }
        editorStatus = .importing
        defer { editorStatus = .idle }

        do {
            let imported = try await Self.loadImportedPhoto(from: result)
            let sourcePreview = await Task.detached(priority: .userInitiated) {
                Self.previewProcessor.renderImportedPreview(
                    rawData: imported.rawData,
                    processedData: imported.processedData,
                    settings: .neutral,
                    preferredProcessingSource: imported.processingSource,
                    maxDimension: Self.interactivePreviewMaxDimension,
                    includeGrain: false
                )
            }.value
            importedPhoto = imported
            previewSourceImage = sourcePreview
            renderedPreviewImage = sourcePreview
            schedulePreviewRender()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func schedulePreviewRender() {
        guard let importedPhoto else {
            renderedPreviewImage = nil
            return
        }

        let settings = editorSettings.clamped()
        previewRenderGeneration &+= 1
        let generation = previewRenderGeneration

        previewRenderTask?.cancel()
        let sourcePreviewImage = previewSourceImage
        previewRenderTask = Task.detached(priority: .userInitiated) {
            try? await Task.sleep(nanoseconds: Self.previewDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            let rendered: UIImage?
            if let sourcePreviewImage {
                rendered = Self.previewProcessor.renderReferencePreview(
                    from: sourcePreviewImage,
                    settings: settings,
                    maxDimension: Self.interactivePreviewMaxDimension,
                    includeGrain: true
                )
            } else {
                rendered = Self.previewProcessor.renderImportedPreview(
                    rawData: importedPhoto.rawData,
                    processedData: importedPhoto.processedData,
                    settings: settings,
                    preferredProcessingSource: importedPhoto.processingSource,
                    maxDimension: Self.interactivePreviewMaxDimension,
                    includeGrain: true
                )
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard generation == previewRenderGeneration else { return }
                renderedPreviewImage = rendered
            }
        }
    }

    private func exportEditedPhoto() async {
        guard editorStatus == .idle, let importedPhoto else { return }
        editorStatus = .exporting
        defer { editorStatus = .idle }

        let settings = editorSettings.clamped()
        let quality = min(max(exportQuality, 0.4), 1.0)
        let bitDepth = cameraService.styledHEIFBitDepth
        let outputFormat = exportFormat
        let rendered = await Task.detached(priority: .userInitiated) {
            Self.exportProcessor.renderProcessedImageData(
                rawData: importedPhoto.rawData,
                processedData: importedPhoto.processedData,
                settings: settings,
                preferredHEIFBitDepth: bitDepth,
                preferredHEIFCompressionQuality: quality,
                preferredProcessingSource: importedPhoto.processingSource,
                preferredOutputFormat: outputFormat
            )
        }.value

        guard let rendered else {
            alertMessage = "Couldn’t render the edited image."
            return
        }

        let result = await saveToPhotoLibrary(styledResource: rendered)
        if result.0 {
            showExportSheet = false
        } else {
            alertMessage = result.1 ?? "Couldn’t save the edited image."
        }
    }

    private func saveToPhotoLibrary(
        styledResource: (data: Data, uniformTypeIdentifier: String)
    ) async -> (Bool, String?) {
        let authStatus = await ensurePhotoWriteAuthorization()
        guard authStatus == .authorized || authStatus == .limited else {
            return (false, "No Photos write permission")
        }

        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = Date()
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = normalizedOutputUTI(styledResource.uniformTypeIdentifier)
                request.addResource(with: .photo, data: styledResource.data, options: options)
            }, completionHandler: { success, error in
                continuation.resume(returning: (success, error?.localizedDescription))
            })
        }
    }

    private func ensurePhotoWriteAuthorization() async -> PHAuthorizationStatus {
        let addOnlyCurrent = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch addOnlyCurrent {
        case .authorized: return .authorized
        case .notDetermined:
            let requested = await requestPhotoAuthorization(for: .addOnly)
            if requested == .authorized { return requested }
        default: break
        }

        let readWriteCurrent = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch readWriteCurrent {
        case .authorized, .limited: return readWriteCurrent
        case .notDetermined: return await requestPhotoAuthorization(for: .readWrite)
        default: return readWriteCurrent
        }
    }

    private func requestPhotoAuthorization(for accessLevel: PHAccessLevel) async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: accessLevel) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func normalizedOutputUTI(_ candidate: String) -> String {
        if candidate == UTType.jpeg.identifier || candidate == "public.jpeg" {
            return UTType.jpeg.identifier
        }
        if candidate == UTType.heic.identifier || candidate == "public.heic" {
            return UTType.heic.identifier
        }
        return UTType.heic.identifier
    }

    private func gradeTintColor(hue: Double) -> Color {
        let normalized = normalizedHueUnit(hue)
        return Color(hue: normalized, saturation: 0.9, brightness: 0.95)
    }

    private func warmthTintColor(value: Double) -> Color {
        let neutral = UIColor(themeTextSecondary.opacity(0.9))
        let cool = UIColor(red: 0.35, green: 0.72, blue: 0.98, alpha: 1)
        let warm = UIColor(red: 1.0, green: 0.63, blue: 0.24, alpha: 1)
        let progress = normalizedUnit(value, in: PhotoEffectSettings.warmthRange)

        if progress < 0.5 {
            return interpolateColor(from: cool, to: neutral, progress: progress / 0.5)
        }

        return interpolateColor(from: neutral, to: warm, progress: (progress - 0.5) / 0.5)
    }

    private func tintAdjustmentColor(value: Double) -> Color {
        let neutral = UIColor(themeTextSecondary.opacity(0.9))
        let green = UIColor(red: 0.34, green: 0.86, blue: 0.58, alpha: 1)
        let magenta = UIColor(red: 0.96, green: 0.47, blue: 0.82, alpha: 1)
        let progress = normalizedUnit(value, in: PhotoEffectSettings.tintRange)

        if progress < 0.5 {
            return interpolateColor(from: green, to: neutral, progress: progress / 0.5)
        }

        return interpolateColor(from: neutral, to: magenta, progress: (progress - 0.5) / 0.5)
    }

    private func hslHueTintColor(for band: HSLColorBand, shift: Double) -> Color {
        hslBandColor(for: band, hueShift: shift, saturation: 0.92, brightness: 0.96)
    }

    private func hslSaturationTintColor(for band: HSLColorBand, delta: Double) -> Color {
        let progress = normalizedUnit(delta, in: PhotoEffectSettings.hslSaturationRange)
        let saturation = 0.18 + (progress * 0.78)
        let brightness = 0.76 + (progress * 0.2)
        return hslBandColor(for: band, saturation: saturation, brightness: brightness)
    }

    private func hslLuminanceTintColor(for band: HSLColorBand, delta: Double) -> Color {
        let progress = normalizedUnit(delta, in: PhotoEffectSettings.hslLightnessRange)
        let saturation = 0.92 - (progress * 0.28)
        let brightness = 0.42 + (progress * 0.54)
        return hslBandColor(for: band, saturation: saturation, brightness: brightness)
    }

    private func hslBandColor(
        for band: HSLColorBand,
        hueShift: Double = 0,
        saturation: Double = 0.9,
        brightness: Double = 0.95
    ) -> Color {
        let normalized = normalizedHueUnit(hslBandBaseHueDegrees(for: band) + hueShift)
        return Color(hue: normalized, saturation: saturation, brightness: brightness)
    }

    private func hslBandBaseHueDegrees(for band: HSLColorBand) -> Double {
        switch band {
        case .red: return 0
        case .orange: return 28
        case .yellow: return 56
        case .green: return 122
        case .aqua: return 182
        case .blue: return 220
        case .purple: return 276
        case .magenta: return 320
        }
    }

    private func normalizedHueUnit(_ hue: Double) -> Double {
        let degrees = hue.truncatingRemainder(dividingBy: 360)
        return (degrees < 0 ? degrees + 360 : degrees) / 360
    }

    private func normalizedUnit(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped - range.lowerBound) / span
    }

    private func interpolateColor(from start: UIColor, to end: UIColor, progress: Double) -> Color {
        let clamped = min(max(progress, 0), 1)

        var startRed: CGFloat = 0
        var startGreen: CGFloat = 0
        var startBlue: CGFloat = 0
        var startAlpha: CGFloat = 0
        var endRed: CGFloat = 0
        var endGreen: CGFloat = 0
        var endBlue: CGFloat = 0
        var endAlpha: CGFloat = 0

        guard start.getRed(&startRed, green: &startGreen, blue: &startBlue, alpha: &startAlpha),
              end.getRed(&endRed, green: &endGreen, blue: &endBlue, alpha: &endAlpha) else {
            return Color(uiColor: end)
        }

        let inverse = 1 - clamped
        return Color(
            red: Double((startRed * inverse) + (endRed * clamped)),
            green: Double((startGreen * inverse) + (endGreen * clamped)),
            blue: Double((startBlue * inverse) + (endBlue * clamped)),
            opacity: Double((startAlpha * inverse) + (endAlpha * clamped))
        )
    }

    nonisolated private static func loadImportedPhoto(from result: PHPickerResult) async throws -> ImportedPhoto {
        let selectedAsset: PHAsset? = {
            guard let assetIdentifier = result.assetIdentifier else { return nil }
            return PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject
        }()

        do {
            return try await loadImportedPhoto(from: result.itemProvider, asset: selectedAsset)
        } catch {
            if let selectedAsset {
                return try await loadImportedPhoto(from: selectedAsset)
            }
            throw error
        }
    }

    nonisolated private static func loadImportedPhoto(from asset: PHAsset) async throws -> ImportedPhoto {
        let resources = PHAssetResource.assetResources(for: asset)
        let rawResource = preferredRawResource(from: resources)
        let processedResource = preferredProcessedResource(from: resources)

        async let rawDataTask = loadResourceData(rawResource)
        async let processedDataTask = loadResourceData(processedResource)
        let rawData = try await rawDataTask
        let processedData = try await processedDataTask

        guard rawData != nil || processedData != nil else {
            throw EditorImportError.loadFailed
        }

        return ImportedPhoto(
            rawData: rawData,
            processedData: processedData,
            processingSource: rawData != nil ? .proRAW : .processed,
            pixelSize: metadataPixelSize(from: asset) ?? CGSize(width: 1, height: 1),
            originalFilename: metadataFilename(from: asset)
        )
    }

    nonisolated private static func loadImportedPhoto(
        from itemProvider: NSItemProvider,
        asset: PHAsset?
    ) async throws -> ImportedPhoto {
        let resolvedPixelSize = metadataPixelSize(from: asset)
        let resolvedFilename = metadataFilename(from: asset)
        let rawTypeIdentifier = itemProvider.registeredTypeIdentifiers.first(where: { typeIdentifier in
            UTType(typeIdentifier)?.conforms(to: .rawImage) == true
        })
        if let rawTypeIdentifier {
            let rawData = try await loadFileData(from: itemProvider, typeIdentifier: rawTypeIdentifier)
            guard let rawData else { throw EditorImportError.loadFailed }
            return ImportedPhoto(
                rawData: rawData,
                processedData: nil,
                processingSource: .proRAW,
                pixelSize: resolvedPixelSize ?? pixelSize(from: rawData) ?? CGSize(width: 1, height: 1),
                originalFilename: resolvedFilename
            )
        }

        let imageTypeIdentifier = itemProvider.registeredTypeIdentifiers.first(where: { typeIdentifier in
            UTType(typeIdentifier)?.conforms(to: .image) == true
        }) ?? UTType.image.identifier
        let processedData = try await loadFileData(from: itemProvider, typeIdentifier: imageTypeIdentifier)
        guard let processedData else { throw EditorImportError.loadFailed }
        return ImportedPhoto(
            rawData: nil,
            processedData: processedData,
            processingSource: .processed,
            pixelSize: resolvedPixelSize ?? pixelSize(from: processedData) ?? CGSize(width: 1, height: 1),
            originalFilename: resolvedFilename
        )
    }

    nonisolated private static func metadataPixelSize(from asset: PHAsset?) -> CGSize? {
        guard let asset else { return nil }
        let width = CGFloat(asset.pixelWidth)
        let height = CGFloat(asset.pixelHeight)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func metadataFilename(from asset: PHAsset?) -> String? {
        guard let asset else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    nonisolated private static func preferredRawResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first(where: isRawResource(_:))
    }

    nonisolated private static func preferredProcessedResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        let candidates = resources.filter {
            let typeIdentifier = $0.uniformTypeIdentifier
            let utType = UTType(typeIdentifier)
            return utType?.conforms(to: .image) == true && utType?.conforms(to: .rawImage) != true
        }

        return candidates.first(where: { $0.type == .fullSizePhoto })
            ?? candidates.first(where: { $0.type == .photo })
            ?? candidates.first
    }

    nonisolated private static func isRawResource(_ resource: PHAssetResource) -> Bool {
        if UTType(resource.uniformTypeIdentifier)?.conforms(to: .rawImage) == true {
            return true
        }

        let rawExtensions = ["dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef"]
        return rawExtensions.contains((resource.originalFilename as NSString).pathExtension.lowercased())
    }

    nonisolated private static func loadResourceData(_ resource: PHAssetResource?) async throws -> Data? {
        guard let resource else { return nil }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        return try await withCheckedThrowingContinuation { continuation in
            let buffer = NSMutableData()
            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { chunk in
                buffer.append(chunk)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: buffer as Data)
                }
            }
        }
    }

    nonisolated private static func loadFileData(from itemProvider: NSItemProvider, typeIdentifier: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            itemProvider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let data = try Data(contentsOf: url)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func pixelSize(from data: Data) -> CGSize? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
           width > 0,
           height > 0 {
            return CGSize(width: width, height: height)
        }

        if let image = CIImage(data: data) {
            let extent = image.extent.integral
            guard extent.width > 0, extent.height > 0 else { return nil }
            return CGSize(width: extent.width, height: extent.height)
        }

        return nil
    }
}

private enum EditorImportError: LocalizedError {
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .loadFailed:
            return "Couldn’t load the selected image from Photos."
        }
    }
}

private struct EditorPhotoPicker: UIViewControllerRepresentable {
    let onSelect: (PHPickerResult?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current

        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelect: (PHPickerResult?) -> Void

        init(onSelect: @escaping (PHPickerResult?) -> Void) {
            self.onSelect = onSelect
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            onSelect(results.first)
        }
    }
}
