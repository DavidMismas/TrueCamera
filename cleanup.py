import re
import sys

with open('TrueCamera/ContentView.swift', 'r') as f:
    text = f.read()

# Lines 785 to 1045: settingsSheet (we need to be exact; maybe regex)
text = re.sub(r'    // MARK: - Settings sheet\n\n    private var settingsSheet: some View \{.*?(?=    private var selectedUserPreset: PhotoEffectPreset\? \{)', '', text, flags=re.DOTALL)

# Lines 1047 to 1736: selectedUserPreset to shortPresetTitle
text = re.sub(r'    private var selectedUserPreset: PhotoEffectPreset\? \{.*?(?=    // MARK: - Capture format helpers)', '', text, flags=re.DOTALL)

# Now, we need to remove `private` from many variables:
# But we only want to do it inside ContentView, up to 'var body: some View {'
body_idx = text.find('    var body: some View {')
if body_idx == -1:
    print("Could not find body")
    sys.exit(1)

head = text[:body_idx]
tail = text[body_idx:]

head = head.replace('private struct MainPresetStripItem', 'struct MainPresetStripItem')
head = head.replace('private enum EffectEditorGroup', 'enum EffectEditorGroup')
head = head.replace('private enum CaptureProcessingStage', 'enum CaptureProcessingStage')
head = head.replace('private struct CaptureRequestContext', 'struct CaptureRequestContext')
head = head.replace('private struct PendingCaptureJob', 'struct PendingCaptureJob')

head = head.replace('private static let editorReferenceImage', 'static let editorReferenceImage')
head = head.replace('nonisolated private static let referencePreviewProcessor', 'nonisolated static let referencePreviewProcessor')
head = head.replace('nonisolated private static let referenceRenderDebounceNanoseconds', 'nonisolated static let referenceRenderDebounceNanoseconds')
head = head.replace('private static let editorReferenceMaxDimension', 'static let editorReferenceMaxDimension')
head = head.replace('nonisolated private static let referencePreviewRenderDimension', 'nonisolated static let referencePreviewRenderDimension')

head = head.replace('@StateObject private var cameraService', '@StateObject var cameraService')
head = head.replace('@EnvironmentObject private var premiumManager', '@EnvironmentObject var premiumManager')
head = head.replace('@Environment(\\.scenePhase) private var scenePhase', '@Environment(\\.scenePhase) var scenePhase')

# replace '@State private var' with '@State var'
head = head.replace('@State private var', '@State var')

# replace 'private let theme' with 'let theme'
head = head.replace('private let theme', 'let theme')
head = head.replace('private let maxPendingBackgroundCaptures', 'let maxPendingBackgroundCaptures')

# replace 'private var visibleEffectPresets' with 'var visibleEffectPresets', etc.
head = head.replace('private var visibleEffectPresets', 'var visibleEffectPresets')
head = head.replace('private var hasReachedFreePresetLimit', 'var hasReachedFreePresetLimit')
head = head.replace('private var selectedPresetDisplayColorBinding', 'var selectedPresetDisplayColorBinding')
head = head.replace('private var resolutionCapBinding', 'var resolutionCapBinding')
head = head.replace('private var livePresetPreviewBinding', 'var livePresetPreviewBinding')

# update tail as well, we have the loadEditorReferenceImage and other helpers at the end that EffectsSheet uses? 
# effectsSheet doesn't use capture format helpers, but it uses other things?
# No wait EffectsSheet is moved. 
# Also we need to ensure `ThemedSlider` is internal.
tail = tail.replace('private struct ThemedSlider', 'struct ThemedSlider')

with open('TrueCamera/ContentView.swift', 'w') as f:
    f.write(head + tail)
